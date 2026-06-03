-- Migration 024: Tenant-Aware Allocation Limit Guard
-- ================================================================
-- Migration 010 added a trigger that prevents over-allocation
-- (allocating more than a fee's amount or a payment's amount).
-- Multi-tenancy adds one more invariant:
--   * payment_allocations.tenant_id must equal payments.tenant_id
--     (which must equal fee_assignments.tenant_id).
--
-- This migration rewrites the trigger to also enforce that.
--
-- UPGRADE BEYOND THE PLAN:
--   None of the three plans explicitly addressed the allocation
--   guard. But the original guard pre-dates multi-tenancy. Without
--   this update, a buggy/malicious caller could insert an allocation
--   with the wrong tenant_id and create cross-tenant journal entries.
-- ================================================================

CREATE OR REPLACE FUNCTION trg_check_allocation_limits()
RETURNS TRIGGER AS $$
DECLARE
    v_fee_amount              NUMERIC;
    v_fee_total_allocated     NUMERIC;
    v_fee_tenant              UUID;
    v_payment_amount          NUMERIC;
    v_payment_total_allocated NUMERIC;
    v_payment_tenant          UUID;
BEGIN
    -- ── Tenant consistency: allocation ⇄ fee ⇄ payment
    SELECT amount, tenant_id INTO v_fee_amount, v_fee_tenant
    FROM fee_assignments
    WHERE id = NEW.fee_assignment_id;

    SELECT amount, tenant_id INTO v_payment_amount, v_payment_tenant
    FROM payments
    WHERE id = NEW.payment_id;

    IF v_fee_tenant IS NULL THEN
        RAISE EXCEPTION 'fee_assignment % not found', NEW.fee_assignment_id;
    END IF;
    IF v_payment_tenant IS NULL THEN
        RAISE EXCEPTION 'payment % not found', NEW.payment_id;
    END IF;
    IF v_fee_tenant <> v_payment_tenant THEN
        RAISE EXCEPTION 'Cross-tenant allocation forbidden: fee tenant %, payment tenant %',
            v_fee_tenant, v_payment_tenant;
    END IF;
    IF NEW.tenant_id <> v_fee_tenant THEN
        RAISE EXCEPTION 'allocation.tenant_id (%) does not match fee/payment tenant (%)',
            NEW.tenant_id, v_fee_tenant;
    END IF;

    -- ── Fee over-allocation check
    -- payment_allocations.id is INT (SERIAL); use 0 as the "not yet inserted" sentinel.
    SELECT COALESCE(SUM(amount), 0) INTO v_fee_total_allocated
    FROM payment_allocations
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND id != COALESCE(NEW.id, 0);

    IF (v_fee_total_allocated + NEW.amount) > v_fee_amount THEN
        RAISE EXCEPTION 'Allocation would exceed fee amount. Fee: %, Already allocated: %, Attempted: %',
            v_fee_amount, v_fee_total_allocated, NEW.amount;
    END IF;

    -- ── Payment over-allocation check
    SELECT COALESCE(SUM(amount), 0) INTO v_payment_total_allocated
    FROM payment_allocations
    WHERE payment_id = NEW.payment_id
      AND id != COALESCE(NEW.id, 0);

    IF (v_payment_total_allocated + NEW.amount) > v_payment_amount THEN
        RAISE EXCEPTION 'Allocation would exceed payment amount. Payment: %, Already allocated: %, Attempted: %',
            v_payment_amount, v_payment_total_allocated, NEW.amount;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger remains bound (CREATE OR REPLACE updates the body).
-- Recreate the binding to be safe in case migration 010 was rolled back.
DROP TRIGGER IF EXISTS check_allocation_limits ON payment_allocations;
CREATE TRIGGER check_allocation_limits
BEFORE INSERT OR UPDATE ON payment_allocations
FOR EACH ROW
EXECUTE FUNCTION trg_check_allocation_limits();
