-- Migration 017: Per-Tenant Receipt Number Generation
-- ================================================================
-- The original migration 005 created a GLOBAL `receipt_seq`. With
-- multi-tenancy that means:
--   * Tenant A pays once → gets PAY-2026-0001
--   * Tenant B pays once → gets PAY-2026-0002 (!!!)
--
-- This breaks the per-tenant receipt numbering expectation
-- ("our madrasa's 1st receipt of 2026"). It also leaks how busy
-- other tenants are (an information disclosure side-channel).
--
-- THIS MIGRATION:
--   * Adds a `tenant_counters` table keyed by (tenant_id, kind, year).
--   * Reimplements generate_receipt_no() to take a tenant_id and use
--     this counter atomically (INSERT ... ON CONFLICT ... DO UPDATE).
--   * Keeps the old global sequence around so existing receipt_no's
--     remain valid history.
--
-- UPGRADE BEYOND THE PLAN:
--   The three plans never addressed this. Without it, multi-tenancy
--   is broken for receipts.
-- ================================================================

CREATE TABLE IF NOT EXISTS tenant_counters (
    tenant_id    UUID    NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    kind         TEXT    NOT NULL,    -- e.g. 'receipt'
    year         INT     NOT NULL,
    last_value   INT     NOT NULL DEFAULT 0,
    updated_at   TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (tenant_id, kind, year)
);

-- Drop the old signature so callers get a fast failure rather than
-- silently mixing tenants.
DROP FUNCTION IF EXISTS generate_receipt_no();

CREATE OR REPLACE FUNCTION generate_receipt_no(p_tenant_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_year INT := EXTRACT(YEAR FROM NOW())::INT;
    v_next INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'generate_receipt_no: tenant_id must not be NULL';
    END IF;

    -- Atomic upsert returns the post-increment value.
    INSERT INTO tenant_counters (tenant_id, kind, year, last_value, updated_at)
    VALUES (p_tenant_id, 'receipt', v_year, 1, NOW())
    ON CONFLICT (tenant_id, kind, year)
    DO UPDATE SET
        last_value = tenant_counters.last_value + 1,
        updated_at = NOW()
    RETURNING last_value INTO v_next;

    RETURN 'PAY-' || v_year || '-' || LPAD(v_next::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_receipt_no(UUID) IS
'Per-tenant, per-year sequential receipt numbers. Call via supabase.rpc("generate_receipt_no", {"p_tenant_id": tenant_id}).';
