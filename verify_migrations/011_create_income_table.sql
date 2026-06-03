-- Migration 011: Create Income Table (GAP FIX)
-- ================================================================
-- WHY: routes/income.py queries supabase.table("income") and the
--      trg_income_journal() function exists in the schema dump, but
--      the `income` table itself was NEVER created in migrations
--      001-010. Running income endpoints would fail with
--      "relation income does not exist".
--
--      This migration creates the missing table AND attaches the
--      pre-existing trg_income_journal() trigger function.
--
-- Columns mirror `expenses` (also a single-account, single-amount,
-- single-date record) plus soft-delete + audit columns introduced
-- in migration 003.
-- ================================================================

CREATE TABLE IF NOT EXISTS income (
    id              SERIAL PRIMARY KEY,
    account_id      INT NOT NULL REFERENCES accounts(id),
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    date            DATE NOT NULL,
    description     TEXT,
    is_deleted      BOOLEAN DEFAULT FALSE,
    deleted_at      TIMESTAMP NULL,
    created_at      TIMESTAMP DEFAULT NOW(),
    created_by      TEXT NULL,
    updated_at      TIMESTAMP NULL,
    updated_by      TEXT NULL
);

CREATE INDEX IF NOT EXISTS idx_income_account ON income(account_id);
CREATE INDEX IF NOT EXISTS idx_income_date    ON income(date);

-- Attach the income journaling trigger that was orphaned in schema.txt.
-- trg_income_journal() already exists; we just bind it to the table.
DROP TRIGGER IF EXISTS income_after_insert ON income;
CREATE TRIGGER income_after_insert
AFTER INSERT ON income
FOR EACH ROW
EXECUTE FUNCTION trg_income_journal();
