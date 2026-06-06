-- ============================================================================
-- SEED DATA for Jobeda Madrasa ERP  —  FULL multi-tenant schema
-- ============================================================================
-- ⚠️  RUN THIS AFTER ALL MIGRATIONS (001–033), not in mid-sequence.
--
--     This file sits at position 007 for historical reasons, but it now
--     seeds the COMPLETE post-migration schema (multi-tenancy, users,
--     payroll, exams, attendance, discounts, notifications). During a fresh
--     sequential migration run the new tables do not exist yet at step 7, so
--     the block below GUARDS itself: if the final-schema tables are missing
--     it logs a notice and exits without error. Re-run it once every
--     migration has been applied to populate the demo data.
--
-- WHAT IT DOES (all scoped to the default 'jobeda' tenant, resolved at runtime):
--   * Ensures config/defaults exist: 24 chart-of-accounts, 3 fee types,
--     2 academic years, 5 classes, 7 sections, 4 subjects, the default grade
--     scale, and one owner user.
--   * Wipes this tenant's demo TRANSACTIONAL + people data (FK-safe) and
--     rebuilds it deterministically — so the seed is idempotent/repeatable.
--   * Seeds students, employees, salary structures, fee assignments, payments
--     + allocations, salary payments, expenses, income, an exam with marks →
--     report cards + positions, attendance, draft payslips, a salary advance,
--     a fee discount, and queued notifications.
--
-- ACCOUNTING: every financial insert carries tenant_id; DB triggers auto-post
-- the double-entry journal (tenant-aware, account lookups scoped by tenant).
--
-- DEMO LOGIN:  owner@jobeda.com  /  Owner@123   (role: owner)
-- ============================================================================

DO $$
DECLARE
    v_tenant      UUID;
    v_owner_role  INT;
    v_user        UUID;

    -- account ids
    v_a_assets INT; v_a_liab INT; v_a_equity INT; v_a_rev INT; v_a_exp INT;
    v_cash INT; v_bank INT; v_tuition INT; v_examfee INT; v_hostel INT;
    v_donation INT; v_zakat INT;
    v_util INT; v_boarding INT; v_maint INT; v_stationery INT; v_transport INT;

    -- fee types
    v_ft_tuition INT; v_ft_exam INT; v_ft_hostel INT;

    -- academic structure
    v_ay2025 INT; v_ay2026 INT;
    v_c1 INT; v_c2 INT; v_c3 INT; v_c4 INT; v_c5 INT;
    v_secC1A INT; v_secC1B INT; v_secC2A INT; v_secC3A INT; v_secC3B INT;
    v_secC4A INT; v_secC5A INT;

    -- people
    v_s1 INT; v_s2 INT; v_s3 INT; v_s4 INT; v_s5 INT; v_s6 INT; v_s7 INT; v_s8 INT;
    v_e1 INT; v_e2 INT; v_e3 INT; v_e4 INT;

    -- payments
    v_p1 INT; v_p2 INT; v_p3 INT; v_p4 INT; v_p5 INT;
    v_p6 INT; v_p7 INT; v_p8 INT; v_p9 INT; v_p10 INT;

    -- exams / subjects
    v_quran INT; v_tajweed INT; v_arabic INT; v_fiqh INT;
    v_scale INT; v_exam INT; v_jid INT;

    -- loop helpers
    v_stu RECORD; v_es RECORD; v_emp RECORD;
    v_sub_off INT; v_score NUMERIC;
