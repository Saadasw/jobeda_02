-- Migration 016: Tenant-Aware Views + Dashboard Function
-- ================================================================
-- Updates the 3 SQL views to expose tenant_id so the application
-- layer can call `.eq("tenant_id", user.tenant_id)` against them.
--
-- KEY DECISION:
--   * `dashboard_summary` was a SINGLE-ROW aggregate view. With
--     multi-tenancy a single row can't represent N tenants.
--     We REPLACE the view with a function get_dashboard_summary(uuid)
--     called via supabase.rpc(...).
--   * `student_due_summary` and `fee_detail_summary` ADD a
--     `tenant_id` column so the app can filter normally.
--
-- UPGRADES BEYOND THE PLAN:
--   * Both views now expose section_id and class_id so the frontend
--     can drill down per class/section without an extra join.
--   * dashboard function returns `today_collection`, `today_expense`,
--     `total_students`, `total_due`, `cash_balance`,
--     `total_employees`, `pending_payments` (added 2 useful kpis).
-- ================================================================

-- ═══════════════════════════════════════════════════════════════
-- 1. student_due_summary  — per-student aggregate, scoped per tenant
-- ═══════════════════════════════════════════════════════════════
DROP VIEW IF EXISTS student_due_summary;

CREATE VIEW student_due_summary AS
SELECT
    s.id,
    s.name,
    s.class,
    s.class_id,
    s.section_id,
    s.tenant_id,
    COALESCE(fees.total, 0)                                          AS total_fee,
    COALESCE(alloc.total, 0)                                         AS total_paid,
    GREATEST(COALESCE(fees.total, 0) - COALESCE(alloc.total, 0), 0)  AS due,
    GREATEST(COALESCE(paid.total, 0) - COALESCE(fees.total, 0), 0)   AS advance,
    last_pay.last_payment_date
FROM students s
LEFT JOIN (
    SELECT student_id, tenant_id, SUM(amount) AS total
    FROM fee_assignments
    WHERE is_deleted = FALSE
    GROUP BY student_id, tenant_id
) fees ON s.id = fees.student_id AND s.tenant_id = fees.tenant_id
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

-- ═══════════════════════════════════════════════════════════════
-- 2. fee_detail_summary  — per-fee row, scoped per tenant
-- ═══════════════════════════════════════════════════════════════
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
    f.amount        AS fee_amount,
    COALESCE(alloc.paid, 0)                AS paid,
    f.amount - COALESCE(alloc.paid, 0)     AS due
FROM fee_assignments f
JOIN students s ON s.id = f.student_id AND s.tenant_id = f.tenant_id
LEFT JOIN fee_types ft ON ft.id = f.fee_type_id AND ft.tenant_id = f.tenant_id
LEFT JOIN (
    SELECT fee_assignment_id, SUM(amount) AS paid
    FROM payment_allocations
    GROUP BY fee_assignment_id
) alloc ON alloc.fee_assignment_id = f.id
WHERE f.is_deleted = FALSE
  AND s.is_deleted = FALSE
ORDER BY f.month, s.name;

-- ═══════════════════════════════════════════════════════════════
-- 3. dashboard_summary  — REPLACED by a tenant-parameterised function
-- ═══════════════════════════════════════════════════════════════
DROP VIEW IF EXISTS dashboard_summary;

CREATE OR REPLACE FUNCTION get_dashboard_summary(p_tenant_id UUID)
RETURNS TABLE (
    today_collection  NUMERIC,
    today_expense     NUMERIC,
    total_students    BIGINT,
    total_employees   BIGINT,
    total_due         NUMERIC,
    cash_balance      NUMERIC,
    pending_payments  BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        -- Today's collection
        (
            SELECT COALESCE(SUM(amount), 0)
            FROM payments
            WHERE date = CURRENT_DATE
              AND is_deleted = FALSE
              AND status = 'completed'
              AND tenant_id = p_tenant_id
        ) AS today_collection,

        -- Today's expense
        (
            SELECT COALESCE(SUM(amount), 0)
            FROM expenses
            WHERE date = CURRENT_DATE
              AND is_deleted = FALSE
              AND tenant_id = p_tenant_id
        ) AS today_expense,

        -- Active students
        (
            SELECT COUNT(*)
            FROM students
            WHERE is_deleted = FALSE
              AND tenant_id = p_tenant_id
        ) AS total_students,

        -- Active employees
        (
            SELECT COUNT(*)
            FROM employees
            WHERE is_deleted = FALSE
              AND tenant_id = p_tenant_id
        ) AS total_employees,

        -- Outstanding due (fees − allocations, floored at 0)
        GREATEST(
            (
                SELECT COALESCE(SUM(amount), 0)
                FROM fee_assignments
                WHERE is_deleted = FALSE
                  AND tenant_id = p_tenant_id
            )
            -
            (
                SELECT COALESCE(SUM(pa.amount), 0)
                FROM payment_allocations pa
                JOIN fee_assignments f ON pa.fee_assignment_id = f.id
                WHERE f.is_deleted = FALSE
                  AND f.tenant_id = p_tenant_id
            ),
            0
        ) AS total_due,

        -- Cash balance from journal lines for the tenant's "Cash" account
        (
            SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
            FROM journal_lines jl
            JOIN journal_entries je ON jl.journal_id = je.id
            JOIN accounts a ON jl.account_id = a.id
            WHERE a.name = 'Cash'
              AND a.tenant_id = p_tenant_id
              AND jl.tenant_id = p_tenant_id
              AND je.is_reversed = FALSE
        ) AS cash_balance,

        -- Pending payments count
        (
            SELECT COUNT(*)
            FROM payments
            WHERE status = 'pending'
              AND is_deleted = FALSE
              AND tenant_id = p_tenant_id
        ) AS pending_payments;
END;
$$;

COMMENT ON FUNCTION get_dashboard_summary(UUID) IS
'Replaces dashboard_summary view. Call via supabase.rpc("get_dashboard_summary", {"p_tenant_id": tenant_id}).';
