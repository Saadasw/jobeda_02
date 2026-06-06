-- Migration 035: Fix payment-allocation double-counting of Cash
-- ================================================================
-- BUG (pre-existing, from migration 015):
--   Two triggers both debited Cash for the SAME money:
--     * trg_payment_advance_journal (on payment INSERT) posts the full,
--       not-yet-allocated payment as  Dr Cash / Cr Unearned Revenue.
--     * trg_payment_allocation_journal (per allocation) ALSO posted
--       Dr Cash / Cr Accounts Receivable — debiting Cash a second time.
--   A fully-allocated payment therefore debited Cash twice. Cash and
--   Unearned Revenue were both overstated by the allocated amount. (Every
--   journal entry was internally balanced, so the trial balance still
--   balanced — but those two account balances were wrong, which is why the
--   dashboard's "Cash in Hand" was inflated.)
--
-- FIX:
--   Allocating a payment brings in no new cash — the cash already arrived
--   via the advance entry. Allocation only reclassifies that advance to
--   settle the receivable:
--       Dr Unearned Revenue / Cr Accounts Receivable
--   so Cash is debited exactly once and Unearned Revenue nets down to only
--   the genuinely-unapplied advance.
--
--   Worked example (payment 5000, fees 4000, 1000 overpaid):
--       advance:      Dr Cash 5000     / Cr Unearned 5000
--       allocations:  Dr Unearned 4000 / Cr A/R 4000
--     => Cash +5000 (real), A/R 0 (settled), Unearned 1000 (true advance). ✓
-- ================================================================

-- ─── 1. Corrected trigger function ──────────────────────────────
-- (Trigger binding `payment_allocation_after_insert` from migration 015 is
--  unchanged; CREATE OR REPLACE only swaps the function body.)
CREATE OR REPLACE FUNCTION trg_payment_allocation_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_payment RECORD;
    v_journal_id INT;
BEGIN
    SELECT * INTO v_payment FROM payments WHERE id = NEW.payment_id;

    -- Safety: payment.tenant_id must equal allocation.tenant_id
    IF v_payment.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant allocation forbidden: payment % tenant %, allocation tenant %',
            NEW.payment_id, v_payment.tenant_id, NEW.tenant_id;
    END IF;

    v_journal_id := create_journal_entry(
        v_payment.date,
        'Payment allocation for student ' || v_payment.student_id,
        NEW.tenant_id
    );

    -- Reclassify the already-received advance to settle the receivable.
    -- (Previously this debited Cash, double-counting the cash receipt.)
    PERFORM add_journal_line(v_journal_id, 'Unearned Revenue',    NEW.amount, 0,          NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', 0,          NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─── 2. One-time backfill of existing allocation journals ───────
-- Move each existing allocation entry's Cash *debit* line onto Unearned
-- Revenue. Scoped precisely to allocation journals (by description) and to
-- the Cash debit line only. Idempotent: after this runs those lines are on
-- Unearned Revenue, so the Cash filter no longer matches on a re-run.
UPDATE journal_lines jl
SET account_id = ua.id
FROM journal_entries je,
     accounts ca,
     accounts ua
WHERE jl.journal_id = je.id
  AND je.description LIKE 'Payment allocation for student %'
  AND je.is_reversed = FALSE
  AND jl.debit > 0
  AND ca.tenant_id = jl.tenant_id AND ca.name = 'Cash'
  AND jl.account_id = ca.id
  AND ua.tenant_id = jl.tenant_id AND ua.name = 'Unearned Revenue';

-- After applying:
--   * Cash in Hand reflects only real cash movements.
--   * Unearned Revenue holds only genuine advances/overpayments.
--   * Going forward, new allocations post Dr Unearned Revenue / Cr A/R.
