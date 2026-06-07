-- Migration 037: Make generate_receipt_no self-healing
-- ================================================================
-- BUG: generate_receipt_no (migration 017) relies solely on the
--   tenant_counters table. But receipts can enter the payments table
--   WITHOUT going through this function — e.g. the demo seed writes
--   PAY-2026-0001..0010 directly. The counter then still starts at 0,
--   so the next API payment gets PAY-2026-0001 and hits the
--   uq_payments_tenant_receipt unique constraint.
--
-- FIX: keep the atomic per-tenant counter (so concurrent calls are
--   safe) but never return a sequence <= the highest receipt that
--   already exists for this tenant + year. The counter is bumped to
--   max(counter+1, existing_max+1), which self-heals any drift left by
--   seeds/imports.
-- ================================================================

CREATE OR REPLACE FUNCTION generate_receipt_no(p_tenant_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_year         INT := EXTRACT(YEAR FROM NOW())::INT;
    v_max_existing INT;
    v_next         INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'generate_receipt_no: tenant_id must not be NULL';
    END IF;

    -- Highest sequence already used by this tenant for this year (covers
    -- receipts inserted directly, e.g. by the seed/import).
    SELECT COALESCE(MAX(substring(receipt_no FROM '\d+$')::INT), 0)
    INTO v_max_existing
    FROM payments
    WHERE tenant_id = p_tenant_id
      AND receipt_no LIKE 'PAY-' || v_year || '-%';

    -- Atomic upsert; never go below existing_max + 1.
    INSERT INTO tenant_counters (tenant_id, kind, year, last_value, updated_at)
    VALUES (p_tenant_id, 'receipt', v_year, GREATEST(1, v_max_existing + 1), NOW())
    ON CONFLICT (tenant_id, kind, year)
    DO UPDATE SET
        last_value = GREATEST(tenant_counters.last_value + 1, v_max_existing + 1),
        updated_at = NOW()
    RETURNING last_value INTO v_next;

    RETURN 'PAY-' || v_year || '-' || LPAD(v_next::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_receipt_no(UUID) IS
'Per-tenant, per-year sequential receipt numbers; self-heals past receipts inserted directly (seeds/imports). Atomic via tenant_counters.';
