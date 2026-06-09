-- ============================================================================
-- Migration 040: fix created_by_id type (INT -> UUID)
-- ============================================================================
-- Migration 039 created fee_structures.created_by_id and
-- fee_assignments.created_by_id as INT, but users.id is a UUID — so stamping
-- the creator raised "invalid input syntax for type integer".
--
-- These columns are still empty (generation never succeeded; manual assigns and
-- the seed don't set them), so the safe fix is drop & re-add as UUID.
-- Idempotent / safe to re-run.
-- Apply in the Supabase SQL editor on project lltdojrxjdnwbwowqptb.
-- ============================================================================

ALTER TABLE fee_structures  DROP COLUMN IF EXISTS created_by_id;
ALTER TABLE fee_structures  ADD  COLUMN created_by_id UUID;

ALTER TABLE fee_assignments DROP COLUMN IF EXISTS created_by_id;
ALTER TABLE fee_assignments ADD  COLUMN created_by_id UUID;

COMMENT ON COLUMN fee_structures.created_by_id  IS 'User (UUID) who created the structure.';
COMMENT ON COLUMN fee_assignments.created_by_id IS 'User (UUID) who created/generated this fee (audit).';
