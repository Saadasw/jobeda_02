-- ============================================================================
-- Migration 042: Backfill historical fee-revenue journal lines  (apply AFTER 041)
-- ============================================================================
-- Before 041, every fee journal credited 'Tuition Fees'. This re-points the
-- historical CREDIT line of each non-Tuition fee (Hostel, Exam, Meals, …) to the
-- fee's actual revenue account, so past income statements read correctly.
--
-- Why matching is needed: journal_entries.reference_type/reference_id are NOT
-- populated by the triggers, so there is no direct fee -> journal link. We match
-- the journal credit line by (tenant, date = fee.month, description, credit =
-- fee.amount, current account = Tuition Fees).
--
-- SAFE BY DESIGN:
--   * Only fees whose account_id <> the tenant's 'Tuition Fees' account.
--   * Updates ONLY when the match is UNIQUE. Ambiguous cases (e.g. two
--     same-amount non-Tuition fees for one student in one month) are SKIPPED,
--     never guessed.
--   * Touches only journal_lines.account_id (the revenue side). The Dr
--     Accounts-Receivable line and all amounts are untouched, so debits = credits
--     stay balanced.
--   * Idempotent: a re-run finds no Tuition-credit line for an already-moved
--     fee, so it does nothing.
-- Apply in the Supabase SQL editor (lltdojrxjdnwbwowqptb). Read the NOTICE output.
-- ============================================================================

DO $$
DECLARE
    fa        RECORD;
    v_tuition INT;
    v_line_id INT;
    v_n       INT;
    v_moved   INT := 0;
    v_ambig   INT := 0;
BEGIN
    FOR fa IN
        SELECT id, tenant_id, student_id, month, amount, account_id
        FROM fee_assignments
        WHERE account_id IS NOT NULL
    LOOP
        SELECT id INTO v_tuition
        FROM accounts
        WHERE tenant_id = fa.tenant_id AND name = 'Tuition Fees'
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

        -- Skip fees already pointing at Tuition (or where Tuition is missing).
        IF v_tuition IS NULL OR fa.account_id = v_tuition THEN
            CONTINUE;
        END IF;

        -- Locate the (currently mis-credited) Tuition credit line for this fee.
        SELECT count(*), min(jl.id) INTO v_n, v_line_id
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_id
        WHERE jl.tenant_id  = fa.tenant_id
          AND jl.account_id = v_tuition
          AND jl.credit     = fa.amount
          AND jl.debit      = 0
          AND je.date       = fa.month
          AND je.description = 'Fee assigned for student ' || fa.student_id;

        IF v_n = 1 THEN
            UPDATE journal_lines SET account_id = fa.account_id WHERE id = v_line_id;
            v_moved := v_moved + 1;
        ELSIF v_n > 1 THEN
            v_ambig := v_ambig + 1;   -- multiple candidates -> leave for manual review
        END IF;
        -- v_n = 0 -> nothing to move (already correct / already migrated): no-op.
    END LOOP;

    RAISE NOTICE 'Fee-revenue backfill complete: % line(s) re-pointed, % ambiguous skipped.', v_moved, v_ambig;
END $$;
