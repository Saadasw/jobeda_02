-- Migration 019: Users Table (Custom Auth, NOT Supabase auth.users)
-- ================================================================
-- Implements plan_multi_user.md + plan_multi_role_permission.md.
--
-- PLAN VERIFICATION FINDINGS — ADDRESSED HERE:
--   1. plan_multi_user.md schema: `role TEXT CHECK (role IN (...))`
--      plan_multi_role_permission.md schema: `role_id INT REFERENCES roles(id)`
--      → We use role_id (FK to migration 018). The role-permission
--        plan supersedes — it gives FK integrity AND lets us add
--        metadata to roles later.
--
--   2. plan_multi_user.md: `email TEXT NOT NULL UNIQUE` (global).
--      → BUG: two tenants couldn't both have an admin@... user.
--      → FIXED: UNIQUE (tenant_id, lower(email)) instead.
--        Globally we still index email lowercased for fast login lookup,
--        but two tenants may share the email.
--
--   3. Email case-sensitivity: plan stored email raw. Industry
--      standard is to compare lower-cased. We enforce a
--      `email_lower` generated column for case-insensitive uniqueness.
--
--   4. Password policy enforcement is in application code (per plan).
--      DB stores only password_hash (bcrypt $2b$12$...).
-- ================================================================

CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    email           TEXT NOT NULL,
    email_lower     TEXT GENERATED ALWAYS AS (lower(email)) STORED,
    password_hash   TEXT NOT NULL,
    full_name       TEXT NOT NULL,
    phone           TEXT,
    role_id         INT  NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    is_active       BOOLEAN DEFAULT TRUE,
    last_login      TIMESTAMP,
    failed_login_attempts INT DEFAULT 0,
    locked_until    TIMESTAMP NULL,
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP NULL,
    created_by      UUID NULL,
    updated_by      UUID NULL,

    -- Email is unique PER TENANT, not globally.
    CONSTRAINT uq_users_tenant_email UNIQUE (tenant_id, email_lower),
    -- Basic email shape check (full validation in app layer).
    CONSTRAINT chk_users_email_format CHECK (position('@' IN email) > 1)
);

CREATE INDEX IF NOT EXISTS idx_users_tenant       ON users(tenant_id);
CREATE INDEX IF NOT EXISTS idx_users_email_lower  ON users(email_lower);
CREATE INDEX IF NOT EXISTS idx_users_active       ON users(tenant_id, is_active) WHERE is_active = TRUE;

-- Self-referencing audit FKs (deferred for chicken/egg with first owner).
ALTER TABLE users
    ADD CONSTRAINT fk_users_created_by FOREIGN KEY (created_by) REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT fk_users_updated_by FOREIGN KEY (updated_by) REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED;

-- Safety guard: exactly one OWNER per tenant.
-- A partial unique index can't reference a subquery (must be IMMUTABLE),
-- so we enforce this via a trigger instead.
CREATE OR REPLACE FUNCTION trg_one_owner_per_tenant()
RETURNS TRIGGER AS $$
DECLARE
    v_owner_role_id INT;
    v_existing      INT;
BEGIN
    SELECT id INTO v_owner_role_id FROM roles WHERE name = 'owner';

    IF NEW.role_id = v_owner_role_id THEN
        SELECT COUNT(*) INTO v_existing
        FROM users
        WHERE tenant_id = NEW.tenant_id
          AND role_id  = v_owner_role_id
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

        IF v_existing > 0 THEN
            RAISE EXCEPTION 'Tenant % already has an owner; only one owner allowed per tenant', NEW.tenant_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS enforce_one_owner_per_tenant ON users;
CREATE TRIGGER enforce_one_owner_per_tenant
BEFORE INSERT OR UPDATE OF role_id, tenant_id ON users
FOR EACH ROW
EXECUTE FUNCTION trg_one_owner_per_tenant();
