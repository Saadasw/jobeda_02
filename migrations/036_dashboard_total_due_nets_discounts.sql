-- Migration 036: Dashboard total_due nets out discounts
-- ================================================================
-- BUG: get_dashboard_summary.total_due used GROSS fee amounts
--   (Σ fee_assignments.amount − Σ allocations), so it ignored the fee
--   discounts added in migration 027. The per-student student_due_summary
--   view DID net discounts out, so the dashboard's "Total Due" overstated
--   the real figure by the sum of all discounts (e.g. 18,000 vs the true
--   17,500 in the demo — the 500 sibling discount).
--
-- FIX: subtract active discounts (on non-deleted fees) as well, so the
--   dashboard's Total Due equals the sum of per-student dues:
--       net due = Σ gross fees − Σ discounts − Σ allocations  (floored at 0)
--
-- Function-only change (computed on read) — no data backfill needed.
-- ================================================================

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

        -- Outstanding due, NET of discounts:
        --   Σ gross fees − Σ discounts − Σ allocations, floored at 0
        GREATEST(
            (
                SELECT COALESCE(SUM(amount), 0)
                FROM fee_assignments
                WHERE is_deleted = FALSE
                  AND tenant_id = p_tenant_id
            )
            -
            (
                SELECT COALESCE(SUM(d.amount), 0)
                FROM fee_discounts d
                JOIN fee_assignments f ON f.id = d.fee_assignment_id
                WHERE d.is_deleted = FALSE
                  AND f.is_deleted = FALSE
                  AND f.tenant_id = p_tenant_id
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
'Dashboard KPIs. total_due is NET of discounts (matches student_due_summary).';
