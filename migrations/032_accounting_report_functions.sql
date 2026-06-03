-- Migration 032: Accounting Report Functions
-- ================================================================
-- WHY:
--   Owners need standard reports without writing SQL: trial balance,
--   income statement, balance sheet, monthly collection. Up to 031
--   these are derivable from journal_lines but require complex
--   queries every time.
--
-- DESIGN:
--   * All reports are SQL functions returning TABLE.
--   * All filter by tenant_id (multi-tenant safe).
--   * All exclude reversed journal entries.
--   * Sign convention:
--       assets, expenses     → debit-positive (balance = SUM(debit) − SUM(credit))
--       liabilities, equity, revenue → credit-positive (balance = SUM(credit) − SUM(debit))
--   * Income statement net profit feeds into balance sheet equity
--     ("Retained earnings" computed inline).
--
-- USE FROM APP:
--   supabase.rpc('get_trial_balance',  { p_tenant_id: '…', p_as_of: '2026-12-31' })
--   supabase.rpc('get_income_statement', { p_tenant_id: '…', p_from: '2026-01-01', p_to: '2026-12-31' })
--   supabase.rpc('get_balance_sheet',  { p_tenant_id: '…', p_as_of: '2026-12-31' })
--   supabase.rpc('get_monthly_collection', { p_tenant_id: '…', p_year: 2026 })
--   supabase.rpc('get_general_ledger', { p_tenant_id: '…', p_account_id: 12, p_from: '…', p_to: '…' })
-- ================================================================

