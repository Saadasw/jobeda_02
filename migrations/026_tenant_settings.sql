-- Migration 026: Per-Tenant Settings
-- ================================================================
-- WHY:
--   Up to migration 025 every tenant shares the same hard-coded
--   assumptions: BDT currency, English locale, calendar-year fiscal
--   year, "PAY-YYYY-NNNN" receipt prefix, no late-fee policy.
--   The moment a branch operates in INR / USD / SAR, starts its
--   academic year in July, or wants its own receipt header, those
--   assumptions break.
--
-- DESIGN:
--   One row per tenant (1:1 with tenants table). Structured columns
--   — NOT key/value — because:
--     * Type safety (currency is CHAR(3), not free TEXT)
--     * Easy to JOIN with other queries
--     * Each setting has a sensible default
--
--   New tenants get a default settings row via seed_tenant_defaults()
--   (see end of this migration — we extend that function).
-- ================================================================

CREATE TABLE IF NOT EXISTS tenant_settings (
    tenant_id            UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,

    -- ─── Localization ──────────────────────────────────────────
    currency_code        CHAR(3)  NOT NULL DEFAULT 'BDT',     -- ISO 4217
    currency_symbol      TEXT     NOT NULL DEFAULT '৳',
    locale               TEXT     NOT NULL DEFAULT 'en',       -- en, bn, ar, ur, hi
    timezone             TEXT     NOT NULL DEFAULT 'Asia/Dhaka',
    date_format          TEXT     NOT NULL DEFAULT 'DD-MM-YYYY',
    number_format        TEXT     NOT NULL DEFAULT 'en-IN',    -- 1,00,000 vs 100,000

    -- ─── Fiscal / Academic calendar ────────────────────────────
    fiscal_year_start_month  SMALLINT NOT NULL DEFAULT 1
        CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
    academic_year_start_month SMALLINT NOT NULL DEFAULT 1
        CHECK (academic_year_start_month BETWEEN 1 AND 12),

    -- ─── Receipt / Invoice template ────────────────────────────
    receipt_prefix       TEXT     NOT NULL DEFAULT 'PAY',
    receipt_footer       TEXT,                                 -- e.g. "Thank you. Non-refundable."
    invoice_prefix       TEXT     NOT NULL DEFAULT 'INV',
    school_motto         TEXT,                                 -- displayed on receipts/reports

    -- ─── Late fee policy (defaults — fee_types can override) ───
    late_fee_enabled     BOOLEAN  NOT NULL DEFAULT FALSE,
    late_fee_grace_days  SMALLINT NOT NULL DEFAULT 7
        CHECK (late_fee_grace_days >= 0),
    late_fee_type        TEXT     NOT NULL DEFAULT 'flat'
        CHECK (late_fee_type IN ('flat', 'percent')),
    late_fee_value       NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (late_fee_value >= 0),

    -- ─── Dashboard alerts ──────────────────────────────────────
    low_cash_threshold   NUMERIC(12,2) NOT NULL DEFAULT 0,     -- 0 = disabled
    overdue_alert_days   SMALLINT NOT NULL DEFAULT 30,

    -- ─── Brand / Contact (display only — overrides tenants.*) ──
    display_name         TEXT,
    display_address      TEXT,
    display_phone        TEXT,
    display_email        TEXT,

    -- ─── Audit ─────────────────────────────────────────────────
    created_at           TIMESTAMP DEFAULT NOW(),
    updated_at           TIMESTAMP NULL,
    updated_by_id        UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    -- ─── Sanity checks ─────────────────────────────────────────
    CONSTRAINT chk_settings_currency_format
        CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT chk_settings_receipt_prefix
        CHECK (receipt_prefix ~ '^[A-Z0-9]{1,10}$'),
    CONSTRAINT chk_settings_invoice_prefix
        CHECK (invoice_prefix ~ '^[A-Z0-9]{1,10}$')
);

