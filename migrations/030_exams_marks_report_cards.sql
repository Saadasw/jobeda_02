-- Migration 030: Exams, Subjects, Marks, Grade Scales, Report Cards
-- ================================================================
-- WHY:
--   The biggest functional gap for school owners. Up to 029 there's
--   no academic-result side at all.
--
-- DESIGN:
--   * subjects        — list of subjects per tenant (Quran, English…)
--   * class_subjects  — which classes teach which subjects
--   * grade_scales    — per-tenant grading bands (e.g. A+ = 80-100)
--   * exams           — exam header (name, type, academic_year)
--   * exam_subjects   — per-class-per-subject marks setup
--                       (full_marks, pass_marks, date, time, room)
--   * marks           — one row per (student, exam_subject)
--   * report_cards    — aggregate per (student, exam) with GPA + position
--
--   Grade lookup is done by trigger on marks insert/update so the
--   `grade` column is always consistent with percent and scale.
-- ================================================================

-- ════════════════════════════════════════════════════════════════
-- 1. SUBJECTS + class link
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS subjects (
    id           SERIAL PRIMARY KEY,
    tenant_id    UUID NOT NULL REFERENCES tenants(id),
    name         TEXT NOT NULL,
    code         TEXT,                  -- short code: 'QUR', 'ENG', 'BNG'
    description  TEXT,
    is_active    BOOLEAN DEFAULT TRUE,
    is_deleted   BOOLEAN DEFAULT FALSE,
    created_at   TIMESTAMP DEFAULT NOW(),
    CONSTRAINT uq_subjects_tenant_name UNIQUE (tenant_id, name)
);

CREATE INDEX IF NOT EXISTS idx_subjects_tenant ON subjects(tenant_id);

CREATE TABLE IF NOT EXISTS class_subjects (
    id           SERIAL PRIMARY KEY,
    tenant_id    UUID NOT NULL REFERENCES tenants(id),
    class_id     INT  NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    subject_id   INT  NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
    is_optional  BOOLEAN DEFAULT FALSE,
    created_at   TIMESTAMP DEFAULT NOW(),
    CONSTRAINT uq_class_subjects UNIQUE (class_id, subject_id)
);

CREATE INDEX IF NOT EXISTS idx_class_subjects_tenant  ON class_subjects(tenant_id);
CREATE INDEX IF NOT EXISTS idx_class_subjects_class   ON class_subjects(class_id);
CREATE INDEX IF NOT EXISTS idx_class_subjects_subject ON class_subjects(subject_id);

-- ════════════════════════════════════════════════════════════════
-- 2. GRADE SCALES
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS grade_scales (
    id           SERIAL PRIMARY KEY,
    tenant_id    UUID NOT NULL REFERENCES tenants(id),
    name         TEXT NOT NULL,
    is_default   BOOLEAN DEFAULT FALSE,
    is_active    BOOLEAN DEFAULT TRUE,
    created_at   TIMESTAMP DEFAULT NOW(),
    CONSTRAINT uq_grade_scales_tenant_name UNIQUE (tenant_id, name)
);

-- Only one default scale per tenant
CREATE UNIQUE INDEX IF NOT EXISTS uq_grade_scales_one_default_per_tenant
    ON grade_scales(tenant_id)
    WHERE is_default = TRUE;

CREATE TABLE IF NOT EXISTS grade_scale_bands (
    id              SERIAL PRIMARY KEY,
    grade_scale_id  INT  NOT NULL REFERENCES grade_scales(id) ON DELETE CASCADE,
    grade_name      TEXT NOT NULL,                   -- 'A+', 'A', 'B', 'F', or 'মুমতাজ' etc.
    min_percent     NUMERIC(5,2) NOT NULL CHECK (min_percent >= 0 AND min_percent <= 100),
    max_percent     NUMERIC(5,2) NOT NULL CHECK (max_percent >= 0 AND max_percent <= 100),
    grade_point     NUMERIC(4,2) NOT NULL CHECK (grade_point >= 0),
    is_pass         BOOLEAN NOT NULL DEFAULT TRUE,   -- FALSE only for the "F" band

    CONSTRAINT chk_band_min_le_max CHECK (min_percent <= max_percent),
    CONSTRAINT uq_band_per_scale_grade UNIQUE (grade_scale_id, grade_name)
);

