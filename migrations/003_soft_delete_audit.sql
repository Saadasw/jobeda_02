-- Migration 003: Soft Delete + Audit Fields on All Tables
-- Adds is_deleted, deleted_at, audit fields, status columns

-- employees
ALTER TABLE employees
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS created_by TEXT NULL,
ADD COLUMN IF NOT EXISTS updated_by TEXT NULL;

-- fee_assignments
ALTER TABLE fee_assignments
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS created_by TEXT NULL;

-- payments: status, receipt, cash_account, soft delete, audit
ALTER TABLE payments
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'cancelled', 'refunded')),
ADD COLUMN IF NOT EXISTS receipt_no TEXT UNIQUE,
ADD COLUMN IF NOT EXISTS cash_account_id INT REFERENCES accounts(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS created_by TEXT NULL;

-- expenses
ALTER TABLE expenses
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS created_by TEXT NULL;

-- salary_payments
ALTER TABLE salary_payments
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL,
ADD COLUMN IF NOT EXISTS created_by TEXT NULL;

-- journal_entries: reversal tracking
ALTER TABLE journal_entries
ADD COLUMN IF NOT EXISTS is_reversed BOOLEAN DEFAULT FALSE;

-- fee_types: soft delete
ALTER TABLE fee_types
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL;

-- accounts: soft delete
ALTER TABLE accounts
ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL;
