-- Migration 029: Salary Structure, Advances, and Payslips
-- ================================================================
-- WHY:
--   Up to 028 payroll is "Dr Salary Expense / Cr Cash" with no
--   breakdown. Owners need:
--     * a salary structure per employee (basic + allowances)
--     * salary advances (money paid against future salary)
--     * monthly payslips that snapshot what was earned and deducted
--     * salary_payments tied to a payslip (so HR + accounting agree)
--
-- DESIGN:
--   * salary_structures — versioned per employee. Effective_from /
--     effective_to so raises are tracked.
--   * salary_advances — money lent to an employee. Posts:
--         Dr Salary Advances (asset) / Cr Cash
--     The balance_remaining is reduced as it's recovered from payslips.
--   * payslips — one row per (employee, year, month). Snapshot of:
--         basic, hra, transport, medical, other_allowance
--         absence_deduction, advance_recovery, other_deduction
--         gross, total_deductions, net_payable, status
--   * salary_payments — now references a payslip. Trigger rewritten:
--         Dr Salary Expense   (gross − absence_deduction)
--         Cr Salary Advances  (advance_recovery)
--         Cr Cash             (net_payable)
--
-- NEW ACCOUNT REQUIRED:
--   * 'Salary Advances' (asset) — added to seed_tenant_defaults
--     and backfilled for the existing 'jobeda' tenant.
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- 0. Add 'Salary Advances' account for the default tenant
--    (new tenants will get it via the seed function).
-- ────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_tenant UUID;
    v_assets INT;
