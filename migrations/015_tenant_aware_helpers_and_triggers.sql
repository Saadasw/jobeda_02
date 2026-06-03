-- Migration 015: Tenant-Aware Journal Helpers + Triggers
-- ================================================================
-- Rewrites every trigger function so cross-tenant journal corruption
-- is impossible at the database level.
--
-- WHY THIS IS CRITICAL:
--   The original add_journal_line() does:
--       SELECT id FROM accounts WHERE name = p_account_name LIMIT 1;
--   With multiple tenants, 'Cash' exists in every tenant — so the
--   LIMIT 1 picks an arbitrary one. A fee assigned in Tenant A could
--   credit Tenant B's "Tuition Fees" account. That's data poisoning.
--
-- CHANGES:
--   * add_journal_line()       now requires p_tenant_id
--   * create_journal_entry()   now requires p_tenant_id, stamps journal_entries
--   * All 6 trigger functions  pass NEW.tenant_id
--   * journal_lines.tenant_id  set from p_tenant_id (denormalized)
--
-- UPGRADE BEYOND THE PLAN:
--   * trg_payment_advance_journal() and trg_payment_allocation_journal()
--     are updated even though the plan didn't list them explicitly.
--   * RAISE EXCEPTION messages include tenant_id for forensic debugging.
-- ================================================================

-- ─── Helper 1: create_journal_entry ────────────────────────────
DROP FUNCTION IF EXISTS create_journal_entry(DATE, TEXT) CASCADE;

CREATE OR REPLACE FUNCTION create_journal_entry(
    p_date        DATE,
    p_description TEXT,
    p_tenant_id   UUID
) RETURNS INT AS $$
DECLARE
    v_journal_id INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'create_journal_entry: tenant_id must not be NULL';
    END IF;

    INSERT INTO journal_entries (date, description, tenant_id)
    VALUES (p_date, p_description, p_tenant_id)
    RETURNING id INTO v_journal_id;

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

-- ─── Helper 2: add_journal_line ────────────────────────────────
DROP FUNCTION IF EXISTS add_journal_line(INT, TEXT, NUMERIC, NUMERIC) CASCADE;

CREATE OR REPLACE FUNCTION add_journal_line(
    p_journal_id    INT,
    p_account_name  TEXT,
    p_debit         NUMERIC,
    p_credit        NUMERIC,
    p_tenant_id     UUID
) RETURNS VOID AS $$
DECLARE
    v_account_id INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'add_journal_line: tenant_id must not be NULL';
    END IF;

    -- Tenant-scoped account lookup. Unique by (tenant_id, name) per migration 014.
    SELECT id INTO v_account_id
    FROM accounts
    WHERE name = p_account_name
      AND tenant_id = p_tenant_id
      AND COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Account "%" not found for tenant %', p_account_name, p_tenant_id;
    END IF;

    INSERT INTO journal_lines (journal_id, account_id, debit, credit, tenant_id)
    VALUES (p_journal_id, v_account_id, p_debit, p_credit, p_tenant_id);
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 1: fee_assignment → Dr Accounts Receivable / Cr Tuition
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_fee_assignment_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
BEGIN
    v_journal_id := create_journal_entry(
        NEW.month,
        'Fee assigned for student ' || NEW.student_id,
        NEW.tenant_id
    );

    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', NEW.amount, 0,           NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Tuition Fees',         0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 2: payment_allocation → Dr Cash / Cr Accounts Receivable
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_payment_allocation_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_payment RECORD;
    v_journal_id INT;