-- ════════════════════════════════════════════════════════════════
-- 1. get_trial_balance(tenant_id, as_of)
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_trial_balance(
    p_tenant_id UUID,
    p_as_of     DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
    account_id     INT,
    account_name   TEXT,
    account_type   TEXT,
    parent_id      INT,
    total_debit    NUMERIC,
    total_credit   NUMERIC,
    debit_balance  NUMERIC,
    credit_balance NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH agg AS (
        SELECT
            a.id              AS account_id,
            a.name            AS account_name,
            a.type            AS account_type,
            a.parent_id,
            COALESCE(SUM(jl.debit),  0) AS total_debit,
            COALESCE(SUM(jl.credit), 0) AS total_credit
        FROM accounts a
        LEFT JOIN journal_lines jl ON jl.account_id = a.id
            AND jl.tenant_id  = p_tenant_id
        LEFT JOIN journal_entries je ON je.id = jl.journal_id
            AND je.is_reversed = FALSE
            AND je.date <= p_as_of
        WHERE a.tenant_id  = p_tenant_id
          AND COALESCE(a.is_deleted, FALSE) = FALSE
        GROUP BY a.id, a.name, a.type, a.parent_id
    )
    SELECT
        account_id,
        account_name,
        account_type,
        parent_id,
        total_debit,
        total_credit,
        CASE WHEN account_type IN ('asset','expense')
             THEN GREATEST(total_debit  - total_credit, 0)
             ELSE 0 END AS debit_balance,
        CASE WHEN account_type IN ('liability','equity','revenue')
             THEN GREATEST(total_credit - total_debit, 0)
             ELSE 0 END AS credit_balance
    FROM agg
    ORDER BY
        CASE account_type
            WHEN 'asset'     THEN 1
            WHEN 'liability' THEN 2
            WHEN 'equity'    THEN 3
            WHEN 'revenue'   THEN 4
            WHEN 'expense'   THEN 5
            ELSE 6
        END,
        account_name;
$$;

COMMENT ON FUNCTION get_trial_balance(UUID, DATE) IS
'Trial balance as of a date. Returns one row per account with debit/credit totals and balanced columns.';

-- ════════════════════════════════════════════════════════════════
-- 2. get_income_statement(tenant_id, from, to)
--      Profit & Loss for a date range.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_income_statement(
    p_tenant_id UUID,
    p_from      DATE,
    p_to        DATE
) RETURNS TABLE (
    section        TEXT,       -- 'revenue', 'expense', 'summary'
    account_id     INT,
    account_name   TEXT,
    amount         NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH lines AS (
        SELECT a.id, a.name, a.type,
               COALESCE(SUM(jl.debit),  0) AS debit_total,
               COALESCE(SUM(jl.credit), 0) AS credit_total
        FROM accounts a
        LEFT JOIN journal_lines jl ON jl.account_id = a.id
            AND jl.tenant_id  = p_tenant_id
        LEFT JOIN journal_entries je ON je.id = jl.journal_id
            AND je.is_reversed = FALSE
            AND je.date BETWEEN p_from AND p_to
        WHERE a.tenant_id  = p_tenant_id
          AND COALESCE(a.is_deleted, FALSE) = FALSE
          AND a.type IN ('revenue','expense')
          AND a.parent_id IS NOT NULL          -- skip top-level "Revenue"/"Expenses" headers
        GROUP BY a.id, a.name, a.type
    ),
    rows AS (
        SELECT 'revenue'::TEXT  AS section, id AS account_id, name AS account_name,
               (credit_total - debit_total) AS amount
        FROM lines WHERE type = 'revenue'
        UNION ALL
        SELECT 'expense'::TEXT, id, name,
               (debit_total - credit_total)
        FROM lines WHERE type = 'expense'
    )
    SELECT * FROM rows
    UNION ALL
    SELECT 'summary'::TEXT, NULL::INT, 'Total Revenue',
           COALESCE(SUM(amount), 0)
        FROM rows WHERE section = 'revenue'
    UNION ALL
    SELECT 'summary'::TEXT, NULL::INT, 'Total Expense',
           COALESCE(SUM(amount), 0)
        FROM rows WHERE section = 'expense'
    UNION ALL
    SELECT 'summary'::TEXT, NULL::INT, 'Net Profit/Loss',
           COALESCE((SELECT SUM(amount) FROM rows WHERE section = 'revenue'), 0)
         - COALESCE((SELECT SUM(amount) FROM rows WHERE section = 'expense'), 0)
    ORDER BY section, account_name NULLS LAST;
$$;

COMMENT ON FUNCTION get_income_statement(UUID, DATE, DATE) IS
'P&L for a date range. Rows are tagged section: revenue, expense, or summary.';

-- ════════════════════════════════════════════════════════════════
-- 3. get_balance_sheet(tenant_id, as_of)
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_balance_sheet(
    p_tenant_id UUID,
    p_as_of     DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
    section       TEXT,        -- 'asset' | 'liability' | 'equity' | 'summary'
    account_id    INT,
    account_name  TEXT,
    amount        NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH balances AS (
        SELECT
            a.id, a.name, a.type,
            COALESCE(SUM(jl.debit),  0) AS d,
            COALESCE(SUM(jl.credit), 0) AS c
        FROM accounts a
        LEFT JOIN journal_lines jl ON jl.account_id = a.id
            AND jl.tenant_id  = p_tenant_id
        LEFT JOIN journal_entries je ON je.id = jl.journal_id
            AND je.is_reversed = FALSE
            AND je.date <= p_as_of
        WHERE a.tenant_id  = p_tenant_id
          AND COALESCE(a.is_deleted, FALSE) = FALSE
          AND a.parent_id IS NOT NULL
        GROUP BY a.id, a.name, a.type
    ),
    -- Net profit from inception to as_of (= retained earnings delta)
    pl AS (
        SELECT
            COALESCE(SUM(CASE WHEN a.type = 'revenue' THEN jl.credit - jl.debit END), 0)
          - COALESCE(SUM(CASE WHEN a.type = 'expense' THEN jl.debit - jl.credit END), 0)
              AS net_profit
        FROM accounts a
        LEFT JOIN journal_lines jl ON jl.account_id = a.id
            AND jl.tenant_id  = p_tenant_id
        LEFT JOIN journal_entries je ON je.id = jl.journal_id
            AND je.is_reversed = FALSE
            AND je.date <= p_as_of
        WHERE a.tenant_id  = p_tenant_id
          AND a.type IN ('revenue','expense')
    ),
    rows AS (
        SELECT 'asset'::TEXT      AS section, id AS account_id, name AS account_name,
               (d - c) AS amount
        FROM balances WHERE type = 'asset'
        UNION ALL
        SELECT 'liability'::TEXT, id, name,   (c - d) FROM balances WHERE type = 'liability'
        UNION ALL
        SELECT 'equity'::TEXT,    id, name,   (c - d) FROM balances WHERE type = 'equity'
        UNION ALL
        -- Retained earnings (net profit since inception) as part of equity
        SELECT 'equity'::TEXT, NULL::INT, 'Retained Earnings', (SELECT net_profit FROM pl)
    )
    -- The UNION is wrapped in a derived table so the outer ORDER BY can use a
    -- CASE expression. Postgres forbids expressions in a UNION's own ORDER BY
    -- (only output column names / ordinal positions are allowed there).
    SELECT section, account_id, account_name, amount
    FROM (
        SELECT * FROM rows
        UNION ALL
        SELECT 'summary', NULL, 'Total Assets',
               COALESCE(SUM(amount), 0) FROM rows WHERE section = 'asset'
        UNION ALL
        SELECT 'summary', NULL, 'Total Liabilities',
               COALESCE(SUM(amount), 0) FROM rows WHERE section = 'liability'
        UNION ALL
        SELECT 'summary', NULL, 'Total Equity',
               COALESCE(SUM(amount), 0) FROM rows WHERE section = 'equity'
        UNION ALL
        SELECT 'summary', NULL, 'Total Liabilities + Equity',
               COALESCE((SELECT SUM(amount) FROM rows WHERE section = 'liability'), 0)
             + COALESCE((SELECT SUM(amount) FROM rows WHERE section = 'equity'),    0)
    ) bs
    ORDER BY
        CASE section
            WHEN 'asset'     THEN 1
            WHEN 'liability' THEN 2
            WHEN 'equity'    THEN 3
            WHEN 'summary'   THEN 4
        END,
        account_name NULLS LAST;
$$;

COMMENT ON FUNCTION get_balance_sheet(UUID, DATE) IS
'Balance sheet as of date. Includes Retained Earnings under equity (net profit since inception).';

-- ════════════════════════════════════════════════════════════════
-- 4. get_monthly_collection(tenant_id, year)
--      Per-month roll-up of fee collections and discounts/late fees.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_monthly_collection(
    p_tenant_id UUID,
    p_year      INT
) RETURNS TABLE (
    month_num         SMALLINT,
    month_label       TEXT,
    payments_received NUMERIC,
    discounts_given   NUMERIC,
    late_fees_charged NUMERIC,
    expenses_paid     NUMERIC,
    net_inflow        NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH months AS (
        SELECT s::SMALLINT AS m FROM generate_series(1, 12) s
    ),
    pay AS (
        SELECT EXTRACT(MONTH FROM date)::SMALLINT AS m, SUM(amount) AS total
        FROM payments
        WHERE tenant_id  = p_tenant_id
          AND is_deleted = FALSE
          AND status     = 'completed'
          AND EXTRACT(YEAR FROM date) = p_year
        GROUP BY 1
    ),
    disc AS (
        SELECT EXTRACT(MONTH FROM d.created_at)::SMALLINT AS m, SUM(d.amount) AS total
        FROM fee_discounts d
        WHERE d.tenant_id  = p_tenant_id
          AND d.is_deleted = FALSE
          AND EXTRACT(YEAR FROM d.created_at) = p_year
        GROUP BY 1
    ),
    late AS (
        -- Late fees post via journal entries when apply_late_fees runs;
        -- use the journal_entries date for accuracy.
        SELECT EXTRACT(MONTH FROM je.date)::SMALLINT AS m, SUM(jl.credit) AS total
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_id AND je.is_reversed = FALSE
        JOIN accounts a ON a.id = jl.account_id
        WHERE jl.tenant_id = p_tenant_id
          AND a.name       = 'Late Fee Income'
          AND EXTRACT(YEAR FROM je.date) = p_year
        GROUP BY 1
    ),
    exp AS (
        SELECT EXTRACT(MONTH FROM date)::SMALLINT AS m, SUM(amount) AS total
        FROM expenses
        WHERE tenant_id  = p_tenant_id
          AND is_deleted = FALSE
          AND EXTRACT(YEAR FROM date) = p_year
        GROUP BY 1
    )
    SELECT
        months.m,
        TO_CHAR(MAKE_DATE(p_year, months.m, 1), 'Mon') AS month_label,
        COALESCE(pay.total,  0) AS payments_received,
        COALESCE(disc.total, 0) AS discounts_given,
        COALESCE(late.total, 0) AS late_fees_charged,
        COALESCE(exp.total,  0) AS expenses_paid,
        COALESCE(pay.total, 0) - COALESCE(exp.total, 0) AS net_inflow
    FROM months
    LEFT JOIN pay  ON pay.m  = months.m
    LEFT JOIN disc ON disc.m = months.m
    LEFT JOIN late ON late.m = months.m
    LEFT JOIN exp  ON exp.m  = months.m
    ORDER BY months.m;
$$;

COMMENT ON FUNCTION get_monthly_collection(UUID, INT) IS
'12-row monthly collection summary for one year, including discounts, late fees, expenses, and net inflow.';

-- ════════════════════════════════════════════════════════════════
-- 5. BONUS: get_general_ledger(tenant_id, account_id, from, to)
--      Line-by-line ledger entries for a single account with running balance.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_general_ledger(
    p_tenant_id  UUID,
    p_account_id INT,
    p_from       DATE,
    p_to         DATE
) RETURNS TABLE (
    entry_date      DATE,
    journal_id      INT,
    description     TEXT,
    debit           NUMERIC,
    credit          NUMERIC,
    running_balance NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH opening AS (
        SELECT
            a.type AS atype,
            COALESCE(SUM(jl.debit),  0) AS d,
            COALESCE(SUM(jl.credit), 0) AS c
        FROM accounts a
        LEFT JOIN journal_lines jl ON jl.account_id = a.id
            AND jl.tenant_id  = p_tenant_id
        LEFT JOIN journal_entries je ON je.id = jl.journal_id
            AND je.is_reversed = FALSE
            AND je.date < p_from
        WHERE a.id = p_account_id AND a.tenant_id = p_tenant_id
        GROUP BY a.type
    ),
    range_lines AS (
        SELECT
            je.date,
            je.id  AS journal_id,
            je.description,
            jl.debit,
            jl.credit,
            (SELECT atype FROM opening) AS atype,
            (SELECT CASE atype WHEN 'asset'   THEN d - c
                               WHEN 'expense' THEN d - c
                               ELSE c - d END FROM opening) AS opening_bal
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_id
        WHERE jl.tenant_id = p_tenant_id
          AND jl.account_id = p_account_id
          AND je.is_reversed = FALSE
          AND je.date BETWEEN p_from AND p_to
        ORDER BY je.date, je.id
    )
    SELECT
        date AS entry_date,
        journal_id,
        description,
        debit,
        credit,
        opening_bal +
            SUM(
                CASE WHEN atype IN ('asset','expense') THEN debit - credit
                     ELSE credit - debit END
            ) OVER (ORDER BY date, journal_id) AS running_balance
    FROM range_lines;
$$;

COMMENT ON FUNCTION get_general_ledger(UUID, INT, DATE, DATE) IS
'Line-by-line journal entries for a single account between two dates, with running balance.';

-- ════════════════════════════════════════════════════════════════
-- 6. BONUS: get_student_ledger(tenant_id, student_id)
--      All fees, discounts, and payment allocations for one student.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_student_ledger(
    p_tenant_id  UUID,
    p_student_id INT
) RETURNS TABLE (
    event_date    DATE,
    event_type    TEXT,         -- 'fee', 'discount', 'payment', 'late_fee'
    description   TEXT,
    debit         NUMERIC,
    credit        NUMERIC,
    running_due   NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH events AS (
        SELECT f.month::DATE AS event_date, 'fee'::TEXT AS event_type,
               COALESCE(ft.name, 'Fee') || ' for ' || TO_CHAR(f.month, 'Mon YYYY') AS description,
               f.amount AS debit, 0::NUMERIC AS credit, f.id AS ord_key
        FROM fee_assignments f
        LEFT JOIN fee_types ft ON ft.id = f.fee_type_id
        WHERE f.tenant_id  = p_tenant_id
          AND f.student_id = p_student_id
          AND f.is_deleted = FALSE
        UNION ALL
        SELECT d.created_at::DATE, 'discount',
               'Discount: ' || d.reason || COALESCE(' — ' || d.notes, ''),
               0, d.amount, d.id
        FROM fee_discounts d
        JOIN fee_assignments f ON f.id = d.fee_assignment_id
        WHERE d.tenant_id  = p_tenant_id
          AND d.is_deleted = FALSE
          AND f.student_id = p_student_id
        UNION ALL
        SELECT p.date, 'payment',
               'Payment ' || COALESCE(p.receipt_no, '(no receipt)'),
               0, p.amount, p.id
        FROM payments p
        WHERE p.tenant_id  = p_tenant_id
          AND p.student_id = p_student_id
          AND p.is_deleted = FALSE
          AND p.status     = 'completed'
        UNION ALL
        SELECT f.month::DATE, 'late_fee',
               'Late fee on ' || TO_CHAR(f.month, 'Mon YYYY'),
               COALESCE(f.late_fee_amount, 0), 0, f.id
        FROM fee_assignments f
        WHERE f.tenant_id  = p_tenant_id
          AND f.student_id = p_student_id
          AND COALESCE(f.late_fee_amount, 0) > 0
    )
    SELECT
        event_date,
        event_type,
        description,
        debit,
        credit,
        SUM(debit - credit) OVER (ORDER BY event_date, event_type, ord_key) AS running_due
    FROM events
    ORDER BY event_date, event_type, ord_key;
$$;

COMMENT ON FUNCTION get_student_ledger(UUID, INT) IS
'Per-student running ledger: every fee, discount, late fee, and payment with running due.';
