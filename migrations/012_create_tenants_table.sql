-- Migration 012: Tenants Table
-- ================================================================
-- Implements plan_multi_tenant.md — root of multi-tenancy.
--
-- Design choices:
--   * UUID primary key (not SERIAL) so tenant IDs are non-guessable
--     and safe to expose in URLs/JWT.
--   * Slug pattern enforced at DB level: ^[a-z0-9-]+$ (URL-safe).
--   * Default tenant ("jobeda") is created so existing rows can be
--     backfilled in migration 013.
--   * `is_active` lets us deactivate a tenant without deleting data
--     (lockout flow).
-- ================================================================

CREATE TABLE IF NOT EXISTS tenants (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL,
    address     TEXT,
    phone       TEXT,
    email       TEXT,
    logo_url    TEXT,
    is_active   BOOLEAN DEFAULT TRUE,
    created_at  TIMESTAMP DEFAULT NOW(),
    updated_at  TIMESTAMP NULL,
    CONSTRAINT uq_tenants_slug UNIQUE (slug),
    CONSTRAINT chk_tenants_slug_format
        CHECK (slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$' AND length(slug) BETWEEN 2 AND 50)
);

CREATE INDEX IF NOT EXISTS idx_tenants_active ON tenants(is_active) WHERE is_active = TRUE;

-- Seed the default tenant for ALL existing rows.
-- Migration 013 will backfill tenant_id on every table using this row.
INSERT INTO tenants (name, slug, is_active)
VALUES ('Jobeda Hafizia Madrasa', 'jobeda', TRUE)
ON CONFLICT (slug) DO NOTHING;
