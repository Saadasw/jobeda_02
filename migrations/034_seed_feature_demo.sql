-- Migration 034: Final Demo Seed for the New Feature Tables (027–033)
-- ================================================================
-- WHY:
--   007_seed_data.sql predates multi-tenancy and every feature added
--   in migrations 027–033 (discounts, payroll, exams, attendance,
--   notifications). After all migrations run, those new tables are
--   empty, so the new APIs return nothing to demo against.
--
--   This migration EXTENDS the 007 demo dataset for the default
--   'jobeda' tenant with:
--     * Subjects + class-subject links (Hifz-1)
--     * An exam ("First Term 2026") with per-subject setup
--     * Marks for every Hifz-1 student → report cards + class positions
--     * Student & staff attendance for two days
--     * Draft payslips for March 2026 (structures already backfilled by 029)
--     * One salary advance (posts Dr Salary Advances / Cr Cash)
--     * A few queued notifications
--
-- DESIGN:
--   * Runs AFTER 033 — every referenced table/function/account exists.
--   * Scoped to the 'jobeda' tenant resolved at runtime (no hardcoded UUID).
--   * Entirely additive + idempotent (ON CONFLICT / NOT EXISTS guards),
--     so it is safe to re-run.
--   * Touches NO column that requires a NOT NULL users FK (there is no
--     seeded user), which is why fee_discounts is intentionally omitted —
--     its approved_by_id is NOT NULL. Use the API (authenticated) to
--     record discounts.
--   * Skips gracefully if the tenant or the 007 demo students are absent.
-- ================================================================

DO $$
DECLARE
    v_tenant    UUID;
    v_year      INT;          -- current academic year id
    v_class     INT;          -- Hifz-1 class id
    v_exam      INT;
    v_scale     INT;          -- default grade scale id
    v_cash      INT;          -- 'Cash' account id
    v_quran     INT;
    v_tajweed   INT;
    v_arabic    INT;
    v_fiqh      INT;
    v_adv_emp   INT;
    v_sub_off   INT;
    v_score     NUMERIC;
    v_stu       RECORD;
    v_emp       RECORD;
    v_es        RECORD;
