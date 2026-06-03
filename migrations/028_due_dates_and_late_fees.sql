-- Migration 028: Due Dates + Late Fee Policy
-- ================================================================
-- WHY:
--   Up to 027 a fee is "owed forever" — no due date, no late
--   penalty, no aging report. Owners need:
--     * a due_date on each fee (so reports can highlight overdue)
--     * an automatic late-fee mechanism using the tenant_settings
--       policy from migration 026
--     * an "aging" report (how much is 30/60/90 days overdue)
--
-- DESIGN:
--   * Add due_date + late_fee_amount + late_fee_applied_at columns
--     to fee_assignments. (Three columns instead of a side table —
--     simpler for views/allocation guard.)
--   * late_fee_amount is a running TOTAL — every time apply_late_fees()
--     finds the fee is still overdue and the policy demands more, it
--     bumps the column and posts ONE journal entry for the delta.
--     This makes the function idempotent within a single day.
--   * Net amount used everywhere now = (amount + late_fee_amount) − discounts.
--   * apply_late_fees(tenant_id, as_of) — owner runs nightly or on
--     demand. Safe to re-run.
--   * get_overdue_aging(tenant_id, as_of) — aging buckets for reports.
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- 1. Columns on fee_assignments
-- ────────────────────────────────────────────────────────────────
ALTER TABLE fee_assignments
    ADD COLUMN IF NOT EXISTS due_date              DATE NULL,
    ADD COLUMN IF NOT EXISTS late_fee_amount       NUMERIC(12,2) NOT NULL DEFAULT 0
        CHECK (late_fee_amount >= 0),
    ADD COLUMN IF NOT EXISTS late_fee_applied_at   TIMESTAMP NULL;

CREATE INDEX IF NOT EXISTS idx_fee_assignments_due_date
    ON fee_assignments(tenant_id, due_date)
    WHERE is_deleted = FALSE AND due_date IS NOT NULL;

-- Backfill: existing fee_assignments get a due_date = end of their
-- billing month (so they don't all become "overdue" on day 1 of
-- whichever date you run apply_late_fees).
UPDATE fee_assignments
SET due_date = (DATE_TRUNC('month', month) + INTERVAL '1 month - 1 day')::DATE
WHERE due_date IS NULL;

-- ────────────────────────────────────────────────────────────────
-- 2. Update allocation guard to use (gross + late_fee) − discounts
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_check_allocation_limits()
RETURNS TRIGGER AS $$
DECLARE
    v_fee_amount              NUMERIC;
    v_fee_late                NUMERIC;
    v_fee_discounts           NUMERIC;
    v_fee_net                 NUMERIC;
    v_fee_total_allocated     NUMERIC;
    v_fee_tenant              UUID;
    v_payment_amount          NUMERIC;
    v_payment_total_allocated NUMERIC;
    v_payment_tenant          UUID;
BEGIN
    SELECT amount, late_fee_amount, tenant_id
        INTO v_fee_amount, v_fee_late, v_fee_tenant
    FROM fee_assignments WHERE id = NEW.fee_assignment_id;

    SELECT amount, tenant_id INTO v_payment_amount, v_payment_tenant
    FROM payments WHERE id = NEW.payment_id;

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

    SELECT COALESCE(SUM(amount), 0) INTO v_fee_discounts
    FROM fee_discounts
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND is_deleted = FALSE;

    v_fee_net := (v_fee_amount + COALESCE(v_fee_late, 0)) - v_fee_discounts;

    SELECT COALESCE(SUM(amount), 0) INTO v_fee_total_allocated
    FROM payment_allocations
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND id != COALESCE(NEW.id, 0);

    IF (v_fee_total_allocated + NEW.amount) > v_fee_net THEN
        RAISE EXCEPTION 'Allocation would exceed NET fee. Gross: %, Late: %, Discounts: %, Net: %, Already allocated: %, Attempted: %',
            v_fee_amount, v_fee_late, v_fee_discounts, v_fee_net, v_fee_total_allocated, NEW.amount;
    END IF;

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

