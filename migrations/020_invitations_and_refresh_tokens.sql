-- Migration 020: Invitations + Refresh Tokens + Password Resets
-- ================================================================
-- Implements plan_multi_user.md auth tables.
--
-- PLAN VERIFICATION FINDINGS — ADDRESSED HERE:
--   1. plan_multi_user.md stored invitation tokens IN PLAINTEXT
--      (`token TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32),'hex')`).
--      → SECURITY GAP: anyone with DB read access can hijack pending
--        invites. Industry standard is to store only a HASH of the
--        token; the plaintext is shown to the recipient via email
--        and never again.
--      → FIXED: `token_hash TEXT` (bcrypt or sha256 hex). The app
--        layer hashes the token before insert/lookup.
--
--   2. plan_multi_user.md marked refresh_tokens "optional".
--      → For ANY production system with login/logout flows, refresh
--        tokens are required (else you choose between short 15-min
--        sessions or long-lived stealable tokens). Made it part of
--        this migration, not optional.
--
--   3. plan_multi_user.md Q2 mentioned password reset but no schema.
--      → Added password_resets table here. Identical structure to
--        invitations (token_hash + expiry + single-use).
--
--   4. Invitations reference role by FK to roles.id, NOT role TEXT.
--      Consistent with users.role_id from migration 019.
-- ================================================================

-- ═══════════════════════════════════════════════════════════════
-- 1. invitations
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS invitations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email        TEXT NOT NULL,
    email_lower  TEXT GENERATED ALWAYS AS (lower(email)) STORED,
    role_id      INT  NOT NULL REFERENCES roles(id),
    invited_by   UUID NOT NULL REFERENCES users(id),
    token_hash   TEXT NOT NULL,   -- SHA-256 hex of the secret. Plaintext never stored.
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
    expires_at   TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    accepted_at  TIMESTAMP,
    created_at   TIMESTAMP DEFAULT NOW(),

    -- Cannot invite the owner role (only the founding registration creates one).
    CONSTRAINT chk_invitations_role_not_owner
        CHECK (role_id <> (SELECT id FROM roles WHERE name = 'owner' LIMIT 1))
);

-- The CHECK above with a subquery is non-deterministic in some PG versions.
-- Replace with a trigger for portability.
ALTER TABLE invitations DROP CONSTRAINT IF EXISTS chk_invitations_role_not_owner;

CREATE OR REPLACE FUNCTION trg_invitation_no_owner_role()
RETURNS TRIGGER AS $$
DECLARE
    v_owner_role_id INT;
BEGIN
    SELECT id INTO v_owner_role_id FROM roles WHERE name = 'owner';
    IF NEW.role_id = v_owner_role_id THEN
        RAISE EXCEPTION 'Cannot invite a user with role "owner". Owner is created only via tenant registration.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS invitation_no_owner_role ON invitations;
CREATE TRIGGER invitation_no_owner_role
BEFORE INSERT OR UPDATE OF role_id ON invitations
FOR EACH ROW
EXECUTE FUNCTION trg_invitation_no_owner_role();

CREATE INDEX IF NOT EXISTS idx_invitations_tenant     ON invitations(tenant_id);
CREATE INDEX IF NOT EXISTS idx_invitations_token_hash ON invitations(token_hash);
CREATE INDEX IF NOT EXISTS idx_invitations_pending
    ON invitations(tenant_id, email_lower)
    WHERE status = 'pending';

-- ═══════════════════════════════════════════════════════════════
-- 2. refresh_tokens
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL,                -- SHA-256 / bcrypt of the token
    expires_at  TIMESTAMP NOT NULL,
    created_at  TIMESTAMP DEFAULT NOW(),
    revoked_at  TIMESTAMP,
    user_agent  TEXT,                         -- helpful for "log out other sessions"
    ip_address  TEXT
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user       ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_active
    ON refresh_tokens(user_id, expires_at)
    WHERE revoked_at IS NULL;

-- ═══════════════════════════════════════════════════════════════
-- 3. password_resets (filling plan_multi_user.md Q2 gap)
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS password_resets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL,
    expires_at  TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '1 hour'),
    used_at     TIMESTAMP,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_password_resets_user       ON password_resets(user_id);
CREATE INDEX IF NOT EXISTS idx_password_resets_token_hash ON password_resets(token_hash);
