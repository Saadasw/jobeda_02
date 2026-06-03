-- Migration 011: Dedicated Income Table
-- Fixes the income accounting bug where income was being inserted into the
-- expenses table, causing trg_expense_journal to fire with WRONG entries:
--   WRONG: Dr Revenue Account / Cr Cash  (treats income as expense)
--   RIGHT: Dr Cash / Cr Revenue Account  (cash comes in, revenue recognized)
--
-- The trg_income_journal() function already exists in the DB (from initial schema)
-- with the correct logic. This migration:
--   1. Creates a dedicated 'income' table
--   2. Re-creates the function (idempotent via CREATE OR REPLACE)
--   3. Attaches the trigger to the new table
--
-- After this migration, routes/income.py must insert into 'income', not 'expenses'.
-- NOTE: If any income records were previously inserted into the 'expenses' table,
-- they will need to be manually migrated and their journal entries reversed.

-- ============================================================================
-- STEP 1: Create the income table
-- Same structure as expenses, but dedicated to revenue transactions
-- ============================================================================

CREATE TABLE IF NOT EXISTS income (
    id SERIAL PRIMARY KEY,
    account_id INT NOT NULL REFERENCES accounts(id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    date DATE NOT NULL,
    description TEXT,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP NULL,
    created_by TEXT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- ============================================================================
-- STEP 2: Ensure the trigger function exists (idempotent)
-- Dr Cash / Cr Revenue Account — correct double-entry for income
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_income_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
    v_account_name TEXT;
BEGIN
    SELECT name INTO v_account_name FROM accounts WHERE id = NEW.account_id;

    v_journal_id := create_journal_entry(
        NEW.date,
        'Income: ' || v_account_name
    );

    -- Dr Cash — money coming in
    PERFORM add_journal_line(v_journal_id, 'Cash', NEW.amount, 0);

    -- Cr Revenue Account — income recognized
    PERFORM add_journal_line(v_journal_id, v_account_name, 0, NEW.amount);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STEP 3: Attach trigger to income table
-- ============================================================================

CREATE TRIGGER income_after_insert
AFTER INSERT ON income
FOR EACH ROW
EXECUTE FUNCTION trg_income_journal();