-- ────────────────────────────────────────────────────────────────
-- 3. apply_late_fees(p_tenant_id, p_as_of)
--      Idempotent: re-runs do nothing once the fee has been charged
--      its policy-max for the current overdue window.
--      Returns: number of fee rows whose late_fee_amount changed.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION apply_late_fees(
    p_tenant_id UUID,
    p_as_of     DATE DEFAULT CURRENT_DATE
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    s            tenant_settings%ROWTYPE;
    r            RECORD;
    v_changed    INT := 0;
    v_due        NUMERIC;
    v_paid       NUMERIC;
    v_discount   NUMERIC;
    v_target     NUMERIC;  -- what late_fee_amount SHOULD be
    v_delta      NUMERIC;
    v_journal_id INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'apply_late_fees: tenant_id must not be NULL';
    END IF;

    SELECT * INTO s FROM tenant_settings WHERE tenant_id = p_tenant_id;

    IF NOT FOUND OR NOT s.late_fee_enabled THEN
        RETURN 0;
    END IF;

    FOR r IN
        SELECT f.id, f.amount, f.late_fee_amount, f.due_date
        FROM fee_assignments f
        WHERE f.tenant_id = p_tenant_id
          AND f.is_deleted = FALSE
          AND f.due_date IS NOT NULL
          AND p_as_of > (f.due_date + (s.late_fee_grace_days || ' days')::INTERVAL)::DATE
    LOOP
        -- Already-paid + discount on this fee
        SELECT COALESCE(SUM(amount), 0) INTO v_paid
        FROM payment_allocations
        WHERE fee_assignment_id = r.id;

        SELECT COALESCE(SUM(amount), 0) INTO v_discount
        FROM fee_discounts
        WHERE fee_assignment_id = r.id AND is_deleted = FALSE;

        v_due := (r.amount + COALESCE(r.late_fee_amount, 0)) - v_discount - v_paid;

        -- Fully paid → no penalty
        IF v_due <= 0 THEN
            CONTINUE;
        END IF;

        -- Policy: how much late fee SHOULD be on this fee right now.
        IF s.late_fee_type = 'flat' THEN
            v_target := s.late_fee_value;
        ELSE
            -- percent of (gross − discount). We don't compound on prior late fees.
            v_target := ROUND( ((r.amount - v_discount) * s.late_fee_value / 100.0)::NUMERIC, 2 );
        END IF;

        v_delta := v_target - COALESCE(r.late_fee_amount, 0);

        IF v_delta > 0 THEN
            UPDATE fee_assignments
            SET late_fee_amount     = COALESCE(late_fee_amount, 0) + v_delta,
                late_fee_applied_at = NOW()
            WHERE id = r.id;

            v_journal_id := create_journal_entry(
                p_as_of,
                'Late fee on fee_assignment ' || r.id,
                p_tenant_id
            );
            PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', v_delta, 0,         p_tenant_id);
            PERFORM add_journal_line(v_journal_id, 'Late Fee Income',     0,        v_delta,  p_tenant_id);

            v_changed := v_changed + 1;
        END IF;
    END LOOP;

    RETURN v_changed;
END;
$$;

COMMENT ON FUNCTION apply_late_fees(UUID, DATE) IS
'Scans tenant''s fee_assignments and applies the configured late_fee policy. Idempotent. Returns count of rows whose late_fee_amount changed.';

-- ────────────────────────────────────────────────────────────────
-- 4. get_overdue_aging — bucketed aging report
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_overdue_aging(
    p_tenant_id UUID,
    p_as_of     DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
    bucket           TEXT,
    fee_count        BIGINT,
    overdue_amount   NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH fee_status AS (
        SELECT
            f.id,
            (f.amount + COALESCE(f.late_fee_amount, 0)
                - COALESCE((SELECT SUM(amount) FROM fee_discounts d
                            WHERE d.fee_assignment_id = f.id AND d.is_deleted = FALSE), 0)
                - COALESCE((SELECT SUM(amount) FROM payment_allocations a
                            WHERE a.fee_assignment_id = f.id), 0)
            ) AS net_due,
            (p_as_of - f.due_date) AS days_overdue
        FROM fee_assignments f
        WHERE f.tenant_id = p_tenant_id
          AND f.is_deleted = FALSE
          AND f.due_date IS NOT NULL
          AND f.due_date < p_as_of
    )
    SELECT
        CASE
            WHEN days_overdue BETWEEN 1 AND 30   THEN '1-30 days'
            WHEN days_overdue BETWEEN 31 AND 60  THEN '31-60 days'
            WHEN days_overdue BETWEEN 61 AND 90  THEN '61-90 days'
            ELSE '90+ days'
        END                          AS bucket,
        COUNT(*)                     AS fee_count,
        SUM(net_due)                 AS overdue_amount
    FROM fee_status
    WHERE net_due > 0
    GROUP BY 1
    ORDER BY MIN(days_overdue);
$$;

COMMENT ON FUNCTION get_overdue_aging(UUID, DATE) IS
'Standard accounting aging report: 1-30, 31-60, 61-90, 90+ day buckets of overdue fees for a tenant.';

-- ────────────────────────────────────────────────────────────────
-- 5. Refresh views to include late_fee_amount
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
    f.due_date,
    f.amount                                                                  AS gross_amount,
    COALESCE(f.late_fee_amount, 0)                                            AS late_fee,
    COALESCE(disc.total, 0)                                                   AS discount,
    f.amount + COALESCE(f.late_fee_amount, 0) - COALESCE(disc.total, 0)       AS net_amount,
    COALESCE(alloc.paid, 0)                                                   AS paid,
    (f.amount + COALESCE(f.late_fee_amount, 0)
        - COALESCE(disc.total, 0) - COALESCE(alloc.paid, 0))                  AS due,
    CASE
        WHEN f.due_date IS NULL                                THEN 'no_due_date'
        WHEN COALESCE(alloc.paid, 0) >=
             (f.amount + COALESCE(f.late_fee_amount, 0) - COALESCE(disc.total, 0))
                                                               THEN 'paid'
        WHEN CURRENT_DATE > f.due_date                         THEN 'overdue'
        ELSE                                                        'upcoming'
    END                                                                       AS status
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

DROP VIEW IF EXISTS student_due_summary;

CREATE VIEW student_due_summary AS
SELECT
    s.id,
    s.name,
    s.class,
    s.class_id,
    s.section_id,
    s.tenant_id,
    COALESCE(fees.total, 0)                                                              AS gross_fee,
    COALESCE(fees.late_total, 0)                                                         AS late_fee,
    COALESCE(disc.total, 0)                                                              AS total_discount,
    COALESCE(fees.total, 0) + COALESCE(fees.late_total, 0) - COALESCE(disc.total, 0)     AS total_fee,
    COALESCE(alloc.total, 0)                                                             AS total_paid,
    GREATEST(
        COALESCE(fees.total, 0) + COALESCE(fees.late_total, 0)
            - COALESCE(disc.total, 0) - COALESCE(alloc.total, 0), 0
    )                                                                                    AS due,
    GREATEST(
        COALESCE(paid.total, 0) -
        (COALESCE(fees.total, 0) + COALESCE(fees.late_total, 0) - COALESCE(disc.total, 0)),
        0
    )                                                                                    AS advance,
    last_pay.last_payment_date
FROM students s
LEFT JOIN (
    SELECT student_id, tenant_id,
           SUM(amount) AS total,
           SUM(COALESCE(late_fee_amount, 0)) AS late_total
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
