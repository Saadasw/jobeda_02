-- Migration 006: Student Due Summary View
-- Replaces N+1 Python queries with a single efficient SQL view.
--
-- Uses subqueries (not raw JOINs) to avoid cartesian product inflation
-- when a student has multiple fees and multiple allocations.
--
-- Columns:
--   id, name, class, total_fee, total_paid, due, advance, last_payment_date
--
-- Queryable via Supabase like a regular table:
--   supabase.table("student_due_summary").select("*").execute()
--   supabase.table("student_due_summary").select("*").eq("id", 1).execute()
--   supabase.table("student_due_summary").select("*").gt("due", 0).execute()

DROP VIEW IF EXISTS student_due_summary;
CREATE VIEW student_due_summary AS
SELECT
    s.id,
    s.name,
    s.class,
    COALESCE(fees.total, 0)                                         AS total_fee,
    COALESCE(alloc.total, 0)                                        AS total_paid,
    GREATEST(COALESCE(fees.total, 0) - COALESCE(alloc.total, 0), 0) AS due,
    GREATEST(COALESCE(paid.total, 0) - COALESCE(fees.total, 0), 0)  AS advance,
    last_pay.last_payment_date
FROM students s

-- Subquery 1: Total fees assigned per student
LEFT JOIN (
    SELECT student_id, SUM(amount) AS total
    FROM fee_assignments
    WHERE is_deleted = FALSE
    GROUP BY student_id
) fees ON s.id = fees.student_id

-- Subquery 2: Total allocated against fees per student
LEFT JOIN (
    SELECT f.student_id, SUM(pa.amount) AS total
    FROM payment_allocations pa
    JOIN fee_assignments f ON pa.fee_assignment_id = f.id
    WHERE f.is_deleted = FALSE
    GROUP BY f.student_id
) alloc ON s.id = alloc.student_id

-- Subquery 3: Total raw payments per student (for advance calculation)
LEFT JOIN (
    SELECT student_id, SUM(amount) AS total
    FROM payments
    WHERE is_deleted = FALSE
      AND status = 'completed'
    GROUP BY student_id
) paid ON s.id = paid.student_id

-- Subquery 4: Last payment date per student
LEFT JOIN (
    SELECT student_id, MAX(date) AS last_payment_date
    FROM payments
    WHERE is_deleted = FALSE
      AND status = 'completed'
    GROUP BY student_id
) last_pay ON s.id = last_pay.student_id

WHERE s.is_deleted = FALSE;
