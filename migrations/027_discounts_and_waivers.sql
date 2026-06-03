-- Migration 027: Discounts, Waivers, and Scholarships
-- ================================================================
-- WHY:
--   Real schools rarely charge every student the full fee. There are
--   sibling discounts, zakat scholarships, hardship waivers, staff-
--   child concessions. Up to migration 026 the only way to record
--   this was to lower fee_assignment.amount — losing the record of
--   "list price was X, we waived Y".
--
-- DESIGN:
--   * Keep fee_assignment.amount = gross / list price.
--   * New table fee_discounts(fee_assignment_id, amount, reason, …)
--     records the waiver. Multiple discounts per fee allowed (e.g.
--     5% sibling + 50% scholarship = two rows).
--   * Net fee = fee_assignment.amount − SUM(discounts).
--   * Trigger posts journal entry on each discount:
--       Dr  Fee Discount       (expense — contra-revenue)
--       Cr  Accounts Receivable
--     This keeps the trial balance correct: revenue stays at gross,
--     discount expense increases, receivable drops.
--   * Allocation guard updated to use NET amount, not gross. This
--     prevents over-allocating against the discounted fee.
--   * Views updated to expose gross_amount, discount, net_amount.
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- 1. fee_discounts table
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fee_discounts (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    fee_assignment_id   INT  NOT NULL REFERENCES fee_assignments(id) ON DELETE CASCADE,

    -- A discount is recorded as a flat amount in money terms.
    -- The app layer can compute "10%" → amount, but we store the
    -- final money figure for auditability.
    amount              NUMERIC(12,2) NOT NULL CHECK (amount > 0),

    -- Optional: record the original percent so reports can show
    -- "5% sibling discount" instead of just the money figure.
    percent             NUMERIC(5,2)  NULL CHECK (percent IS NULL OR (percent > 0 AND percent <= 100)),

    reason              TEXT NOT NULL CHECK (reason IN (
        'sibling',
        'scholarship',
        'hardship',
        'zakat',
        'staff_child',
        'founder_waiver',
        'early_payment',
        'other'
    )),
    notes               TEXT,

    approved_by_id      UUID NOT NULL REFERENCES users(id),
    approved_at         TIMESTAMP NOT NULL DEFAULT NOW(),

    is_deleted          BOOLEAN DEFAULT FALSE,
    deleted_at          TIMESTAMP NULL,
    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_fee_discounts_tenant     ON fee_discounts(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fee_discounts_assignment ON fee_discounts(fee_assignment_id);
CREATE INDEX IF NOT EXISTS idx_fee_discounts_reason     ON fee_discounts(reason);

-- ────────────────────────────────────────────────────────────────
-- 2. Tenant consistency + total-discount-not-exceed-fee guard
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_fee_discount_validate()
RETURNS TRIGGER AS $$
DECLARE
    v_fee_amount     NUMERIC;
    v_fee_tenant     UUID;
    v_total_existing NUMERIC;
    v_total_paid     NUMERIC;
BEGIN
    SELECT amount, tenant_id INTO v_fee_amount, v_fee_tenant
    FROM fee_assignments WHERE id = NEW.fee_assignment_id;

    IF v_fee_tenant IS NULL THEN
        RAISE EXCEPTION 'fee_assignment % not found', NEW.fee_assignment_id;
    END IF;

    IF v_fee_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant discount forbidden: fee tenant %, discount tenant %',
            v_fee_tenant, NEW.tenant_id;
    END IF;

    -- Sum existing non-deleted discounts on the same fee (exclude self on UPDATE)
    SELECT COALESCE(SUM(amount), 0) INTO v_total_existing
    FROM fee_discounts
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND is_deleted = FALSE
      AND id != COALESCE(NEW.id, 0);

    IF (v_total_existing + NEW.amount) > v_fee_amount THEN
        RAISE EXCEPTION 'Total discounts (%) would exceed fee amount (%) for fee %',
            v_total_existing + NEW.amount, v_fee_amount, NEW.fee_assignment_id;
    END IF;

    -- Don't allow discount that would make net < already-allocated payments.
    SELECT COALESCE(SUM(amount), 0) INTO v_total_paid
    FROM payment_allocations
    WHERE fee_assignment_id = NEW.fee_assignment_id;

    IF (v_fee_amount - (v_total_existing + NEW.amount)) < v_total_paid THEN
        RAISE EXCEPTION 'Discount would make net fee (%) less than already-paid (%) on fee %',
            v_fee_amount - (v_total_existing + NEW.amount), v_total_paid, NEW.fee_assignment_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS fee_discount_validate ON fee_discounts;
CREATE TRIGGER fee_discount_validate
BEFORE INSERT OR UPDATE ON fee_discounts
FOR EACH ROW
EXECUTE FUNCTION trg_fee_discount_validate();

-- ────────────────────────────────────────────────────────────────
-- 3. Auto-post journal entry on discount creation
--      Dr Fee Discount  / Cr Accounts Receivable
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_fee_discount_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
BEGIN
    v_journal_id := create_journal_entry(
        CURRENT_DATE,
        'Fee discount (' || NEW.reason || ') on assignment ' || NEW.fee_assignment_id,
        NEW.tenant_id
    );

    PERFORM add_journal_line(v_journal_id, 'Fee Discount',         NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable',  0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS fee_discount_after_insert ON fee_discounts;
CREATE TRIGGER fee_discount_after_insert
AFTER INSERT ON fee_discounts
FOR EACH ROW
EXECUTE FUNCTION trg_fee_discount_journal();

-- ────────────────────────────────────────────────────────────────
-- 4. Update allocation guard to use NET fee amount (gross − discounts)
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_check_allocation_limits()
RETURNS TRIGGER AS $$
DECLARE
    v_fee_amount              NUMERIC;
    v_fee_discounts           NUMERIC;
    v_fee_net                 NUMERIC;
    v_fee_total_allocated     NUMERIC;
    v_fee_tenant              UUID;
    v_payment_amount          NUMERIC;
    v_payment_total_allocated NUMERIC;
    v_payment_tenant          UUID;
BEGIN
    SELECT amount, tenant_id INTO v_fee_amount, v_fee_tenant
    FROM fee_assignments
    WHERE id = NEW.fee_assignment_id;

    SELECT amount, tenant_id INTO v_payment_amount, v_payment_tenant
    FROM payments
    WHERE id = NEW.payment_id;

    IF v_fee_tenant IS NULL THEN
        RAISE EXCEPTION 'fee_assignment % not found', NEW.fee_assignment_id;
    END IF;
    IF v_payment_tenant IS NULL THEN
        RAISE EXCEPTION 'payment % not found', NEW.payment_id;
    END IF;
    IF v_fee_tenant <> v_payment_tenant THEN
        RAISE EXCEPTION 'Cross-tenant allocation forbidden: fee tenant %, payment tenant %',
            v_fee_tenant, v_payment_tenant;
    END IF;
    IF NEW.tenant_id <> v_fee_tenant THEN
        RAISE EXCEPTION 'allocation.tenant_id (%) does not match fee/payment tenant (%)',
            NEW.tenant_id, v_fee_tenant;
    END IF;

    -- Compute NET fee = gross − active discounts
    SELECT COALESCE(SUM(amount), 0) INTO v_fee_discounts
    FROM fee_discounts
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND is_deleted = FALSE;

    v_fee_net := v_fee_amount - v_fee_discounts;

    -- Fee over-allocation check (against NET)
    SELECT COALESCE(SUM(amount), 0) INTO v_fee_total_allocated
    FROM payment_allocations
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND id != COALESCE(NEW.id, 0);

    IF (v_fee_total_allocated + NEW.amount) > v_fee_net THEN
        RAISE EXCEPTION 'Allocation would exceed NET fee. Gross: %, Discounts: %, Net: %, Already allocated: %, Attempted: %',
            v_fee_amount, v_fee_discounts, v_fee_net, v_fee_total_allocated, NEW.amount;
    END IF;

    -- Payment over-allocation check (against payment amount)
    SELECT COALESCE(SUM(amount), 0) INTO v_payment_total_allocated
    FROM payment_allocations
    WHERE payment_id = NEW.payment_id
      AND id != COALESCE(NEW.id, 0);

    IF (v_payment_total_allocated + NEW.amount) > v_payment_amount THEN
        RAISE EXCEPTION 'Allocation would exceed payment amount. Payment: %, Already allocated: %, Attempted: %',
            v_payment_amount, v_payment_total_allocated, NEW.amount;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger binding is unchanged; only the function body was updated.

-- ────────────────────────────────────────────────────────────────
-- 5. Update fee_detail_summary view to expose discount + net
-- ────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS fee_detail_summary;

CREATE VIEW fee_detail_summary AS
SELECT
    f.id            AS fee_id,
    f.student_id,
    s.name          AS student_name,
    s.class         AS class_name,
    s.class_id,
    s.section_id,
    f.tenant_id,
    f.fee_type_id,
    ft.name         AS fee_type_name,
    f.month,
    f.amount                                                AS gross_amount,
    COALESCE(disc.total, 0)                                 AS discount,
    f.amount - COALESCE(disc.total, 0)                      AS net_amount,
    COALESCE(alloc.paid, 0)                                 AS paid,
    (f.amount - COALESCE(disc.total, 0)) - COALESCE(alloc.paid, 0) AS due
FROM fee_assignments f
JOIN students s ON s.id = f.student_id AND s.tenant_id = f.tenant_id
LEFT JOIN fee_types ft ON ft.id = f.fee_type_id AND ft.tenant_id = f.tenant_id
LEFT JOIN (
    SELECT fee_assignment_id, SUM(amount) AS total
    FROM fee_discounts
    WHERE is_deleted = FALSE
    GROUP BY fee_assignment_id
) disc ON disc.fee_assignment_id = f.id
LEFT JOIN (
    SELECT fee_assignment_id, SUM(amount) AS paid
    FROM payment_allocations
    GROUP BY fee_assignment_id
) alloc ON alloc.fee_assignment_id = f.id
WHERE f.is_deleted = FALSE
  AND s.is_deleted = FALSE
ORDER BY f.month, s.name;

-- ────────────────────────────────────────────────────────────────
-- 6. Update student_due_summary to net out discounts
-- ────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS student_due_summary;

CREATE VIEW student_due_summary AS
SELECT
    s.id,
    s.name,
    s.class,
    s.class_id,
    s.section_id,
    s.tenant_id,
    COALESCE(fees.total, 0)                                                                          AS gross_fee,
    COALESCE(disc.total, 0)                                                                          AS total_discount,
    COALESCE(fees.total, 0) - COALESCE(disc.total, 0)                                                AS total_fee,
    COALESCE(alloc.total, 0)                                                                         AS total_paid,
    GREATEST(COALESCE(fees.total, 0) - COALESCE(disc.total, 0) - COALESCE(alloc.total, 0), 0)        AS due,
    GREATEST(COALESCE(paid.total, 0) - (COALESCE(fees.total, 0) - COALESCE(disc.total, 0)), 0)       AS advance,
    last_pay.last_payment_date
FROM students s
LEFT JOIN (
    SELECT student_id, tenant_id, SUM(amount) AS total
    FROM fee_assignments
    WHERE is_deleted = FALSE
    GROUP BY student_id, tenant_id
) fees ON s.id = fees.student_id AND s.tenant_id = fees.tenant_id
LEFT JOIN (
    SELECT f.student_id, f.tenant_id, SUM(d.amount) AS total
    FROM fee_discounts d
    JOIN fee_assignments f ON f.id = d.fee_assignment_id
    WHERE d.is_deleted = FALSE AND f.is_deleted = FALSE
    GROUP BY f.student_id, f.tenant_id
) disc ON s.id = disc.student_id AND s.tenant_id = disc.tenant_id
LEFT JOIN (
    SELECT f.student_id, f.tenant_id, SUM(pa.amount) AS total
    FROM payment_allocations pa
    JOIN fee_assignments f ON pa.fee_assignment_id = f.id
    WHERE f.is_deleted = FALSE
    GROUP BY f.student_id, f.tenant_id
) alloc ON s.id = alloc.student_id AND s.tenant_id = alloc.tenant_id
LEFT JOIN (
    SELECT student_id, tenant_id, SUM(amount) AS total
    FROM payments
    WHERE is_deleted = FALSE AND status = 'completed'
    GROUP BY student_id, tenant_id
) paid ON s.id = paid.student_id AND s.tenant_id = paid.tenant_id
LEFT JOIN (
    SELECT student_id, tenant_id, MAX(date) AS last_payment_date
    FROM payments
    WHERE is_deleted = FALSE AND status = 'completed'
    GROUP BY student_id, tenant_id
) last_pay ON s.id = last_pay.student_id AND s.tenant_id = last_pay.tenant_id
WHERE s.is_deleted = FALSE;

COMMENT ON TABLE fee_discounts IS
'Per-fee-assignment waivers. Multiple rows allowed per fee. Auto-posts Dr Fee Discount / Cr Accounts Receivable.';
