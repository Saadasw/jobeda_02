-- Migration 013: Add tenant_id to All Tenant-Scoped Tables
-- ================================================================
-- Implements plan_multi_tenant.md — Phase 1 schema preparation.
--
-- Strategy (3 steps per table):
--   1. ADD COLUMN tenant_id UUID (nullable)
--   2. UPDATE backfill rows to the default tenant
--   3. ALTER COLUMN SET NOT NULL + FK + INDEX
--
-- UPGRADES BEYOND THE PLAN:
--   * `payment_allocations` and `journal_lines` GET denormalized
--     tenant_id columns even though the plan calls them "inherited".
--     Reason: ledger and report queries scan these tables; without
--     a direct tenant_id, every report would join through 2-3 hops
--     to filter, killing performance at scale.
--   * `sections` is included (plan listed it as tenant-scoped but
--     didn't explicitly call it out in Phase 1).
--   * The `income` table from migration 011 is included.
-- ================================================================

-- Resolve the default tenant once.
DO $$
DECLARE
    v_default UUID;
BEGIN
    SELECT id INTO v_default FROM tenants WHERE slug = 'jobeda' LIMIT 1;
    IF v_default IS NULL THEN
        RAISE EXCEPTION 'Default tenant "jobeda" not found. Run migration 012 first.';
    END IF;

    -- ─── Core entities ──────────────────────────────────────────
    ALTER TABLE accounts            ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE journal_entries     ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE journal_lines       ADD COLUMN IF NOT EXISTS tenant_id UUID; -- denormalized
    ALTER TABLE students            ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE employees           ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE fee_types           ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE fee_assignments     ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE payments            ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE payment_allocations ADD COLUMN IF NOT EXISTS tenant_id UUID; -- denormalized
    ALTER TABLE salary_payments     ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE expenses            ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE income              ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE academic_years      ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE classes             ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE sections            ADD COLUMN IF NOT EXISTS tenant_id UUID;

    -- ─── Backfill all rows to the default tenant ────────────────
    UPDATE accounts            SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE journal_entries     SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE journal_lines       SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE students            SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE employees           SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE fee_types           SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE fee_assignments     SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE payments            SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE payment_allocations SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE salary_payments     SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE expenses            SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE income              SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE academic_years      SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE classes             SET tenant_id = v_default WHERE tenant_id IS NULL;
    UPDATE sections            SET tenant_id = v_default WHERE tenant_id IS NULL;
END $$;

-- ─── Lock columns NOT NULL + add FKs ────────────────────────────
ALTER TABLE accounts            ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE journal_entries     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE journal_lines       ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE students            ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE employees           ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE fee_types           ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE fee_assignments     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE payments            ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE payment_allocations ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE salary_payments     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE expenses            ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE income              ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE academic_years      ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE classes             ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE sections            ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE accounts            ADD CONSTRAINT fk_accounts_tenant            FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE journal_entries     ADD CONSTRAINT fk_journal_entries_tenant     FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE journal_lines       ADD CONSTRAINT fk_journal_lines_tenant       FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE students            ADD CONSTRAINT fk_students_tenant            FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE employees           ADD CONSTRAINT fk_employees_tenant           FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE fee_types           ADD CONSTRAINT fk_fee_types_tenant           FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE fee_assignments     ADD CONSTRAINT fk_fee_assignments_tenant     FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE payments            ADD CONSTRAINT fk_payments_tenant            FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE payment_allocations ADD CONSTRAINT fk_payment_allocations_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE salary_payments     ADD CONSTRAINT fk_salary_payments_tenant     FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE expenses            ADD CONSTRAINT fk_expenses_tenant            FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE income              ADD CONSTRAINT fk_income_tenant              FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE academic_years      ADD CONSTRAINT fk_academic_years_tenant      FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE classes             ADD CONSTRAINT fk_classes_tenant             FOREIGN KEY (tenant_id) REFERENCES tenants(id);
ALTER TABLE sections            ADD CONSTRAINT fk_sections_tenant            FOREIGN KEY (tenant_id) REFERENCES tenants(id);

-- ─── Indexes for tenant filtering ───────────────────────────────
CREATE INDEX IF NOT EXISTS idx_accounts_tenant            ON accounts(tenant_id);
CREATE INDEX IF NOT EXISTS idx_journal_entries_tenant     ON journal_entries(tenant_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_tenant       ON journal_lines(tenant_id);
CREATE INDEX IF NOT EXISTS idx_students_tenant            ON students(tenant_id);
CREATE INDEX IF NOT EXISTS idx_employees_tenant           ON employees(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fee_types_tenant           ON fee_types(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fee_assignments_tenant     ON fee_assignments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payments_tenant            ON payments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payment_allocations_tenant ON payment_allocations(tenant_id);
CREATE INDEX IF NOT EXISTS idx_salary_payments_tenant     ON salary_payments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_expenses_tenant            ON expenses(tenant_id);
CREATE INDEX IF NOT EXISTS idx_income_tenant              ON income(tenant_id);
CREATE INDEX IF NOT EXISTS idx_academic_years_tenant      ON academic_years(tenant_id);
CREATE INDEX IF NOT EXISTS idx_classes_tenant             ON classes(tenant_id);
CREATE INDEX IF NOT EXISTS idx_sections_tenant            ON sections(tenant_id);
