-- Migration 004: Unique Constraints
-- Prevents duplicate fee assignments

ALTER TABLE fee_assignments
ADD CONSTRAINT uq_fee_per_student_per_month
UNIQUE (student_id, fee_type_id, month);