-- One row per tenant, eager-initialize for the existing default tenant.
INSERT INTO tenant_settings (tenant_id)
SELECT id FROM tenants
ON CONFLICT (tenant_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────
-- Backfill new accounts for EXISTING tenants.
-- The updated seed_tenant_defaults() below adds 'Late Fee Income'
-- (needed by migration 028) and 'Fee Discount' (needed by 027), but
-- that function only fires for NEW tenants. For tenants already
-- seeded by migration 025, we add the rows here.
-- ────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_tenant   UUID;
    v_revenue  INT;
    v_expense  INT;
BEGIN
    FOR v_tenant IN SELECT id FROM tenants LOOP
        SELECT id INTO v_revenue FROM accounts
         WHERE tenant_id = v_tenant AND name = 'Revenue';
        SELECT id INTO v_expense FROM accounts
         WHERE tenant_id = v_tenant AND name = 'Expenses';

        IF v_revenue IS NOT NULL THEN
            INSERT INTO accounts (name, type, parent_id, tenant_id)
            VALUES ('Late Fee Income', 'revenue', v_revenue, v_tenant)
            ON CONFLICT (tenant_id, name) DO NOTHING;
        END IF;
        IF v_expense IS NOT NULL THEN
            INSERT INTO accounts (name, type, parent_id, tenant_id)
            VALUES ('Fee Discount', 'expense', v_expense, v_tenant)
            ON CONFLICT (tenant_id, name) DO NOTHING;
        END IF;
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────────
-- generate_receipt_no() must honour the per-tenant prefix.
-- We replace migration 017's version with one that reads the prefix.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_receipt_no(p_tenant_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_year   INT := EXTRACT(YEAR FROM NOW())::INT;
    v_next   INT;
    v_prefix TEXT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'generate_receipt_no: tenant_id must not be NULL';
    END IF;

    -- Read tenant-specific prefix; fall back to 'PAY' if no settings row.
    SELECT COALESCE(receipt_prefix, 'PAY') INTO v_prefix
    FROM tenant_settings
    WHERE tenant_id = p_tenant_id;

    IF v_prefix IS NULL THEN
        v_prefix := 'PAY';
    END IF;

    INSERT INTO tenant_counters (tenant_id, kind, year, last_value, updated_at)
    VALUES (p_tenant_id, 'receipt', v_year, 1, NOW())
    ON CONFLICT (tenant_id, kind, year)
    DO UPDATE SET
        last_value = tenant_counters.last_value + 1,
        updated_at = NOW()
    RETURNING last_value INTO v_next;

    RETURN v_prefix || '-' || v_year || '-' || LPAD(v_next::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;

-- ────────────────────────────────────────────────────────────────
-- Extend seed_tenant_defaults() so a new tenant gets a settings row.
-- We re-declare it; the body is identical to migration 025 PLUS the
-- final INSERT into tenant_settings.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION seed_tenant_defaults(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_assets_id   INT;
    v_liab_id     INT;
    v_equity_id   INT;
    v_revenue_id  INT;
    v_expense_id  INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'seed_tenant_defaults: tenant_id must not be NULL';
    END IF;

    -- Chart of Accounts
    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Assets', 'asset', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_assets_id;
    IF v_assets_id IS NULL THEN
        SELECT id INTO v_assets_id FROM accounts
         WHERE tenant_id = p_tenant_id AND name = 'Assets';
    END IF;

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Cash',                'asset',     v_assets_id, p_tenant_id),
        ('Bank',                'asset',     v_assets_id, p_tenant_id),
        ('Accounts Receivable', 'asset',     v_assets_id, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Liabilities', 'liability', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_liab_id;
    IF v_liab_id IS NULL THEN
        SELECT id INTO v_liab_id FROM accounts
         WHERE tenant_id = p_tenant_id AND name = 'Liabilities';
    END IF;

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Unearned Revenue', 'liability', v_liab_id, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Equity', 'equity', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_equity_id;
    IF v_equity_id IS NULL THEN
        SELECT id INTO v_equity_id FROM accounts
         WHERE tenant_id = p_tenant_id AND name = 'Equity';
    END IF;

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Opening Balance', 'equity', v_equity_id, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Revenue', 'revenue', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_revenue_id;
    IF v_revenue_id IS NULL THEN
        SELECT id INTO v_revenue_id FROM accounts
         WHERE tenant_id = p_tenant_id AND name = 'Revenue';
    END IF;

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Tuition Fees',    'revenue', v_revenue_id, p_tenant_id),
        ('Exam Fees',       'revenue', v_revenue_id, p_tenant_id),
        ('Hostel Fees',     'revenue', v_revenue_id, p_tenant_id),
        ('Donation Income', 'revenue', v_revenue_id, p_tenant_id),
        ('Zakat Income',    'revenue', v_revenue_id, p_tenant_id),
        ('Late Fee Income', 'revenue', v_revenue_id, p_tenant_id)  -- NEW: needed by 028
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Expenses', 'expense', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_expense_id;
    IF v_expense_id IS NULL THEN
        SELECT id INTO v_expense_id FROM accounts
         WHERE tenant_id = p_tenant_id AND name = 'Expenses';
    END IF;

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Salary Expense',      'expense', v_expense_id, p_tenant_id),
        ('Utilities Expense',   'expense', v_expense_id, p_tenant_id),
        ('Boarding Expense',    'expense', v_expense_id, p_tenant_id),
        ('Maintenance Expense', 'expense', v_expense_id, p_tenant_id),
        ('Stationery Expense',  'expense', v_expense_id, p_tenant_id),
        ('Transport Expense',   'expense', v_expense_id, p_tenant_id),
        ('Fee Discount',        'expense', v_expense_id, p_tenant_id)  -- NEW: needed by 027
    ON CONFLICT (tenant_id, name) DO NOTHING;

    -- Fee Types
    INSERT INTO fee_types (name, is_recurring, account_id, tenant_id)
    SELECT 'Tuition', TRUE, a.id, p_tenant_id
    FROM accounts a
    WHERE a.tenant_id = p_tenant_id AND a.name = 'Tuition Fees'
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO fee_types (name, is_recurring, account_id, tenant_id)
    SELECT 'Exam Fee', FALSE, a.id, p_tenant_id
    FROM accounts a
    WHERE a.tenant_id = p_tenant_id AND a.name = 'Exam Fees'
    ON CONFLICT (tenant_id, name) DO NOTHING;

    INSERT INTO fee_types (name, is_recurring, account_id, tenant_id)
    SELECT 'Hostel', TRUE, a.id, p_tenant_id
    FROM accounts a
    WHERE a.tenant_id = p_tenant_id AND a.name = 'Hostel Fees'
    ON CONFLICT (tenant_id, name) DO NOTHING;

    -- Current Academic Year
    INSERT INTO academic_years (name, start_date, end_date, is_current, tenant_id)
    VALUES (
        EXTRACT(YEAR FROM NOW())::TEXT,
        DATE_TRUNC('year', NOW())::DATE,
        (DATE_TRUNC('year', NOW()) + INTERVAL '1 year - 1 day')::DATE,
        TRUE,
        p_tenant_id
    )
    ON CONFLICT (tenant_id, name) DO NOTHING;

    -- NEW: Default settings row
    INSERT INTO tenant_settings (tenant_id)
    VALUES (p_tenant_id)
    ON CONFLICT (tenant_id) DO NOTHING;
END;
$$;

COMMENT ON TABLE tenant_settings IS
'One row per tenant. Holds currency, locale, fiscal year, receipt prefix, late-fee defaults, and display overrides.';
