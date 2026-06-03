-- Migration 009: Dashboard Summary View
-- Single-row view for the owner's home screen.
--
-- Returns:
--   today_collection   — sum of completed, non-deleted payments dated today
--   today_expense      — sum of non-deleted expenses dated today
--   total_students     — count of active (non-deleted) students
--   total_due          — total unpaid fees (fees - allocations), floored at 0
--   cash_balance       — net cash position from journal entries on the Cash account
--
-- Corner cases handled:
--   ✅ Soft-deleted payments/expenses/fees excluded
--   ✅ Only 'completed' payments counted for collection
--   ✅ total_due cannot go negative (GREATEST(..., 0))
--   ✅ cash_balance derived from journal ledger (Dr Cash - Cr Cash)
--   ✅ Only non-reversed journal entries counted for cash balance
--
-- Queryable via Supabase:
--   supabase.table("dashboard_summary").select("*").execute()

CREATE OR REPLACE VIEW dashboard_summary AS
SELECT

    -- Today's collection: only completed, non-deleted payments dated today
    (
        SELECT COALESCE(SUM(amount), 0)
        FROM payments
        WHERE date = CURRENT_DATE
          AND is_deleted = FALSE
          AND status = 'completed'
    ) AS today_collection,

    -- Today's expense: only non-deleted expenses dated today
    (
        SELECT COALESCE(SUM(amount), 0)
        FROM expenses
        WHERE date = CURRENT_DATE
          AND is_deleted = FALSE
    ) AS today_expense,

    -- Total active students
    (
        SELECT COUNT(*)
        FROM students
        WHERE is_deleted = FALSE
    ) AS total_students,

    -- Total due: fees - allocations, floored at 0
    -- Uses subqueries to avoid cartesian join
    GREATEST(
        (
            SELECT COALESCE(SUM(amount), 0)
            FROM fee_assignments
            WHERE is_deleted = FALSE
        )
        -
        (
            SELECT COALESCE(SUM(pa.amount), 0)
            FROM payment_allocations pa
            JOIN fee_assignments f ON pa.fee_assignment_id = f.id
            WHERE f.is_deleted = FALSE
        ),
        0
    ) AS total_due,

    -- Cash balance: net position from the journal ledger
    -- Dr Cash increases balance, Cr Cash decreases it
    -- Only non-reversed journal entries counted
    (
        SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
        FROM journal_lines jl
        JOIN journal_entries je ON jl.journal_id = je.id
        JOIN accounts a ON jl.account_id = a.id
        WHERE a.name = 'Cash'
          AND je.is_reversed = FALSE
    ) AS cash_balance;
