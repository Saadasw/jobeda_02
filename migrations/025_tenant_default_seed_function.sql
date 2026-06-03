-- Migration 025: Tenant Default-Data Seed Function
-- ================================================================
-- plan_multi_user.md says: "On tenant creation, auto-seed:
--   - Default chart of accounts (21 accounts)
--   - Default fee types (Tuition, Exam, Hostel)
--   - Default academic year (current year)
--   - Owner user account"
--
-- plan_multi_tenant.md also says: "Phase 5: Seed Data ... create a
-- new migration that creates a default tenant. Update seed data to
-- include tenant_id on all inserts."
--
-- The plans expected this to live in services/onboarding.py
-- (application code). Putting it in the DB as a function has
-- advantages:
--   * Atomic — entire seed runs in one transaction
--   * Reusable — call from registration route OR from a CLI tool
--   * Idempotent — ON CONFLICT clauses prevent double seeding
--   * Triggers fire correctly (account name uniqueness etc.)
--
-- This is an UPGRADE BEYOND the plan, but consistent with its
-- intent.
-- ================================================================

CREATE OR REPLACE FUNCTION seed_tenant_defaults(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_assets_id      INT;
    v_liab_id        INT;
    v_equity_id      INT;
    v_revenue_id     INT;
    v_expense_id     INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'seed_tenant_defaults: tenant_id must not be NULL';
    END IF;

    -- ─── Chart of Accounts (21 accounts, mirrors migration 007) ──
    INSERT INTO accounts (name, type, parent_id, tenant_id)
    VALUES ('Assets', 'asset', NULL, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING
    RETURNING id INTO v_assets_id;

    -- ON CONFLICT NOTHING means RETURNING may be empty; fetch in either case.
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
        ('Zakat Income',    'revenue', v_revenue_id, p_tenant_id)
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
        ('Transport Expense',   'expense', v_expense_id, p_tenant_id)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    -- ─── Fee Types (linked to revenue accounts of THIS tenant) ──
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

    -- ─── Current Academic Year ─────────────────────────────────
    INSERT INTO academic_years (name, start_date, end_date, is_current, tenant_id)
    VALUES (
        EXTRACT(YEAR FROM NOW())::TEXT,
        DATE_TRUNC('year', NOW())::DATE,
        (DATE_TRUNC('year', NOW()) + INTERVAL '1 year - 1 day')::DATE,
        TRUE,
        p_tenant_id
    )
    ON CONFLICT (tenant_id, name) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION seed_tenant_defaults(UUID) IS
'Seeds the 21 default accounts, 3 default fee types, and the current academic year for a new tenant. Idempotent. Called from /auth/register.';
