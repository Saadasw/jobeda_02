-- Migration 008: Fee Detail Summary View
-- Per-fee-assignment breakdown: how much was paid against each individual fee.
--
-- Unlike student_due_summary (aggregate per student), this shows EACH fee row
-- with its paid/due status. Useful for:
--   - "Show me which months Student X has/hasn't paid"
--   - "List all unpaid fees across all students"
--   - Monthly collection reports
--
-- Queryable via Supabase like a regular table:
--   supabase.table("fee_detail_summary").select("*").execute()
--   supabase.table("fee_detail_summary").select("*").eq("student_id", 1).execute()
--   supabase.table("fee_detail_summary").select("*").gt("due", 0).execute()
--   supabase.table("fee_detail_summary").select("*").eq("month", "2026-01-01").execute()

CREATE OR REPLACE VIEW fee_detail_summary AS
SELECT
    f.id           AS fee_id,
    f.student_id,
    s.name         AS student_name,
    s.class        AS class_name,
    f.fee_type_id,
    ft.name        AS fee_type_name,
    f.month,
    f.amount       AS fee_amount,
    COALESCE(alloc.paid, 0)                    AS paid,
    f.amount - COALESCE(alloc.paid, 0)         AS due
FROM fee_assignments f
JOIN students s ON s.id = f.student_id
LEFT JOIN fee_types ft ON ft.id = f.fee_type_id
LEFT JOIN (
    -- Aggregate allocations per fee_assignment (avoids cartesian)
    SELECT fee_assignment_id, SUM(amount) AS paid
    FROM payment_allocations
    GROUP BY fee_assignment_id
) alloc ON alloc.fee_assignment_id = f.id
WHERE f.is_deleted = FALSE
  AND s.is_deleted = FALSE
ORDER BY f.month, s.name;