CREATE INDEX IF NOT EXISTS idx_grade_scale_bands_lookup
    ON grade_scale_bands(grade_scale_id, min_percent, max_percent);

-- Helper: lookup grade for a given (scale_id, percent)
CREATE OR REPLACE FUNCTION lookup_grade(
    p_scale_id INT,
    p_percent  NUMERIC
) RETURNS TABLE(grade_name TEXT, grade_point NUMERIC, is_pass BOOLEAN)
LANGUAGE sql
STABLE
AS $$
    SELECT b.grade_name, b.grade_point, b.is_pass
    FROM grade_scale_bands b
    WHERE b.grade_scale_id = p_scale_id
      AND p_percent >= b.min_percent
      AND p_percent <= b.max_percent
    ORDER BY b.min_percent DESC
    LIMIT 1;
$$;

-- ════════════════════════════════════════════════════════════════
-- 3. EXAMS
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS exams (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    academic_year_id    INT  NOT NULL REFERENCES academic_years(id),
    name                TEXT NOT NULL,                   -- 'First Term 2026'
    exam_type           TEXT NOT NULL CHECK (exam_type IN (
                            'weekly', 'monthly', 'first_term', 'mid_term',
                            'second_term', 'final', 'pre_test', 'special'
                        )),
    grade_scale_id      INT  NULL REFERENCES grade_scales(id),
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    status              TEXT NOT NULL DEFAULT 'planned'
                          CHECK (status IN ('planned','scheduled','in_progress','completed','published','cancelled')),
    notes               TEXT,
    is_deleted          BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_exams_tenant_year_name UNIQUE (tenant_id, academic_year_id, name),
    CONSTRAINT chk_exams_date_range CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_exams_tenant  ON exams(tenant_id);
CREATE INDEX IF NOT EXISTS idx_exams_year    ON exams(academic_year_id);
CREATE INDEX IF NOT EXISTS idx_exams_status  ON exams(tenant_id, status);

-- ════════════════════════════════════════════════════════════════
-- 4. EXAM_SUBJECTS — per-exam per-class subject setup
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS exam_subjects (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    exam_id             INT  NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
    class_id            INT  NOT NULL REFERENCES classes(id),
    subject_id          INT  NOT NULL REFERENCES subjects(id),

    full_marks          NUMERIC(6,2) NOT NULL CHECK (full_marks > 0),
    pass_marks          NUMERIC(6,2) NOT NULL CHECK (pass_marks >= 0),
    weightage           NUMERIC(5,2) NOT NULL DEFAULT 100
                          CHECK (weightage > 0 AND weightage <= 100),

    exam_date           DATE NULL,
    exam_time           TIME NULL,
    duration_minutes    INT  NULL CHECK (duration_minutes IS NULL OR duration_minutes > 0),
    room                TEXT,

    created_at          TIMESTAMP DEFAULT NOW(),

    CONSTRAINT uq_exam_subjects UNIQUE (exam_id, class_id, subject_id),
    CONSTRAINT chk_pass_le_full CHECK (pass_marks <= full_marks)
);

CREATE INDEX IF NOT EXISTS idx_exam_subjects_tenant  ON exam_subjects(tenant_id);
CREATE INDEX IF NOT EXISTS idx_exam_subjects_exam    ON exam_subjects(exam_id);
CREATE INDEX IF NOT EXISTS idx_exam_subjects_class   ON exam_subjects(class_id, subject_id);

-- ════════════════════════════════════════════════════════════════
-- 5. MARKS — student's score for one exam_subject
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS marks (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    exam_subject_id     INT  NOT NULL REFERENCES exam_subjects(id) ON DELETE CASCADE,
    student_id          INT  NOT NULL REFERENCES students(id) ON DELETE CASCADE,

    marks_obtained      NUMERIC(6,2) NULL CHECK (marks_obtained IS NULL OR marks_obtained >= 0),
    is_absent           BOOLEAN NOT NULL DEFAULT FALSE,

    -- Snapshot computed from grade_scale at insert/update time
    percent             NUMERIC(5,2) NULL,
    grade               TEXT NULL,
    grade_point         NUMERIC(4,2) NULL,
    is_passed           BOOLEAN NULL,

    remarks             TEXT,

    entered_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    entered_at          TIMESTAMP DEFAULT NOW(),
    updated_at          TIMESTAMP NULL,
    updated_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_marks_student_exam_subject UNIQUE (student_id, exam_subject_id),
    CONSTRAINT chk_marks_absent_or_score
        CHECK ((is_absent = TRUE AND marks_obtained IS NULL)
            OR (is_absent = FALSE AND marks_obtained IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_marks_tenant    ON marks(tenant_id);
CREATE INDEX IF NOT EXISTS idx_marks_student   ON marks(student_id);
CREATE INDEX IF NOT EXISTS idx_marks_exam_sub  ON marks(exam_subject_id);

-- ────────────────────────────────────────────────────────────────
-- Trigger: validate scope + auto-compute percent / grade / is_passed
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_marks_compute_grade()
RETURNS TRIGGER AS $$
DECLARE
    es           exam_subjects%ROWTYPE;
    v_exam_yr    INT;
    v_scale      INT;
    g            RECORD;
BEGIN
    SELECT * INTO es FROM exam_subjects WHERE id = NEW.exam_subject_id;
    IF es.id IS NULL THEN
        RAISE EXCEPTION 'exam_subject % not found', NEW.exam_subject_id;
    END IF;

    IF es.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant marks forbidden: exam_subject tenant %, marks tenant %',
            es.tenant_id, NEW.tenant_id;
    END IF;

    -- Absent → null out score, percent, grade
    IF NEW.is_absent THEN
        NEW.marks_obtained := NULL;
        NEW.percent        := NULL;
        NEW.grade          := NULL;
        NEW.grade_point    := NULL;
        NEW.is_passed      := FALSE;
        RETURN NEW;
    END IF;

    IF NEW.marks_obtained > es.full_marks THEN
        RAISE EXCEPTION 'marks_obtained (%) exceeds full_marks (%) for exam_subject %',
            NEW.marks_obtained, es.full_marks, es.id;
    END IF;

    NEW.percent := ROUND((NEW.marks_obtained / es.full_marks * 100)::NUMERIC, 2);

    -- Grade scale precedence: exam.grade_scale_id → tenant default
    SELECT grade_scale_id INTO v_scale FROM exams WHERE id = es.exam_id;
    IF v_scale IS NULL THEN
        SELECT id INTO v_scale FROM grade_scales
         WHERE tenant_id = NEW.tenant_id AND is_default = TRUE AND is_active = TRUE
         LIMIT 1;
    END IF;

    IF v_scale IS NOT NULL THEN
        SELECT * INTO g FROM lookup_grade(v_scale, NEW.percent);
        IF FOUND THEN
            NEW.grade       := g.grade_name;
            NEW.grade_point := g.grade_point;
            NEW.is_passed   := g.is_pass AND NEW.marks_obtained >= es.pass_marks;
        ELSE
            NEW.is_passed   := NEW.marks_obtained >= es.pass_marks;
        END IF;
    ELSE
        NEW.is_passed := NEW.marks_obtained >= es.pass_marks;
    END IF;

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS marks_compute_grade ON marks;
CREATE TRIGGER marks_compute_grade
BEFORE INSERT OR UPDATE OF marks_obtained, is_absent, exam_subject_id ON marks
FOR EACH ROW
EXECUTE FUNCTION trg_marks_compute_grade();

-- ════════════════════════════════════════════════════════════════
-- 6. REPORT_CARDS — aggregated per student per exam
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS report_cards (
    id                  SERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id),
    exam_id             INT  NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
    student_id          INT  NOT NULL REFERENCES students(id) ON DELETE CASCADE,

    total_full_marks    NUMERIC(8,2) NOT NULL DEFAULT 0,
    total_obtained      NUMERIC(8,2) NOT NULL DEFAULT 0,
    percent             NUMERIC(5,2) NOT NULL DEFAULT 0,
    gpa                 NUMERIC(4,2) NOT NULL DEFAULT 0,
    overall_grade       TEXT,
    is_passed           BOOLEAN NOT NULL DEFAULT FALSE,
    subjects_failed     INT NOT NULL DEFAULT 0,
    subjects_absent     INT NOT NULL DEFAULT 0,

    position_in_class   INT NULL,
    position_in_section INT NULL,
    class_size          INT NULL,
    section_size        INT NULL,

    teacher_remarks     TEXT,
    principal_remarks   TEXT,

    status              TEXT NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft','finalized','published')),
    generated_at        TIMESTAMP DEFAULT NOW(),
    finalized_at        TIMESTAMP NULL,
    published_at        TIMESTAMP NULL,

    CONSTRAINT uq_report_card UNIQUE (exam_id, student_id)
);

CREATE INDEX IF NOT EXISTS idx_report_cards_tenant   ON report_cards(tenant_id);
CREATE INDEX IF NOT EXISTS idx_report_cards_student  ON report_cards(student_id);
CREATE INDEX IF NOT EXISTS idx_report_cards_exam     ON report_cards(exam_id);

-- ────────────────────────────────────────────────────────────────
-- 7. generate_report_card(student, exam) — compute from marks
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_report_card(
    p_student_id INT,
    p_exam_id    INT
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_tenant         UUID;
    v_total_full     NUMERIC(8,2) := 0;
    v_total_obt      NUMERIC(8,2) := 0;
    v_percent        NUMERIC(5,2) := 0;
    v_gpa            NUMERIC(6,2) := 0;
    v_subjects_count INT          := 0;
    v_failed         INT          := 0;
    v_absent         INT          := 0;
    v_passed_all     BOOLEAN;
    v_overall_grade  TEXT;
    v_scale          INT;
    v_report_id      INT;
    g                RECORD;
BEGIN
    SELECT tenant_id INTO v_tenant FROM students WHERE id = p_student_id;
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'student % not found', p_student_id;
    END IF;

    SELECT
        COALESCE(SUM(es.full_marks), 0),
        COALESCE(SUM(COALESCE(m.marks_obtained, 0)), 0),
        COUNT(*) FILTER (WHERE m.id IS NOT NULL),
        COUNT(*) FILTER (WHERE m.id IS NOT NULL AND m.is_passed = FALSE AND m.is_absent = FALSE),
        COUNT(*) FILTER (WHERE m.id IS NOT NULL AND m.is_absent = TRUE),
        COALESCE(SUM(m.grade_point), 0)
    INTO v_total_full, v_total_obt, v_subjects_count, v_failed, v_absent, v_gpa
    FROM exam_subjects es
    LEFT JOIN marks m
        ON m.exam_subject_id = es.id AND m.student_id = p_student_id
    WHERE es.exam_id = p_exam_id
      AND es.class_id = (SELECT class_id FROM students WHERE id = p_student_id);

    IF v_total_full > 0 THEN
        v_percent := ROUND((v_total_obt / v_total_full * 100)::NUMERIC, 2);
    END IF;

    IF v_subjects_count > 0 THEN
        v_gpa := ROUND((v_gpa / v_subjects_count)::NUMERIC, 2);
    END IF;

    v_passed_all := (v_failed = 0 AND v_absent = 0 AND v_subjects_count > 0);

    SELECT grade_scale_id INTO v_scale FROM exams WHERE id = p_exam_id;
    IF v_scale IS NULL THEN
        SELECT id INTO v_scale FROM grade_scales
         WHERE tenant_id = v_tenant AND is_default = TRUE AND is_active = TRUE
         LIMIT 1;
    END IF;
    IF v_scale IS NOT NULL THEN
        SELECT * INTO g FROM lookup_grade(v_scale, v_percent);
        IF FOUND THEN v_overall_grade := g.grade_name; END IF;
    END IF;

    INSERT INTO report_cards (
        tenant_id, exam_id, student_id,
        total_full_marks, total_obtained, percent, gpa, overall_grade,
        is_passed, subjects_failed, subjects_absent
    )
    VALUES (
        v_tenant, p_exam_id, p_student_id,
        v_total_full, v_total_obt, v_percent, v_gpa, v_overall_grade,
        v_passed_all, v_failed, v_absent
    )
    ON CONFLICT (exam_id, student_id) DO UPDATE SET
        total_full_marks = EXCLUDED.total_full_marks,
        total_obtained   = EXCLUDED.total_obtained,
        percent          = EXCLUDED.percent,
        gpa              = EXCLUDED.gpa,
        overall_grade    = EXCLUDED.overall_grade,
        is_passed        = EXCLUDED.is_passed,
        subjects_failed  = EXCLUDED.subjects_failed,
        subjects_absent  = EXCLUDED.subjects_absent,
        generated_at     = NOW()
    WHERE report_cards.status = 'draft'
    RETURNING id INTO v_report_id;

    RETURN v_report_id;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- 8. compute_class_positions(exam, class) — assign ranks
--    Call after all report cards for a class are generated.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION compute_class_positions(
    p_exam_id  INT,
    p_class_id INT
) RETURNS VOID
LANGUAGE sql
AS $$
    WITH ranked AS (
        SELECT
            rc.id,
            RANK() OVER (ORDER BY rc.total_obtained DESC, rc.percent DESC) AS pos_class,
            RANK() OVER (PARTITION BY s.section_id ORDER BY rc.total_obtained DESC, rc.percent DESC) AS pos_section,
            COUNT(*) OVER ()                                AS class_n,
            COUNT(*) OVER (PARTITION BY s.section_id)       AS section_n
        FROM report_cards rc
        JOIN students s ON s.id = rc.student_id
        WHERE rc.exam_id = p_exam_id
          AND s.class_id = p_class_id
          AND rc.is_passed = TRUE
    )
    UPDATE report_cards rc
    SET position_in_class   = ranked.pos_class,
        position_in_section = ranked.pos_section,
        class_size          = ranked.class_n,
        section_size        = ranked.section_n
    FROM ranked
    WHERE rc.id = ranked.id;
$$;

-- ════════════════════════════════════════════════════════════════
-- 9. SEED: default grade scale per tenant (madrasa-style + secular)
--    The owner can edit/disable; this just gives a working default.
-- ════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_tenant   UUID;
    v_scale_id INT;
BEGIN
    FOR v_tenant IN SELECT id FROM tenants LOOP
        INSERT INTO grade_scales (tenant_id, name, is_default)
        VALUES (v_tenant, 'Standard 100-point', TRUE)
        ON CONFLICT (tenant_id, name) DO NOTHING
        RETURNING id INTO v_scale_id;

        IF v_scale_id IS NULL THEN
            SELECT id INTO v_scale_id FROM grade_scales
             WHERE tenant_id = v_tenant AND name = 'Standard 100-point';
        END IF;

        INSERT INTO grade_scale_bands (grade_scale_id, grade_name, min_percent, max_percent, grade_point, is_pass)
        VALUES
            (v_scale_id, 'A+', 80.00, 100.00, 5.00, TRUE),
            (v_scale_id, 'A',  70.00, 79.99,  4.00, TRUE),
            (v_scale_id, 'A-', 60.00, 69.99,  3.50, TRUE),
            (v_scale_id, 'B',  50.00, 59.99,  3.00, TRUE),
            (v_scale_id, 'C',  40.00, 49.99,  2.00, TRUE),
            (v_scale_id, 'D',  33.00, 39.99,  1.00, TRUE),
            (v_scale_id, 'F',   0.00, 32.99,  0.00, FALSE)
        ON CONFLICT (grade_scale_id, grade_name) DO NOTHING;
    END LOOP;
END $$;

COMMENT ON TABLE subjects       IS 'List of subjects per tenant. Joined to classes via class_subjects.';
COMMENT ON TABLE exams          IS 'Exam header — name, type, dates, status.';
COMMENT ON TABLE exam_subjects  IS 'Per-exam per-class subject row: full_marks, pass_marks, date, room.';
COMMENT ON TABLE marks          IS 'One row per (student, exam_subject). Grade auto-computed by trigger.';
COMMENT ON TABLE report_cards   IS 'Aggregate per (student, exam). Use generate_report_card() to populate.';