BEGIN
    SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;

    -- Safety: payment.tenant_id must equal allocation.tenant_id
    IF v_payment.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant allocation forbidden: payment % tenant %, allocation tenant %',
            NEW.payment_id, v_payment.tenant_id, NEW.tenant_id;
    END IF;

    v_journal_id := create_journal_entry(
        v_payment.date,
        'Payment allocation for student ' || v_payment.student_id,
        NEW.tenant_id
    );

    PERFORM add_journal_line(v_journal_id, 'Cash',                NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', 0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 3: payment (advance portion) → Dr Cash / Cr Unearned Revenue
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_payment_advance_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_allocated NUMERIC;
    v_remaining NUMERIC;
    v_journal_id INT;
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO v_allocated
    FROM payment_allocations
    WHERE payment_id = NEW.id;

    v_remaining := NEW.amount - v_allocated;

    IF v_remaining > 0 THEN
        v_journal_id := create_journal_entry(
            NEW.date,
            'Advance payment from student ' || NEW.student_id,
            NEW.tenant_id
        );
        PERFORM add_journal_line(v_journal_id, 'Cash',             v_remaining, 0,           NEW.tenant_id);
        PERFORM add_journal_line(v_journal_id, 'Unearned Revenue', 0,           v_remaining, NEW.tenant_id);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 4: expense → Dr <expense account> / Cr Cash
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_expense_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
    v_account_name TEXT;
    v_account_tenant UUID;
BEGIN
    SELECT name, tenant_id INTO v_account_name, v_account_tenant
    FROM accounts WHERE id = NEW.account_id;

    -- Safety: expense.tenant_id must equal account.tenant_id
    IF v_account_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant expense forbidden: expense tenant %, account % tenant %',
            NEW.tenant_id, NEW.account_id, v_account_tenant;
    END IF;

    v_journal_id := create_journal_entry(
        NEW.date,
        'Expense: ' || v_account_name,
        NEW.tenant_id
    );
    PERFORM add_journal_line(v_journal_id, v_account_name, NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Cash',         0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 5: salary → Dr Salary Expense / Cr Cash
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_salary_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
BEGIN
    v_journal_id := create_journal_entry(
        NEW.date,
        'Salary paid to employee ' || NEW.employee_id,
        NEW.tenant_id
    );
    PERFORM add_journal_line(v_journal_id, 'Salary Expense', NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Cash',           0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ═════════════════════════════════════════════════════════════════
-- Trigger 6: income → Dr Cash / Cr <revenue account>
-- ═════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_income_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
    v_account_name TEXT;
    v_account_tenant UUID;
BEGIN
    SELECT name, tenant_id INTO v_account_name, v_account_tenant
    FROM accounts WHERE id = NEW.account_id;

    IF v_account_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant income forbidden: income tenant %, account % tenant %',
            NEW.tenant_id, NEW.account_id, v_account_tenant;
    END IF;

    v_journal_id := create_journal_entry(
        NEW.date,
        'Income: ' || v_account_name,
        NEW.tenant_id
    );
    PERFORM add_journal_line(v_journal_id, 'Cash',          NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, v_account_name,  0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─── Re-bind triggers (CREATE OR REPLACE only refreshes the body) ──
DROP TRIGGER IF EXISTS fee_assignment_after_insert    ON fee_assignments;
DROP TRIGGER IF EXISTS payment_allocation_after_insert ON payment_allocations;
DROP TRIGGER IF EXISTS payment_after_insert_advance   ON payments;
DROP TRIGGER IF EXISTS expense_after_insert           ON expenses;
DROP TRIGGER IF EXISTS salary_after_insert            ON salary_payments;
DROP TRIGGER IF EXISTS income_after_insert            ON income;

CREATE TRIGGER fee_assignment_after_insert     AFTER INSERT ON fee_assignments     FOR EACH ROW EXECUTE FUNCTION trg_fee_assignment_journal();
CREATE TRIGGER payment_allocation_after_insert AFTER INSERT ON payment_allocations FOR EACH ROW EXECUTE FUNCTION trg_payment_allocation_journal();
CREATE TRIGGER payment_after_insert_advance    AFTER INSERT ON payments            FOR EACH ROW EXECUTE FUNCTION trg_payment_advance_journal();
CREATE TRIGGER expense_after_insert            AFTER INSERT ON expenses            FOR EACH ROW EXECUTE FUNCTION trg_expense_journal();
CREATE TRIGGER salary_after_insert             AFTER INSERT ON salary_payments     FOR EACH ROW EXECUTE FUNCTION trg_salary_journal();
CREATE TRIGGER income_after_insert             AFTER INSERT ON income              FOR EACH ROW EXECUTE FUNCTION trg_income_journal();

-- finalize_payment() helper used by the API — also update.
DROP FUNCTION IF EXISTS finalize_payment(INT);

CREATE OR REPLACE FUNCTION finalize_payment(p_payment_id INT)
RETURNS VOID AS $$
DECLARE
    v_payment RECORD;
    v_allocated NUMERIC;
    v_remaining NUMERIC;
    v_journal_id INT;
BEGIN
    SELECT * INTO v_payment FROM payments WHERE id = p_payment_id;
    IF v_payment.id IS NULL THEN
        RAISE EXCEPTION 'Payment % not found', p_payment_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_allocated
    FROM payment_allocations WHERE payment_id = p_payment_id;

    v_remaining := v_payment.amount - v_allocated;

    IF v_remaining > 0 THEN
        v_journal_id := create_journal_entry(
            v_payment.date,
            'Advance payment from student ' || v_payment.student_id,
            v_payment.tenant_id
        );
        PERFORM add_journal_line(v_journal_id, 'Cash',             v_remaining, 0,           v_payment.tenant_id);
        PERFORM add_journal_line(v_journal_id, 'Unearned Revenue', 0,           v_remaining, v_payment.tenant_id);
    END IF;
END;
$$ LANGUAGE plpgsql;
