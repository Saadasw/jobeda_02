-- ============================================================================
-- Migration 041: Fee journals credit the fee's OWN revenue account
-- ============================================================================
-- BUG (since migration 015): trg_fee_assignment_journal() hardcoded the credit
--   to 'Tuition Fees' and IGNORED fee_assignments.account_id. So every fee —
--   Hostel, Exam, Meals, … — booked its revenue to "Tuition Fees" in the
--   general ledger.
--     * Student dues / balances were UNAFFECTED (those derive from
--       fee_assignments.amount, not the GL account).
--     * But the income statement MIS-CATEGORISED revenue (all fee income showed
--       as Tuition Fees). Confirmed: 9 Hostel + 1 Exam lines mis-credited.
--
-- FIX: resolve the revenue account from NEW.account_id (the fee type's account),
--   exactly like trg_income_journal() / trg_expense_journal() already do, with
--   the same cross-tenant safety check. A defensive COALESCE keeps the old
--   'Tuition Fees' behaviour only if account_id is ever NULL (today it never is).
--
-- The existing fee_assignment_after_insert trigger keeps pointing at this
-- function — CREATE OR REPLACE only refreshes the body, so no re-bind is needed.
-- FORWARD-ONLY: historical journal lines are corrected by migration 042.
-- Idempotent / safe to re-run. Apply in the Supabase SQL editor (lltdojrxjdnwbwowqptb).
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fee_assignment_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id     INT;
    v_account_name   TEXT;
    v_account_tenant UUID;
BEGIN
    -- Revenue account = the fee type's account, carried on the fee row.
    IF NEW.account_id IS NOT NULL THEN
        SELECT name, tenant_id INTO v_account_name, v_account_tenant
        FROM accounts WHERE id = NEW.account_id;

        IF v_account_tenant IS NOT NULL AND v_account_tenant <> NEW.tenant_id THEN
            RAISE EXCEPTION 'Cross-tenant fee account forbidden: fee tenant %, account % tenant %',
                NEW.tenant_id, NEW.account_id, v_account_tenant;
        END IF;
    END IF;

    -- Defensive: never break journaling if the account is unset/unresolved.
    v_account_name := COALESCE(v_account_name, 'Tuition Fees');

    v_journal_id := create_journal_entry(
        NEW.month,
        'Fee assigned for student ' || NEW.student_id,
        NEW.tenant_id
    );

    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, v_account_name,         0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
