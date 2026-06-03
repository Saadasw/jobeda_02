-- Migration 005: Receipt Number Sequence
-- Used by the API to generate receipt numbers like PAY-2026-0001

CREATE SEQUENCE IF NOT EXISTS receipt_seq START 1;

-- Helper function to generate receipt numbers
CREATE OR REPLACE FUNCTION generate_receipt_no()
RETURNS TEXT AS $$
DECLARE
    v_year TEXT;
    v_seq INT;
BEGIN
    v_year := EXTRACT(YEAR FROM NOW())::TEXT;
    v_seq := nextval('receipt_seq');
    RETURN 'PAY-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;