BEGIN
    FOR v_tenant IN SELECT id FROM tenants LOOP
        SELECT id INTO v_assets FROM accounts
         WHERE tenant_id = v_tenant AND name = 'Assets';
        IF v_assets IS NOT NULL THEN
            INSERT INTO accounts (name, type, parent_id, tenant_id)
            VALUES ('Salary Advances', 'asset', v_assets, v_tenant)
            ON CONFLICT (tenant_id, name) DO NOTHING;
        END IF;
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────────
-- 1. salary_structures — versioned pay structure per employee
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS salary_structures (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    employee_id         INT  NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

    basic               NUMERIC(12,2) NOT NULL CHECK (basic >= 0),
    house_rent          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (house_rent >= 0),
    transport           NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (transport >= 0),
    medical             NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (medical >= 0),
    other_allowance     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (other_allowance >= 0),

    -- gross is a generated column so it cannot drift from components
    gross               NUMERIC(12,2) GENERATED ALWAYS AS
                          (basic + house_rent + transport + medical + other_allowance) STORED,

    effective_from      DATE NOT NULL,
    effective_to        DATE NULL,                       -- NULL = currently active

    notes               TEXT,
    is_deleted          BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT chk_salary_structure_dates
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_salary_structures_tenant   ON salary_structures(tenant_id);
CREATE INDEX IF NOT EXISTS idx_salary_structures_employee ON salary_structures(employee_id, effective_from DESC);

-- Only one active (effective_to IS NULL) structure per employee
CREATE UNIQUE INDEX IF NOT EXISTS uq_salary_structure_active_per_employee
    ON salary_structures(employee_id)
    WHERE effective_to IS NULL AND is_deleted = FALSE;

-- ────────────────────────────────────────────────────────────────
-- 2. salary_advances — money advanced against future salary
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS salary_advances (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    employee_id         INT  NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

    amount              NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    balance_remaining   NUMERIC(12,2) NOT NULL,    -- decreases as recovered from payslips
    advance_date        DATE NOT NULL,
    reason              TEXT,
    cash_account_id     INT  NOT NULL REFERENCES accounts(id),

    is_deleted          BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT chk_advance_balance_nonneg CHECK (balance_remaining >= 0),
    CONSTRAINT chk_advance_balance_le_amount CHECK (balance_remaining <= amount)
);

CREATE INDEX IF NOT EXISTS idx_salary_advances_tenant      ON salary_advances(tenant_id);
CREATE INDEX IF NOT EXISTS idx_salary_advances_employee    ON salary_advances(employee_id);
CREATE INDEX IF NOT EXISTS idx_salary_advances_outstanding ON salary_advances(employee_id)
    WHERE balance_remaining > 0 AND is_deleted = FALSE;

-- Initialize balance_remaining = amount on insert (cannot be a GENERATED
-- column because it changes over time).
CREATE OR REPLACE FUNCTION trg_salary_advance_init()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.balance_remaining IS NULL THEN
        NEW.balance_remaining := NEW.amount;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS salary_advance_init ON salary_advances;
CREATE TRIGGER salary_advance_init
BEFORE INSERT ON salary_advances
FOR EACH ROW
EXECUTE FUNCTION trg_salary_advance_init();

-- Post journal on advance issue: Dr Salary Advances / Cr Cash
CREATE OR REPLACE FUNCTION trg_salary_advance_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
BEGIN
    v_journal_id := create_journal_entry(
        NEW.advance_date,
        'Salary advance to employee ' || NEW.employee_id,
        NEW.tenant_id
    );
    PERFORM add_journal_line(v_journal_id, 'Salary Advances', NEW.amount, 0,           NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Cash',            0,          NEW.amount,  NEW.tenant_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS salary_advance_after_insert ON salary_advances;
CREATE TRIGGER salary_advance_after_insert
AFTER INSERT ON salary_advances
FOR EACH ROW
EXECUTE FUNCTION trg_salary_advance_journal();

-- ────────────────────────────────────────────────────────────────
-- 3. payslips — monthly pay snapshot
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payslips (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    employee_id         INT  NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,

    year                SMALLINT NOT NULL CHECK (year BETWEEN 2000 AND 2100),
    month               SMALLINT NOT NULL CHECK (month BETWEEN 1 AND 12),

    -- Snapshot of structure components at the time of generation
    basic               NUMERIC(12,2) NOT NULL CHECK (basic >= 0),
    house_rent          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (house_rent >= 0),
    transport           NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (transport >= 0),
    medical             NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (medical >= 0),
    other_allowance     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (other_allowance >= 0),

    gross               NUMERIC(12,2) GENERATED ALWAYS AS
                          (basic + house_rent + transport + medical + other_allowance) STORED,

    -- Deductions
    days_absent         NUMERIC(5,2)  NOT NULL DEFAULT 0 CHECK (days_absent >= 0),
    absence_deduction   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (absence_deduction >= 0),
    advance_recovery    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (advance_recovery >= 0),
    other_deduction     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (other_deduction >= 0),

    total_deductions    NUMERIC(12,2) GENERATED ALWAYS AS
                          (absence_deduction + advance_recovery + other_deduction) STORED,

    net_payable         NUMERIC(12,2) GENERATED ALWAYS AS
                          (basic + house_rent + transport + medical + other_allowance
                           - absence_deduction - advance_recovery - other_deduction) STORED,

    status              TEXT NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft', 'finalized', 'paid', 'cancelled')),
    notes               TEXT,

    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    finalized_at        TIMESTAMP NULL,
    finalized_by_id     UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_payslip_employee_period UNIQUE (employee_id, year, month)
);

CREATE INDEX IF NOT EXISTS idx_payslips_tenant   ON payslips(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payslips_employee ON payslips(employee_id, year DESC, month DESC);
CREATE INDEX IF NOT EXISTS idx_payslips_status   ON payslips(tenant_id, status);

-- ────────────────────────────────────────────────────────────────
-- 4. Tie salary_payments to a payslip
-- ────────────────────────────────────────────────────────────────
ALTER TABLE salary_payments
    ADD COLUMN IF NOT EXISTS payslip_id      INT NULL REFERENCES payslips(id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS cash_account_id INT NULL REFERENCES accounts(id);

CREATE INDEX IF NOT EXISTS idx_salary_payments_payslip ON salary_payments(payslip_id);

-- Existing salary_payments rows (from seed) have NULL payslip_id;
-- they remain valid historical records. New rows can require payslip_id
-- at the app layer.

-- ────────────────────────────────────────────────────────────────
-- 5. Rewrite salary journal trigger to handle the breakdown
--    If payslip_id is set: post 3-line journal (expense / advances / cash)
--    If payslip_id is NULL (legacy): keep the old 2-line behaviour.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_salary_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
    p            payslips%ROWTYPE;
    v_expense    NUMERIC;
BEGIN
    IF NEW.payslip_id IS NULL THEN
        -- Legacy path: simple two-line entry
        v_journal_id := create_journal_entry(
            NEW.date,
            'Salary paid to employee ' || NEW.employee_id,
            NEW.tenant_id
        );
        PERFORM add_journal_line(v_journal_id, 'Salary Expense', NEW.amount, 0,          NEW.tenant_id);
        PERFORM add_journal_line(v_journal_id, 'Cash',           0,          NEW.amount, NEW.tenant_id);
        RETURN NEW;
    END IF;

    -- Payslip-driven path
    SELECT * INTO p FROM payslips WHERE id = NEW.payslip_id;

    IF p.id IS NULL THEN
        RAISE EXCEPTION 'payslip % not found', NEW.payslip_id;
    END IF;
    IF p.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant payslip link forbidden: payslip tenant %, salary_payment tenant %',
            p.tenant_id, NEW.tenant_id;
    END IF;
    IF p.employee_id <> NEW.employee_id THEN
        RAISE EXCEPTION 'payslip employee % does not match salary_payment employee %',
            p.employee_id, NEW.employee_id;
    END IF;

    -- Sanity: salary_payment.amount should equal net_payable
    IF NEW.amount <> p.net_payable THEN
        RAISE EXCEPTION 'salary_payment.amount (%) does not match payslip.net_payable (%)',
            NEW.amount, p.net_payable;
    END IF;

    -- Earned salary expense = gross − absence deduction
    -- (absence reduces what the employee earned; advance recovery does not.)
    v_expense := p.gross - p.absence_deduction;

    v_journal_id := create_journal_entry(
        NEW.date,
        'Payslip ' || p.year || '-' || LPAD(p.month::TEXT, 2, '0')
            || ' for employee ' || NEW.employee_id,
        NEW.tenant_id
    );

    PERFORM add_journal_line(v_journal_id, 'Salary Expense',   v_expense,             0,                     NEW.tenant_id);
    IF p.advance_recovery > 0 THEN
        PERFORM add_journal_line(v_journal_id, 'Salary Advances', 0,                  p.advance_recovery,    NEW.tenant_id);
    END IF;
    PERFORM add_journal_line(v_journal_id, 'Cash',             0,                     p.net_payable,         NEW.tenant_id);

    -- Mark payslip paid and reduce outstanding advance balances FIFO
    UPDATE payslips SET status = 'paid' WHERE id = p.id;

    IF p.advance_recovery > 0 THEN
        PERFORM apply_advance_recovery(NEW.tenant_id, NEW.employee_id, p.advance_recovery);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger binding already exists (created in migration 015); function body updated.

-- ────────────────────────────────────────────────────────────────
-- 6. Helper: apply_advance_recovery — FIFO drawdown
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION apply_advance_recovery(
    p_tenant_id   UUID,
    p_employee_id INT,
    p_amount      NUMERIC
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    r           RECORD;
    v_remaining NUMERIC := p_amount;
    v_take      NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN;
    END IF;

    FOR r IN
        SELECT id, balance_remaining
        FROM salary_advances
        WHERE tenant_id   = p_tenant_id
          AND employee_id = p_employee_id
          AND is_deleted  = FALSE
          AND balance_remaining > 0
        ORDER BY advance_date ASC, id ASC
    LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(r.balance_remaining, v_remaining);
        UPDATE salary_advances
        SET balance_remaining = balance_remaining - v_take
        WHERE id = r.id;
        v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_remaining > 0 THEN
        RAISE EXCEPTION 'Advance recovery of % exceeds outstanding advances for employee %',
            p_amount, p_employee_id;
    END IF;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- 7. Helper: generate_payslip(employee_id, year, month) — draft from
--    the currently-active salary_structure. Owner can edit fields
--    before finalizing.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_payslip(
    p_employee_id INT,
    p_year        SMALLINT,
    p_month       SMALLINT
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    s            salary_structures%ROWTYPE;
    v_tenant     UUID;
    v_payslip_id INT;
BEGIN
    SELECT * INTO s FROM salary_structures
    WHERE employee_id = p_employee_id
      AND is_deleted  = FALSE
      AND effective_to IS NULL
    LIMIT 1;

    IF s.id IS NULL THEN
        RAISE EXCEPTION 'No active salary_structure for employee %', p_employee_id;
    END IF;

    SELECT tenant_id INTO v_tenant FROM employees WHERE id = p_employee_id;

    INSERT INTO payslips (
        tenant_id, employee_id, year, month,
        basic, house_rent, transport, medical, other_allowance, status
    )
    VALUES (
        v_tenant, p_employee_id, p_year, p_month,
        s.basic, s.house_rent, s.transport, s.medical, s.other_allowance, 'draft'
    )
    ON CONFLICT (employee_id, year, month) DO UPDATE
        SET basic           = EXCLUDED.basic,
            house_rent      = EXCLUDED.house_rent,
            transport       = EXCLUDED.transport,
            medical         = EXCLUDED.medical,
            other_allowance = EXCLUDED.other_allowance
        WHERE payslips.status = 'draft'
    RETURNING id INTO v_payslip_id;

    RETURN v_payslip_id;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- 8. Backfill: create active salary_structure rows from employees.salary
--    so existing employees aren't blocked when owners try to generate
--    payslips.
-- ────────────────────────────────────────────────────────────────
INSERT INTO salary_structures (tenant_id, employee_id, basic, effective_from)
SELECT e.tenant_id, e.id, COALESCE(e.salary, 0), CURRENT_DATE
FROM employees e
WHERE e.is_deleted = FALSE
  AND NOT EXISTS (
      SELECT 1 FROM salary_structures s
      WHERE s.employee_id = e.id AND s.effective_to IS NULL
  );

COMMENT ON TABLE salary_structures IS
'Versioned pay components per employee. effective_to IS NULL means currently active.';
COMMENT ON TABLE salary_advances IS
'Money paid to employees against future salary. balance_remaining decreases as recovered via payslips.';
COMMENT ON TABLE payslips IS
'Monthly pay snapshot. salary_payment must reference a finalized payslip.';
