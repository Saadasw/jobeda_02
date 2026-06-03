-- Migration 010: Allocation Over-Payment Guard
-- Prevents allocating more than a fee's amount or a payment's amount.
-- This is the DB-level safety net — protects against direct SQL manipulation.
--
-- The API already validates this, but the trigger ensures data integrity
-- even if someone bypasses the API and runs SQL directly.

CREATE OR REPLACE FUNCTION trg_check_allocation_limits()
RETURNS TRIGGER AS $$
DECLARE
    v_fee_amount NUMERIC;
    v_fee_total_allocated NUMERIC;
    v_payment_amount NUMERIC;
    v_payment_total_allocated NUMERIC;
BEGIN
    -- Check 1: Total allocations against this fee must not exceed fee amount
    SELECT amount INTO v_fee_amount
    FROM fee_assignments
    WHERE id = NEW.fee_assignment_id;

    SELECT COALESCE(SUM(amount), 0) INTO v_fee_total_allocated
    FROM payment_allocations
    WHERE fee_assignment_id = NEW.fee_assignment_id
      AND id != COALESCE(NEW.id, 0);  -- exclude current row on UPDATE

    IF (v_fee_total_allocated + NEW.amount) > v_fee_amount THEN
        RAISE EXCEPTION 'Allocation would exceed fee amount. Fee: %, Already allocated: %, Attempted: %',
            v_fee_amount, v_fee_total_allocated, NEW.amount;
    END IF;

    -- Check 2: Total allocations against this payment must not exceed payment amount
    SELECT amount INTO v_payment_amount
    FROM payments
    WHERE id = NEW.payment_id;

    SELECT COALESCE(SUM(amount), 0) INTO v_payment_total_allocated
    FROM payment_allocations
    WHERE payment_id = NEW.payment_id
      AND id != COALESCE(NEW.id, 0);  -- exclude current row on UPDATE

    IF (v_payment_total_allocated + NEW.amount) > v_payment_amount THEN
        RAISE EXCEPTION 'Allocation would exceed payment amount. Payment: %, Already allocated: %, Attempted: %',
            v_payment_amount, v_payment_total_allocated, NEW.amount;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_allocation_limits
BEFORE INSERT OR UPDATE ON payment_allocations
FOR EACH ROW
EXECUTE FUNCTION trg_check_allocation_limits();
