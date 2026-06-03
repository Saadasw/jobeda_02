-- Migration 018: Roles Table + Seed System Roles
-- ================================================================
-- Implements plan_multi_role_permission.md — the DB-half of the
-- hybrid RBAC approach. (Permission strings live in code.)
--
-- PLAN VERIFICATION FINDINGS — ADDRESSED HERE:
--   1. plan_multi_user.md uses `users.role TEXT CHECK (...)` directly.
--      plan_multi_role_permission.md uses `users.role_id INT REFERENCES roles(id)`.
--      The two contradict. The role_id approach wins because:
--         * FK integrity at the DB level
--         * the roles table can carry metadata (description, is_system)
--         * the permission plan supersedes the auth plan
--      Migration 019 creates users.role_id, NOT users.role.
--
--   2. plan never addressed: system-role DELETION protection.
--      A trigger here blocks DELETE / UPDATE on roles flagged
--      `is_system = TRUE`. JWTs embed the role NAME — renaming or
--      removing a system role would silently 403 every active session.
--
--   3. plan never addressed: roles must exist BEFORE users (FK ordering).
-- ================================================================

CREATE TABLE IF NOT EXISTS roles (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,
    description  TEXT,
    is_system    BOOLEAN DEFAULT TRUE,
    created_at   TIMESTAMP DEFAULT NOW()
);

-- ─── Seed the 5 system roles ────────────────────────────────────
INSERT INTO roles (name, description, is_system) VALUES
    ('owner',      'Full control — madrasa founder/principal',         TRUE),
    ('admin',      'Operational control — head teacher, vice principal', TRUE),
    ('accountant', 'Financial operations — accounts officer',           TRUE),
    ('teacher',    'Read-only students + own salary — class teacher',   TRUE),
    ('viewer',     'Read-only access — auditor, board member',          TRUE)
ON CONFLICT (name) DO NOTHING;

-- ─── Protect system roles ──────────────────────────────────────
-- Block DELETE of system roles and block rename of system roles.
CREATE OR REPLACE FUNCTION trg_protect_system_roles()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        IF OLD.is_system THEN
            RAISE EXCEPTION 'Cannot delete system role "%"', OLD.name;
        END IF;
        RETURN OLD;
    ELSIF (TG_OP = 'UPDATE') THEN
        IF OLD.is_system AND NEW.name <> OLD.name THEN
            RAISE EXCEPTION 'Cannot rename system role "%" (would invalidate active JWTs)', OLD.name;
        END IF;
        IF OLD.is_system AND NEW.is_system = FALSE THEN
            RAISE EXCEPTION 'Cannot demote system role "%" to non-system', OLD.name;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protect_system_roles ON roles;
CREATE TRIGGER protect_system_roles
BEFORE UPDATE OR DELETE ON roles
FOR EACH ROW
EXECUTE FUNCTION trg_protect_system_roles();