BEGIN
    -- ── 0. Schema-completeness guard ──────────────────────────────
    IF to_regclass('public.users')         IS NULL
       OR to_regclass('public.exams')         IS NULL
       OR to_regclass('public.payslips')      IS NULL
       OR to_regclass('public.notifications') IS NULL
       OR to_regclass('public.grade_scales')  IS NULL THEN
        RAISE NOTICE '007 seed: final-schema tables not present yet — run AFTER migrations 001–033. Skipping.';
        RETURN;
    END IF;

    -- ── 1. Resolve / create the default tenant ────────────────────
    SELECT id INTO v_tenant FROM tenants WHERE slug = 'jobeda' LIMIT 1;
    IF v_tenant IS NULL THEN
        INSERT INTO tenants (name, slug, is_active)
        VALUES ('Jobeda Hafizia Madrasa', 'jobeda', TRUE)
        RETURNING id INTO v_tenant;
    END IF;

    -- ── 2. Chart of accounts (24) — parents then children ─────────
    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Assets',      'asset',     NULL, v_tenant),
        ('Liabilities', 'liability', NULL, v_tenant),
        ('Equity',      'equity',    NULL, v_tenant),
        ('Revenue',     'revenue',   NULL, v_tenant),
        ('Expenses',    'expense',   NULL, v_tenant)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    SELECT id INTO v_a_assets FROM accounts WHERE tenant_id = v_tenant AND name = 'Assets';
    SELECT id INTO v_a_liab   FROM accounts WHERE tenant_id = v_tenant AND name = 'Liabilities';
    SELECT id INTO v_a_equity FROM accounts WHERE tenant_id = v_tenant AND name = 'Equity';
    SELECT id INTO v_a_rev    FROM accounts WHERE tenant_id = v_tenant AND name = 'Revenue';
    SELECT id INTO v_a_exp    FROM accounts WHERE tenant_id = v_tenant AND name = 'Expenses';

    INSERT INTO accounts (name, type, parent_id, tenant_id) VALUES
        ('Cash',                'asset',     v_a_assets, v_tenant),
        ('Bank',                'asset',     v_a_assets, v_tenant),
        ('Accounts Receivable', 'asset',     v_a_assets, v_tenant),
        ('Salary Advances',     'asset',     v_a_assets, v_tenant),
        ('Unearned Revenue',    'liability', v_a_liab,   v_tenant),
        ('Opening Balance',     'equity',    v_a_equity, v_tenant),
        ('Tuition Fees',        'revenue',   v_a_rev,    v_tenant),
        ('Exam Fees',           'revenue',   v_a_rev,    v_tenant),
        ('Hostel Fees',         'revenue',   v_a_rev,    v_tenant),
        ('Donation Income',     'revenue',   v_a_rev,    v_tenant),
        ('Zakat Income',        'revenue',   v_a_rev,    v_tenant),
        ('Late Fee Income',     'revenue',   v_a_rev,    v_tenant),
        ('Salary Expense',      'expense',   v_a_exp,    v_tenant),
        ('Utilities Expense',   'expense',   v_a_exp,    v_tenant),
        ('Boarding Expense',    'expense',   v_a_exp,    v_tenant),
        ('Maintenance Expense', 'expense',   v_a_exp,    v_tenant),
        ('Stationery Expense',  'expense',   v_a_exp,    v_tenant),
        ('Transport Expense',   'expense',   v_a_exp,    v_tenant),
        ('Fee Discount',        'expense',   v_a_exp,    v_tenant)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    SELECT id INTO v_cash       FROM accounts WHERE tenant_id = v_tenant AND name = 'Cash';
    SELECT id INTO v_bank       FROM accounts WHERE tenant_id = v_tenant AND name = 'Bank';
    SELECT id INTO v_tuition    FROM accounts WHERE tenant_id = v_tenant AND name = 'Tuition Fees';
    SELECT id INTO v_examfee    FROM accounts WHERE tenant_id = v_tenant AND name = 'Exam Fees';
    SELECT id INTO v_hostel     FROM accounts WHERE tenant_id = v_tenant AND name = 'Hostel Fees';
    SELECT id INTO v_donation   FROM accounts WHERE tenant_id = v_tenant AND name = 'Donation Income';
    SELECT id INTO v_zakat      FROM accounts WHERE tenant_id = v_tenant AND name = 'Zakat Income';
    SELECT id INTO v_util       FROM accounts WHERE tenant_id = v_tenant AND name = 'Utilities Expense';
    SELECT id INTO v_boarding   FROM accounts WHERE tenant_id = v_tenant AND name = 'Boarding Expense';
    SELECT id INTO v_maint      FROM accounts WHERE tenant_id = v_tenant AND name = 'Maintenance Expense';
    SELECT id INTO v_stationery FROM accounts WHERE tenant_id = v_tenant AND name = 'Stationery Expense';
    SELECT id INTO v_transport  FROM accounts WHERE tenant_id = v_tenant AND name = 'Transport Expense';

    -- ── 3. Fee types ──────────────────────────────────────────────
    INSERT INTO fee_types (name, is_recurring, account_id, tenant_id) VALUES
        ('Tuition',  TRUE,  v_tuition, v_tenant),
        ('Exam Fee', FALSE, v_examfee, v_tenant),
        ('Hostel',   TRUE,  v_hostel,  v_tenant)
    ON CONFLICT (tenant_id, name) DO NOTHING;

    SELECT id INTO v_ft_tuition FROM fee_types WHERE tenant_id = v_tenant AND name = 'Tuition';
    SELECT id INTO v_ft_exam    FROM fee_types WHERE tenant_id = v_tenant AND name = 'Exam Fee';
    SELECT id INTO v_ft_hostel  FROM fee_types WHERE tenant_id = v_tenant AND name = 'Hostel';

    -- ── 4. Academic years / classes / sections ────────────────────
    UPDATE academic_years SET is_current = FALSE
     WHERE tenant_id = v_tenant AND is_current = TRUE AND name <> '2026';

    INSERT INTO academic_years (name, start_date, end_date, is_current, tenant_id) VALUES
        ('2025', '2025-01-01', '2025-12-31', FALSE, v_tenant),
        ('2026', '2026-01-01', '2026-12-31', TRUE,  v_tenant)
    ON CONFLICT (tenant_id, name) DO NOTHING;
    SELECT id INTO v_ay2025 FROM academic_years WHERE tenant_id = v_tenant AND name = '2025';
    SELECT id INTO v_ay2026 FROM academic_years WHERE tenant_id = v_tenant AND name = '2026';

    INSERT INTO classes (name, tenant_id) VALUES
        ('Nazera-1', v_tenant), ('Nazera-2', v_tenant), ('Hifz-1', v_tenant),
        ('Hifz-2', v_tenant), ('Hifz-3', v_tenant)
    ON CONFLICT (tenant_id, name) DO NOTHING;
    SELECT id INTO v_c1 FROM classes WHERE tenant_id = v_tenant AND name = 'Nazera-1';
    SELECT id INTO v_c2 FROM classes WHERE tenant_id = v_tenant AND name = 'Nazera-2';
    SELECT id INTO v_c3 FROM classes WHERE tenant_id = v_tenant AND name = 'Hifz-1';
    SELECT id INTO v_c4 FROM classes WHERE tenant_id = v_tenant AND name = 'Hifz-2';
    SELECT id INTO v_c5 FROM classes WHERE tenant_id = v_tenant AND name = 'Hifz-3';

    INSERT INTO sections (class_id, name, tenant_id) VALUES
        (v_c1, 'A', v_tenant), (v_c1, 'B', v_tenant), (v_c2, 'A', v_tenant),
        (v_c3, 'A', v_tenant), (v_c3, 'B', v_tenant), (v_c4, 'A', v_tenant),
        (v_c5, 'A', v_tenant)
    ON CONFLICT (tenant_id, class_id, name) DO NOTHING;
    SELECT id INTO v_secC1A FROM sections WHERE tenant_id = v_tenant AND class_id = v_c1 AND name = 'A';
    SELECT id INTO v_secC1B FROM sections WHERE tenant_id = v_tenant AND class_id = v_c1 AND name = 'B';
    SELECT id INTO v_secC2A FROM sections WHERE tenant_id = v_tenant AND class_id = v_c2 AND name = 'A';
    SELECT id INTO v_secC3A FROM sections WHERE tenant_id = v_tenant AND class_id = v_c3 AND name = 'A';
    SELECT id INTO v_secC3B FROM sections WHERE tenant_id = v_tenant AND class_id = v_c3 AND name = 'B';
    SELECT id INTO v_secC4A FROM sections WHERE tenant_id = v_tenant AND class_id = v_c4 AND name = 'A';
    SELECT id INTO v_secC5A FROM sections WHERE tenant_id = v_tenant AND class_id = v_c5 AND name = 'A';

    -- ── 5. Owner user (one per tenant) ────────────────────────────
    SELECT id INTO v_owner_role FROM roles WHERE name = 'owner';
    SELECT id INTO v_user FROM users
     WHERE tenant_id = v_tenant AND email_lower = 'owner@jobeda.com';
    IF v_user IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM users WHERE tenant_id = v_tenant AND role_id = v_owner_role) THEN
            INSERT INTO users (tenant_id, email, password_hash, full_name, phone, role_id, is_active)
            VALUES (v_tenant, 'owner@jobeda.com',
                    '$2b$12$xyiCD4LuiKek0WIuUuFWH.H.dHFCENH5eIGsMl3/fUvHhZelvlnrC',
                    'Madrasa Owner', '01700000000', v_owner_role, TRUE)
            RETURNING id INTO v_user;
        ELSE
            SELECT id INTO v_user FROM users
             WHERE tenant_id = v_tenant AND role_id = v_owner_role LIMIT 1;
        END IF;
    END IF;

    -- ── 6. Subjects + class-subject links (Hifz-1) ────────────────
    INSERT INTO subjects (tenant_id, name, code, description) VALUES
        (v_tenant, 'Quran Memorization', 'HIFZ', 'Memorization of the Holy Quran'),
        (v_tenant, 'Tajweed',            'TAJ',  'Rules of Quranic recitation'),
        (v_tenant, 'Arabic',             'ARB',  'Arabic language'),
        (v_tenant, 'Fiqh',               'FIQH', 'Islamic jurisprudence')
    ON CONFLICT (tenant_id, name) DO NOTHING;
    SELECT id INTO v_quran   FROM subjects WHERE tenant_id = v_tenant AND name = 'Quran Memorization';
    SELECT id INTO v_tajweed FROM subjects WHERE tenant_id = v_tenant AND name = 'Tajweed';
    SELECT id INTO v_arabic  FROM subjects WHERE tenant_id = v_tenant AND name = 'Arabic';
    SELECT id INTO v_fiqh    FROM subjects WHERE tenant_id = v_tenant AND name = 'Fiqh';

    INSERT INTO class_subjects (tenant_id, class_id, subject_id) VALUES
        (v_tenant, v_c3, v_quran), (v_tenant, v_c3, v_tajweed),
        (v_tenant, v_c3, v_arabic), (v_tenant, v_c3, v_fiqh)
    ON CONFLICT (class_id, subject_id) DO NOTHING;

    -- Default grade scale (seeded by migration 030; ensure it exists).
    SELECT id INTO v_scale FROM grade_scales
     WHERE tenant_id = v_tenant AND is_default = TRUE AND is_active = TRUE LIMIT 1;
    IF v_scale IS NULL THEN
        INSERT INTO grade_scales (tenant_id, name, is_default)
        VALUES (v_tenant, 'Standard 100-point', TRUE)
        ON CONFLICT (tenant_id, name) DO NOTHING
        RETURNING id INTO v_scale;
        IF v_scale IS NULL THEN
            SELECT id INTO v_scale FROM grade_scales
             WHERE tenant_id = v_tenant AND name = 'Standard 100-point';
        END IF;
        INSERT INTO grade_scale_bands (grade_scale_id, grade_name, min_percent, max_percent, grade_point, is_pass) VALUES
            (v_scale, 'A+', 80, 100, 5.00, TRUE), (v_scale, 'A', 70, 79.99, 4.00, TRUE),
            (v_scale, 'A-', 60, 69.99, 3.50, TRUE), (v_scale, 'B', 50, 59.99, 3.00, TRUE),
            (v_scale, 'C', 40, 49.99, 2.00, TRUE), (v_scale, 'D', 33, 39.99, 1.00, TRUE),
            (v_scale, 'F', 0, 32.99, 0.00, FALSE)
        ON CONFLICT (grade_scale_id, grade_name) DO NOTHING;
    END IF;

    -- ══════════════════════════════════════════════════════════════
    --  CLEAN SLATE — wipe this tenant's demo transactional + people
    --  data (FK-safe: children → parents). Journals are removed too
    --  and re-posted by the triggers as data is re-seeded below.
    -- ══════════════════════════════════════════════════════════════
    DELETE FROM journal_lines       WHERE tenant_id = v_tenant;
    DELETE FROM journal_entries     WHERE tenant_id = v_tenant;
    DELETE FROM notifications       WHERE tenant_id = v_tenant;
    DELETE FROM payment_allocations WHERE tenant_id = v_tenant;
    DELETE FROM fee_discounts       WHERE tenant_id = v_tenant;
    DELETE FROM payments            WHERE tenant_id = v_tenant;
    DELETE FROM marks               WHERE tenant_id = v_tenant;
    DELETE FROM report_cards        WHERE tenant_id = v_tenant;
    DELETE FROM exam_subjects       WHERE tenant_id = v_tenant;
    DELETE FROM exams               WHERE tenant_id = v_tenant;
    DELETE FROM student_attendance  WHERE tenant_id = v_tenant;
    DELETE FROM staff_attendance    WHERE tenant_id = v_tenant;
    DELETE FROM salary_payments     WHERE tenant_id = v_tenant;
    DELETE FROM payslips            WHERE tenant_id = v_tenant;
    DELETE FROM salary_advances     WHERE tenant_id = v_tenant;
    DELETE FROM salary_structures   WHERE tenant_id = v_tenant;
    DELETE FROM fee_assignments     WHERE tenant_id = v_tenant;
    DELETE FROM expenses            WHERE tenant_id = v_tenant;
    DELETE FROM income              WHERE tenant_id = v_tenant;
    DELETE FROM students            WHERE tenant_id = v_tenant;
    DELETE FROM employees           WHERE tenant_id = v_tenant;

    -- ── Opening cash balance ──────────────────────────────────────
    --   A real madrasa starts with reserves (donations / waqf / founder
    --   capital) before it pays any salaries. Without this, Cash would be
    --   deeply negative. Posts Dr Cash / Cr Opening Balance (equity).
    v_jid := create_journal_entry('2026-01-01', 'Opening cash balance', v_tenant);
    PERFORM add_journal_line(v_jid, 'Cash',            200000, 0,      v_tenant);
    PERFORM add_journal_line(v_jid, 'Opening Balance', 0,      200000, v_tenant);

    -- ── 7. Students ───────────────────────────────────────────────
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Ahmed Hossain', 'Hifz-1', v_c3, v_secC3A, v_ay2026, v_tenant) RETURNING id INTO v_s1;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Yusuf Rahman', 'Hifz-1', v_c3, v_secC3B, v_ay2026, v_tenant) RETURNING id INTO v_s2;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Khadija Akter', 'Nazera-1', v_c1, v_secC1A, v_ay2026, v_tenant) RETURNING id INTO v_s3;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Ibrahim Khan', 'Hifz-2', v_c4, v_secC4A, v_ay2026, v_tenant) RETURNING id INTO v_s4;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Fatima Begum', 'Nazera-2', v_c2, v_secC2A, v_ay2026, v_tenant) RETURNING id INTO v_s5;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Hamza Ali', 'Hifz-3', v_c5, v_secC5A, v_ay2026, v_tenant) RETURNING id INTO v_s6;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Aisha Sultana', 'Nazera-1', v_c1, v_secC1B, v_ay2026, v_tenant) RETURNING id INTO v_s7;
    INSERT INTO students (name, class, class_id, section_id, academic_year_id, tenant_id)
    VALUES ('Omar Faruk', 'Hifz-1', v_c3, v_secC3A, v_ay2026, v_tenant) RETURNING id INTO v_s8;

    -- ── 8. Employees ──────────────────────────────────────────────
    INSERT INTO employees (name, role, phone, salary, tenant_id)
    VALUES ('Maulana Abdul Karim', 'teacher', '01711111111', 15000.00, v_tenant) RETURNING id INTO v_e1;
    INSERT INTO employees (name, role, phone, salary, tenant_id)
    VALUES ('Hafiz Nurul Islam', 'teacher', '01722222222', 12000.00, v_tenant) RETURNING id INTO v_e2;
    INSERT INTO employees (name, role, phone, salary, tenant_id)
    VALUES ('Jamal Uddin', 'staff', '01733333333', 8000.00, v_tenant) RETURNING id INTO v_e3;
    INSERT INTO employees (name, role, phone, salary, tenant_id)
    VALUES ('Rahim Sheikh', 'admin', '01744444444', 18000.00, v_tenant) RETURNING id INTO v_e4;

    -- ── 9. Salary structures (active; gross is generated) ─────────
    INSERT INTO salary_structures (tenant_id, employee_id, basic, effective_from) VALUES
        (v_tenant, v_e1, 15000.00, '2026-01-01'),
        (v_tenant, v_e2, 12000.00, '2026-01-01'),
        (v_tenant, v_e3,  8000.00, '2026-01-01'),
        (v_tenant, v_e4, 18000.00, '2026-01-01');

    -- ── 10. Fee assignments (29) — trigger: Dr A/R / Cr Tuition Fees
    INSERT INTO fee_assignments (tenant_id, student_id, month, amount, account_id, fee_type_id, due_date) VALUES
        (v_tenant, v_s1, '2026-01-01', 2000.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s1, '2026-02-01', 2000.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s1, '2026-03-01', 2000.00, v_tuition, v_ft_tuition, '2026-03-10'),
        (v_tenant, v_s1, '2026-04-01', 2000.00, v_tuition, v_ft_tuition, '2026-04-10'),
        (v_tenant, v_s1, '2026-05-01', 2000.00, v_tuition, v_ft_tuition, '2026-05-10'),
        (v_tenant, v_s2, '2026-01-01', 2000.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s2, '2026-02-01', 2000.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s2, '2026-03-01', 2000.00, v_tuition, v_ft_tuition, '2026-03-10'),
        (v_tenant, v_s2, '2026-04-01', 2000.00, v_tuition, v_ft_tuition, '2026-04-10'),
        (v_tenant, v_s2, '2026-05-01', 2000.00, v_tuition, v_ft_tuition, '2026-05-10'),
        (v_tenant, v_s3, '2026-01-01', 1500.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s3, '2026-02-01', 1500.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s3, '2026-03-01', 1500.00, v_tuition, v_ft_tuition, '2026-03-10'),
        (v_tenant, v_s3, '2026-04-01', 1500.00, v_tuition, v_ft_tuition, '2026-04-10'),
        (v_tenant, v_s4, '2026-01-01', 2500.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s4, '2026-02-01', 2500.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s4, '2026-03-01', 2500.00, v_tuition, v_ft_tuition, '2026-03-10'),
        (v_tenant, v_s4, '2026-01-01', 1000.00, v_hostel,  v_ft_hostel,  '2026-01-10'),
        (v_tenant, v_s4, '2026-02-01', 1000.00, v_hostel,  v_ft_hostel,  '2026-02-10'),
        (v_tenant, v_s4, '2026-03-01', 1000.00, v_hostel,  v_ft_hostel,  '2026-03-10'),
        (v_tenant, v_s5, '2026-01-01', 1500.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s5, '2026-02-01', 1500.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s5, '2026-03-01',  500.00, v_examfee, v_ft_exam,    '2026-03-10'),
        (v_tenant, v_s6, '2026-01-01', 2000.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s6, '2026-02-01', 2000.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s7, '2026-01-01', 1500.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s7, '2026-02-01', 1500.00, v_tuition, v_ft_tuition, '2026-02-10'),
        (v_tenant, v_s8, '2026-01-01', 2000.00, v_tuition, v_ft_tuition, '2026-01-10'),
        (v_tenant, v_s8, '2026-02-01', 2000.00, v_tuition, v_ft_tuition, '2026-02-10');

    -- ── 11. Payments (trigger books unallocated remainder as advance)
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s1, 4000.00, '2026-01-15', 'cash', 'completed', 'PAY-2026-0001', v_cash) RETURNING id INTO v_p1;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s1, 4000.00, '2026-03-10', 'cash', 'completed', 'PAY-2026-0002', v_cash) RETURNING id INTO v_p2;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s2, 4000.00, '2026-01-20', 'cash', 'completed', 'PAY-2026-0003', v_cash) RETURNING id INTO v_p3;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s3, 3000.00, '2026-01-10', 'cash', 'completed', 'PAY-2026-0004', v_cash) RETURNING id INTO v_p4;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s3, 3000.00, '2026-03-05', 'bank', 'completed', 'PAY-2026-0005', v_bank) RETURNING id INTO v_p5;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s4, 5000.00, '2026-01-18', 'cash', 'completed', 'PAY-2026-0006', v_cash) RETURNING id INTO v_p6;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s4, 2500.00, '2026-03-01', 'cash', 'completed', 'PAY-2026-0007', v_cash) RETURNING id INTO v_p7;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s5, 2000.00, '2026-01-25', 'cash', 'completed', 'PAY-2026-0008', v_cash) RETURNING id INTO v_p8;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s7, 1500.00, '2026-01-12', 'cash', 'completed', 'PAY-2026-0009', v_cash) RETURNING id INTO v_p9;
    INSERT INTO payments (tenant_id, student_id, amount, date, method, status, receipt_no, cash_account_id)
    VALUES (v_tenant, v_s8, 5000.00, '2026-01-30', 'cash', 'completed', 'PAY-2026-0010', v_cash) RETURNING id INTO v_p10;

    -- ── 12. Payment allocations (trigger: Dr Cash / Cr A/R) ───────
    --        Fee rows resolved by (student, fee_type, month).
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p1, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s1 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p1, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s1 AND fee_type_id=v_ft_tuition AND month='2026-02-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p2, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s1 AND fee_type_id=v_ft_tuition AND month='2026-03-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p2, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s1 AND fee_type_id=v_ft_tuition AND month='2026-04-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p3, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s2 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p3, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s2 AND fee_type_id=v_ft_tuition AND month='2026-02-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p4, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s3 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p4, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s3 AND fee_type_id=v_ft_tuition AND month='2026-02-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p5, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s3 AND fee_type_id=v_ft_tuition AND month='2026-03-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p5, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s3 AND fee_type_id=v_ft_tuition AND month='2026-04-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p6, id, 2500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s4 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p6, id, 2500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s4 AND fee_type_id=v_ft_tuition AND month='2026-02-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p7, id, 2500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s4 AND fee_type_id=v_ft_tuition AND month='2026-03-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p8, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s5 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p8, id, 500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s5 AND fee_type_id=v_ft_tuition AND month='2026-02-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p9, id, 1500 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s7 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p10, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s8 AND fee_type_id=v_ft_tuition AND month='2026-01-01';
    INSERT INTO payment_allocations (tenant_id, payment_id, fee_assignment_id, amount)
        SELECT v_tenant, v_p10, id, 2000 FROM fee_assignments WHERE tenant_id=v_tenant AND student_id=v_s8 AND fee_type_id=v_ft_tuition AND month='2026-02-01';

    -- ── 13. Salary payments (legacy 2-line: Dr Salary Expense / Cr Cash)
    INSERT INTO salary_payments (tenant_id, employee_id, amount, date) VALUES
        (v_tenant, v_e1, 15000.00, '2026-01-31'), (v_tenant, v_e2, 12000.00, '2026-01-31'),
        (v_tenant, v_e3,  8000.00, '2026-01-31'), (v_tenant, v_e4, 18000.00, '2026-01-31'),
        (v_tenant, v_e1, 15000.00, '2026-02-28'), (v_tenant, v_e2, 12000.00, '2026-02-28'),
        (v_tenant, v_e3,  8000.00, '2026-02-28'), (v_tenant, v_e4, 18000.00, '2026-02-28');

    -- ── 14. Expenses (trigger: Dr <expense> / Cr Cash) ───────────
    INSERT INTO expenses (tenant_id, account_id, amount, date, description) VALUES
        (v_tenant, v_util,       5000.00, '2026-01-15', 'January electricity bill'),
        (v_tenant, v_boarding,  12000.00, '2026-01-20', 'January boarding food supplies'),
        (v_tenant, v_maint,      3000.00, '2026-02-05', 'Roof repair'),
        (v_tenant, v_stationery, 1500.00, '2026-02-10', 'Notebooks and pens for students'),
        (v_tenant, v_transport,  2000.00, '2026-03-01', 'Student transport for field trip'),
        (v_tenant, v_util,       4500.00, '2026-02-15', 'February electricity bill');

    -- ── 15. Income (trigger: Dr Cash / Cr <revenue>) ─────────────
    INSERT INTO income (tenant_id, account_id, amount, date, description) VALUES
        (v_tenant, v_donation, 20000.00, '2026-01-22', 'Eid donation from the community'),
        (v_tenant, v_zakat,    15000.00, '2026-02-18', 'Zakat collection');

    -- ── 16. Exam + per-subject setup (Hifz-1) ────────────────────
    INSERT INTO exams (tenant_id, academic_year_id, name, exam_type, grade_scale_id,
                       start_date, end_date, status, created_by_id)
    VALUES (v_tenant, v_ay2026, 'First Term 2026', 'first_term', v_scale,
            '2026-04-01', '2026-04-10', 'published', v_user)
    RETURNING id INTO v_exam;

    INSERT INTO exam_subjects (tenant_id, exam_id, class_id, subject_id, full_marks, pass_marks, exam_date) VALUES
        (v_tenant, v_exam, v_c3, v_quran,   100, 40, '2026-04-01'),
        (v_tenant, v_exam, v_c3, v_tajweed, 100, 33, '2026-04-03'),
        (v_tenant, v_exam, v_c3, v_arabic,  100, 33, '2026-04-05'),
        (v_tenant, v_exam, v_c3, v_fiqh,    100, 33, '2026-04-07');

    -- ── 17. Marks for every Hifz-1 student (grade auto-computed) ──
    FOR v_stu IN
        SELECT id FROM students
         WHERE tenant_id = v_tenant AND class_id = v_c3 AND is_deleted = FALSE ORDER BY id
    LOOP
        v_sub_off := 0;
        FOR v_es IN
            SELECT id FROM exam_subjects WHERE exam_id = v_exam AND class_id = v_c3 ORDER BY id
        LOOP
            v_score := 62 + ((v_stu.id * 13 + v_sub_off * 7) % 37);
            INSERT INTO marks (tenant_id, exam_subject_id, student_id, marks_obtained, is_absent, entered_by_id)
            VALUES (v_tenant, v_es.id, v_stu.id, v_score, FALSE, v_user)
            ON CONFLICT (student_id, exam_subject_id) DO NOTHING;
            v_sub_off := v_sub_off + 1;
        END LOOP;
    END LOOP;

    -- ── 18. Report cards + class positions ───────────────────────
    FOR v_stu IN
        SELECT id FROM students
         WHERE tenant_id = v_tenant AND class_id = v_c3 AND is_deleted = FALSE
    LOOP
        PERFORM generate_report_card(v_stu.id, v_exam);
    END LOOP;
    PERFORM compute_class_positions(v_exam, v_c3);

    -- ── 19. Attendance — two days for all students + staff ───────
    FOR v_stu IN
        SELECT id FROM students WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        INSERT INTO student_attendance (tenant_id, student_id, date, status, marked_by_id)
        VALUES (v_tenant, v_stu.id, '2026-04-01',
                CASE WHEN v_stu.id % 5 = 0 THEN 'absent'
                     WHEN v_stu.id % 7 = 0 THEN 'late' ELSE 'present' END, v_user)
        ON CONFLICT (student_id, date) DO NOTHING;
        INSERT INTO student_attendance (tenant_id, student_id, date, status, marked_by_id)
        VALUES (v_tenant, v_stu.id, '2026-04-02',
                CASE WHEN v_stu.id % 4 = 0 THEN 'absent' ELSE 'present' END, v_user)
        ON CONFLICT (student_id, date) DO NOTHING;
    END LOOP;

    FOR v_emp IN
        SELECT id FROM employees WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        INSERT INTO staff_attendance (tenant_id, employee_id, date, status, marked_by_id)
        VALUES (v_tenant, v_emp.id, '2026-04-01', 'present', v_user)
        ON CONFLICT (employee_id, date) DO NOTHING;
        INSERT INTO staff_attendance (tenant_id, employee_id, date, status, leave_type, marked_by_id)
        VALUES (v_tenant, v_emp.id, '2026-04-02',
                CASE WHEN v_emp.id % 3 = 0 THEN 'leave'  ELSE 'present' END,
                CASE WHEN v_emp.id % 3 = 0 THEN 'casual' ELSE NULL      END, v_user)
        ON CONFLICT (employee_id, date) DO NOTHING;
    END LOOP;

    -- ── 20. Draft payslips for March 2026 ────────────────────────
    FOR v_emp IN
        SELECT id FROM employees WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        PERFORM generate_payslip(v_emp.id, 2026::SMALLINT, 3::SMALLINT);
    END LOOP;

    -- ── 21. Salary advance (Dr Salary Advances / Cr Cash) ────────
    INSERT INTO salary_advances (tenant_id, employee_id, amount, advance_date, reason, cash_account_id, created_by_id)
    VALUES (v_tenant, v_e1, 5000.00, '2026-03-05', 'Advance against March salary', v_cash, v_user);

    -- ── 22. Fee discount (sibling waiver; Dr Fee Discount / Cr A/R)
    INSERT INTO fee_discounts (tenant_id, fee_assignment_id, amount, percent, reason, notes, approved_by_id, created_by_id)
        SELECT v_tenant, id, 500.00, 25.00, 'sibling', 'Sibling discount (demo)', v_user, v_user
        FROM fee_assignments
        WHERE tenant_id = v_tenant AND student_id = v_s6 AND fee_type_id = v_ft_tuition AND month = '2026-01-01';

    -- ── 23. Notifications (queued + one sent) ────────────────────
    INSERT INTO notifications (tenant_id, channel, template_key, recipient_type, recipient_id,
                               recipient_address, recipient_name, body, status, created_by_id)
    VALUES
        (v_tenant, 'sms', 'fee_reminder', 'guardian', v_s1, '01710000001', 'Ahmed Hossain',
         'Dear guardian, the monthly fee for Ahmed Hossain is due. Please pay at the madrasa office.', 'queued', v_user),
        (v_tenant, 'sms', 'fee_reminder', 'guardian', v_s2, '01710000002', 'Yusuf Rahman',
         'Dear guardian, the monthly fee for Yusuf Rahman is due. Please pay at the madrasa office.', 'queued', v_user);
    INSERT INTO notifications (tenant_id, channel, template_key, recipient_type, recipient_id,
                               recipient_address, recipient_name, body, status, provider, sent_at, created_by_id)
    VALUES
        (v_tenant, 'sms', 'receipt_issued', 'guardian', v_s3, '01710000003', 'Khadija Akter',
         'Payment received for Khadija Akter. Receipt PAY-2026-0004. Thank you.', 'sent', 'ssl_wireless',
         '2026-01-10 10:05:00', v_user);

    RAISE NOTICE '007 seed: demo data rebuilt for tenant % (login owner@jobeda.com / Owner@123).', v_tenant;
END $$;

-- ============================================================================
-- EXPECTED STUDENT DUE SUMMARY  (student_due_summary view, nets discounts)
-- ----------------------------------------------------------------------------
--   Ahmed   : fee 10000  paid 8000  due 2000   advance 0
--   Yusuf   : fee 10000  paid 4000  due 6000   advance 0
--   Khadija : fee  6000  paid 6000  due    0   advance 0
--   Ibrahim : fee 10500  paid 7500  due 3000   advance 0
--   Fatima  : fee  3500  paid 2000  due 1500   advance 0
--   Hamza   : fee  4000  discount 500 → net 3500  paid 0  due 3500
--   Aisha   : fee  3000  paid 1500  due 1500   advance 0
--   Omar    : fee  4000  paid 5000  due    0   advance 1000
--
-- ALSO SEEDED: 24 accounts, owner user, 4 salary structures, 8 salary payments,
--   6 expenses, 2 income, 1 exam + 4 subjects + marks → report cards (Hifz-1),
--   2 days attendance (students + staff), 4 draft payslips (2026-03),
--   1 salary advance, 1 fee discount, 3 notifications. Journals auto-posted.
-- ============================================================================
