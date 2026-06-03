-- Migration 023: Security Audit Log
-- ================================================================
-- Implements plan_multi_role_permission.md Future Enhancement
-- ("Audit log: Log every permission check"). The plan flagged it
-- as out-of-scope but for any system that handles money it is in
-- practice required (compliance, incident response, postmortems).
--
-- Decoupled from business tables on purpose:
--   * append-only by design (no UPDATE/DELETE)
--   * keyed by tenant_id so per-tenant queries are cheap
--   * stores both authn (login, logout) and authz (permission
--     denied) events
--
-- This migration creates the table; the application layer writes
-- to it from:
--   * services/auth_service.py (login success/failure)
--   * dependencies/auth.py     (token decode failures)
--   * dependencies/permissions.py (denied permission checks)
--
-- It is OPTIONAL — drop this file if you want to defer it.
-- ================================================================

CREATE TABLE IF NOT EXISTS auth_audit_log (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   UUID NULL REFERENCES tenants(id) ON DELETE SET NULL,
    user_id     UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    event       TEXT NOT NULL,
    /* event values:
       'login_success', 'login_failed', 'logout',
       'token_expired', 'token_invalid',
       'permission_denied', 'permission_granted',
       'password_changed', 'password_reset_requested',
       'invitation_sent', 'invitation_accepted',
       'role_changed', 'user_deactivated'
    */
    detail      JSONB,            -- e.g. {"required":"payments:write","actual_role":"teacher"}
    ip_address  TEXT,
    user_agent  TEXT,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_auth_audit_tenant_time
    ON auth_audit_log(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_audit_user_time
    ON auth_audit_log(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_audit_event
    ON auth_audit_log(event, created_at DESC);

-- Make this table append-only at the DB level too.
CREATE OR REPLACE FUNCTION trg_audit_log_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'auth_audit_log is append-only; % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_log_no_update ON auth_audit_log;
CREATE TRIGGER audit_log_no_update
BEFORE UPDATE OR DELETE OR TRUNCATE ON auth_audit_log
FOR EACH STATEMENT
EXECUTE FUNCTION trg_audit_log_append_only();
