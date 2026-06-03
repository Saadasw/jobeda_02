-- Migration 014: Tenant-Scoped Unique Constraints
-- ================================================================
-- The original migrations defined unique constraints that are GLOBAL
-- (i.e. unique across all tenants). After multi-tenancy these break:
--   * Two different madrasas would clash on `receipt_no = 'PAY-2026-0001'`
--   * Two different madrasas can't both have an account named 'Cash'
--   * Add same-named classes / fee types per tenant
--
-- The triggers in add_journal_line() look up accounts by NAME, so
-- the (tenant_id, name) uniqueness on accounts is non-negotiable —
-- otherwise a trigger could pick another tenant's 'Cash' row.
--
-- UPGRADES BEYOND THE PLAN:
--   The plan called out only `uq_fee_per_student_per_month` and was
--   silent on receipt_no, account name, fee type name, and academic
--   year name. All four are addressed here.
-- ================================================================

-- ── 1. accounts: name unique per tenant (CRITICAL for trigger correctness)
-- Drop the global uniqueness if it was implicit, then add scoped.
ALTER TABLE accounts
    ADD CONSTRAINT uq_accounts_tenant_name UNIQUE (tenant_id, name);

-- ── 2. payments: receipt_no unique per tenant
-- Drop the global unique constraint added in migration 003.
ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_receipt_no_key;
ALTER TABLE payments
    ADD CONSTRAINT uq_payments_tenant_receipt UNIQUE (tenant_id, receipt_no);

-- ── 3. fee_types: name unique per tenant
ALTER TABLE fee_types
    ADD CONSTRAINT uq_fee_types_tenant_name UNIQUE (tenant_id, name);

-- ── 4. academic_years: name unique per tenant
ALTER TABLE academic_years
    ADD CONSTRAINT uq_academic_years_tenant_name UNIQUE (tenant_id, name);

-- ── 5. classes: name unique per tenant
ALTER TABLE classes
    ADD CONSTRAINT uq_classes_tenant_name UNIQUE (tenant_id, name);

-- ── 6. sections: (class_id, name) unique per tenant.
--      class_id already implies a tenant, but tenant_id in the key
--      protects against cross-tenant class_id leaks (defense in depth).
ALTER TABLE sections
    ADD CONSTRAINT uq_sections_tenant_class_name UNIQUE (tenant_id, class_id, name);

-- ── 7. fee_assignments: re-create with tenant_id for defense in depth.
--      The existing uq_fee_per_student_per_month is already implicitly
--      tenant-scoped via student_id, but explicit is safer if a bug
--      ever inserts a row with mismatched tenant_id/student_id.
ALTER TABLE fee_assignments DROP CONSTRAINT IF EXISTS uq_fee_per_student_per_month;
ALTER TABLE fee_assignments
    ADD CONSTRAINT uq_fee_per_tenant_student_type_month
        UNIQUE (tenant_id, student_id, fee_type_id, month);

-- ── 8. Only one current academic year per tenant
-- Use a partial unique index because UNIQUE (tenant_id, is_current)
-- would block multiple non-current rows from coexisting.
CREATE UNIQUE INDEX IF NOT EXISTS uq_academic_years_one_current_per_tenant
    ON academic_years(tenant_id)
    WHERE is_current = TRUE;
