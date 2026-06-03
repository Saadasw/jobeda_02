-- Migration 022: Promote created_by / updated_by to UUID FKs to users
-- ================================================================
-- Migration 003 added `created_by TEXT NULL` and `updated_by TEXT NULL`
-- to all the tables. The plan_multi_user.md says these should be
-- populated with `user.user_id` (a UUID).
--
-- PLAN VERIFICATION FINDINGS — ADDRESSED HERE:
--   * TEXT columns cannot be FK-checked against users(id). A typo or
--     a malicious value silently lands without any constraint.
--   * UUID with FK gives:
--       (a) integrity — can't write a created_by that doesn't exist
--       (b) ability to JOIN users → see who created what
--       (c) ON DELETE behavior (SET NULL keeps history)
--
-- STRATEGY (per table):
--   1. Add new UUID columns (created_by_id / updated_by_id) with FK.
--   2. Keep the original TEXT columns for now (historical data).
--      The application layer can populate both during a transition
--      period, then a future cleanup migration can drop the TEXT
--      columns once all rows are migrated.
--
-- NOTE: This migration is intentionally CONSERVATIVE — it does NOT
--       drop the TEXT columns. That would orphan all existing
--       audit data on the default tenant.
-- ================================================================

DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY[
        'students',
        'employees',
        'fee_assignments',
        'payments',
        'expenses',
        'income',
        'salary_payments',
        'accounts',
        'fee_types',
        'academic_years',
        'classes',
        'sections'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS created_by_id UUID NULL', t);
        EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS updated_by_id UUID NULL', t);
        EXECUTE format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (created_by_id) REFERENCES users(id) ON DELETE SET NULL',
            t, 'fk_' || t || '_created_by'
        );
        EXECUTE format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (updated_by_id) REFERENCES users(id) ON DELETE SET NULL',
            t, 'fk_' || t || '_updated_by'
        );
    END LOOP;
END $$;

-- Also add updated_at to tables that lacked it (accounts, fee_types,
-- payment_allocations, journal_entries, journal_lines).
ALTER TABLE accounts            ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NULL;
ALTER TABLE fee_types           ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NULL;
ALTER TABLE payment_allocations ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NULL;
ALTER TABLE journal_entries     ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NULL;