BEGIN
    SELECT id INTO v_tenant FROM tenants WHERE slug = 'jobeda' LIMIT 1;
    IF v_tenant IS NULL THEN
        RAISE NOTICE '034 seed: default tenant "jobeda" not found — skipping.';
        RETURN;
    END IF;

    -- Nothing to attach demo academics/attendance to without the 007 students.
    IF NOT EXISTS (SELECT 1 FROM students WHERE tenant_id = v_tenant AND is_deleted = FALSE) THEN
        RAISE NOTICE '034 seed: no demo students for tenant — skipping.';
        RETURN;
    END IF;

    SELECT id INTO v_year FROM academic_years
     WHERE tenant_id = v_tenant AND is_current = TRUE
     ORDER BY id DESC LIMIT 1;
    IF v_year IS NULL THEN
        SELECT id INTO v_year FROM academic_years
         WHERE tenant_id = v_tenant ORDER BY id DESC LIMIT 1;
    END IF;

    SELECT id INTO v_class FROM classes
     WHERE tenant_id = v_tenant AND name = 'Hifz-1' LIMIT 1;

    SELECT id INTO v_scale FROM grade_scales
     WHERE tenant_id = v_tenant AND is_default = TRUE AND is_active = TRUE LIMIT 1;

    SELECT id INTO v_cash FROM accounts
     WHERE tenant_id = v_tenant AND name = 'Cash' LIMIT 1;

    -- ───────────────────────────────────────────────────────────────
    -- 1. SUBJECTS  (uq_subjects_tenant_name)
    -- ───────────────────────────────────────────────────────────────
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

    -- ───────────────────────────────────────────────────────────────
    -- 2. CLASS-SUBJECTS for Hifz-1
    -- ───────────────────────────────────────────────────────────────
    IF v_class IS NOT NULL THEN
        INSERT INTO class_subjects (tenant_id, class_id, subject_id) VALUES
            (v_tenant, v_class, v_quran),
            (v_tenant, v_class, v_tajweed),
            (v_tenant, v_class, v_arabic),
            (v_tenant, v_class, v_fiqh)
        ON CONFLICT (class_id, subject_id) DO NOTHING;
    END IF;

    -- ───────────────────────────────────────────────────────────────
    -- 3. EXAM (First Term 2026) + per-subject setup for Hifz-1
    -- ───────────────────────────────────────────────────────────────
    INSERT INTO exams (tenant_id, academic_year_id, name, exam_type, grade_scale_id,
                       start_date, end_date, status)
    VALUES (v_tenant, v_year, 'First Term 2026', 'first_term', v_scale,
            '2026-04-01', '2026-04-10', 'published')
    ON CONFLICT (tenant_id, academic_year_id, name) DO NOTHING;

    SELECT id INTO v_exam FROM exams
     WHERE tenant_id = v_tenant AND academic_year_id = v_year AND name = 'First Term 2026';

    IF v_class IS NOT NULL AND v_exam IS NOT NULL THEN
        INSERT INTO exam_subjects (tenant_id, exam_id, class_id, subject_id,
                                   full_marks, pass_marks, exam_date) VALUES
            (v_tenant, v_exam, v_class, v_quran,   100, 40, '2026-04-01'),
            (v_tenant, v_exam, v_class, v_tajweed, 100, 33, '2026-04-03'),
            (v_tenant, v_exam, v_class, v_arabic,  100, 33, '2026-04-05'),
            (v_tenant, v_exam, v_class, v_fiqh,    100, 33, '2026-04-07')
        ON CONFLICT (exam_id, class_id, subject_id) DO NOTHING;

        -- ── 4. MARKS: every Hifz-1 student × each exam subject ──
        --    Deterministic but varied scores (62–98); the marks trigger
        --    computes percent/grade/is_passed from the grade scale.
        FOR v_stu IN
            SELECT id FROM students
             WHERE tenant_id = v_tenant AND class_id = v_class AND is_deleted = FALSE
             ORDER BY id
        LOOP
            v_sub_off := 0;
            FOR v_es IN
                SELECT id FROM exam_subjects
                 WHERE exam_id = v_exam AND class_id = v_class
                 ORDER BY id
            LOOP
                v_score := 62 + ((v_stu.id * 13 + v_sub_off * 7) % 37);
                INSERT INTO marks (tenant_id, exam_subject_id, student_id, marks_obtained, is_absent)
                VALUES (v_tenant, v_es.id, v_stu.id, v_score, FALSE)
                ON CONFLICT (student_id, exam_subject_id) DO NOTHING;
                v_sub_off := v_sub_off + 1;
            END LOOP;
        END LOOP;

        -- ── 5. REPORT CARDS + class positions ──
        FOR v_stu IN
            SELECT id FROM students
             WHERE tenant_id = v_tenant AND class_id = v_class AND is_deleted = FALSE
        LOOP
            PERFORM generate_report_card(v_stu.id, v_exam);
        END LOOP;
        PERFORM compute_class_positions(v_exam, v_class);
    END IF;

    -- ───────────────────────────────────────────────────────────────
    -- 6. ATTENDANCE — two days for all demo students + staff
    -- ───────────────────────────────────────────────────────────────
    FOR v_stu IN
        SELECT id FROM students WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        INSERT INTO student_attendance (tenant_id, student_id, date, status)
        VALUES (v_tenant, v_stu.id, '2026-04-01',
                CASE WHEN v_stu.id % 5 = 0 THEN 'absent'
                     WHEN v_stu.id % 7 = 0 THEN 'late'
                     ELSE 'present' END)
        ON CONFLICT (student_id, date) DO NOTHING;

        INSERT INTO student_attendance (tenant_id, student_id, date, status)
        VALUES (v_tenant, v_stu.id, '2026-04-02',
                CASE WHEN v_stu.id % 4 = 0 THEN 'absent' ELSE 'present' END)
        ON CONFLICT (student_id, date) DO NOTHING;
    END LOOP;

    FOR v_emp IN
        SELECT id FROM employees WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        INSERT INTO staff_attendance (tenant_id, employee_id, date, status)
        VALUES (v_tenant, v_emp.id, '2026-04-01', 'present')
        ON CONFLICT (employee_id, date) DO NOTHING;

        INSERT INTO staff_attendance (tenant_id, employee_id, date, status, leave_type)
        VALUES (v_tenant, v_emp.id, '2026-04-02',
                CASE WHEN v_emp.id % 3 = 0 THEN 'leave'   ELSE 'present' END,
                CASE WHEN v_emp.id % 3 = 0 THEN 'casual'  ELSE NULL      END)
        ON CONFLICT (employee_id, date) DO NOTHING;
    END LOOP;

    -- ───────────────────────────────────────────────────────────────
    -- 7. DRAFT PAYSLIPS for March 2026
    --    (each employee already has an active salary_structure from the
    --     migration-029 backfill; generate_payslip is idempotent.)
    -- ───────────────────────────────────────────────────────────────
    FOR v_emp IN
        SELECT id FROM employees WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id
    LOOP
        BEGIN
            PERFORM generate_payslip(v_emp.id, 2026::SMALLINT, 3::SMALLINT);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '034 seed: payslip skipped for employee % (%).', v_emp.id, SQLERRM;
        END;
    END LOOP;

    -- ───────────────────────────────────────────────────────────────
    -- 8. SALARY ADVANCE (one; posts Dr Salary Advances / Cr Cash)
    -- ───────────────────────────────────────────────────────────────
    IF v_cash IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM salary_advances WHERE tenant_id = v_tenant) THEN
        SELECT id INTO v_adv_emp FROM employees
         WHERE tenant_id = v_tenant AND is_deleted = FALSE ORDER BY id LIMIT 1;
        IF v_adv_emp IS NOT NULL THEN
            INSERT INTO salary_advances (tenant_id, employee_id, amount, advance_date, reason, cash_account_id)
            VALUES (v_tenant, v_adv_emp, 5000.00, '2026-03-05', 'Advance against March salary', v_cash);
        END IF;
    END IF;

    -- ───────────────────────────────────────────────────────────────
    -- 9. NOTIFICATIONS — a few queued fee reminders (seed once)
    -- ───────────────────────────────────────────────────────────────
    IF NOT EXISTS (SELECT 1 FROM notifications WHERE tenant_id = v_tenant) THEN
        INSERT INTO notifications (tenant_id, channel, template_key, recipient_type,
                                   recipient_id, recipient_address, recipient_name, body, status)
        SELECT v_tenant, 'sms', 'fee_reminder', 'guardian',
               s.id, '0171' || LPAD(s.id::TEXT, 7, '0'), s.name,
               'Dear guardian, the monthly fee for ' || s.name
                   || ' is due. Please pay at the madrasa office. Thank you.',
               'queued'
        FROM students s
        WHERE s.tenant_id = v_tenant AND s.is_deleted = FALSE
        ORDER BY s.id
        LIMIT 3;
    END IF;

    RAISE NOTICE '034 seed: feature demo data complete for tenant %.', v_tenant;
END $$;

-- ============================================================================
-- EXPECTED STATE AFTER THIS SEED (jobeda tenant)
-- ============================================================================
--  subjects ............. 4   (Quran Memorization, Tajweed, Arabic, Fiqh)
--  class_subjects ....... 4   (all four linked to Hifz-1)
--  exams ................ 1   ("First Term 2026", published)
--  exam_subjects ........ 4   (Hifz-1 × 4 subjects, full=100)
--  marks ................ 4 × (#Hifz-1 students)   — all passing, graded
--  report_cards ......... one per Hifz-1 student, with class/section positions
--  student_attendance ... 2 days × all demo students
--  staff_attendance ..... 2 days × all employees (one casual leave)
--  payslips ............. 1 draft per employee for 2026-03
--  salary_advances ...... 1 (Dr Salary Advances / Cr Cash auto-posted)
--  notifications ........ 3 queued SMS fee reminders
-- ============================================================================
