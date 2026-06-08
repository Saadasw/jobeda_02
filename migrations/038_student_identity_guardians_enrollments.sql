-- Migration 038: Student identity, guardians, and per-year enrollments
-- ================================================================
-- WHY:
--   A flat student row can only hold the CURRENT class/section/roll, so
--   promotion overwrites history and old report cards/certificates would
--   reference the wrong year. We introduce the proper SIS shape:
--     * students            — PERMANENT identity (name, registration_no,
--                             admission_date, guardian, dob, ...)
--     * student_enrollments — one row PER ACADEMIC YEAR with the student's
--                             class/section/roll/status for that year
--     * guardians           — sibling-aware (one guardian -> many students)
--
-- STRATEGY (expand / contract — this is the EXPAND step):
--   * Create the new tables + permanent columns, BACKFILL from current data.
--   * Keep students.class_id/section_id/academic_year_id for now (every view
--     and function still reads them) and MIRROR them into student_enrollments
--     via a trigger, so nothing breaks today.
--   * A later migration will flip readers (views, generate_report_card, etc.)
--     to the enrollment table and retire the legacy columns (the CONTRACT step).
--
--   registration_no is generated via tenant_counters (kind='registration'),
--   self-healing exactly like generate_receipt_no (migration 037).
--
-- Idempotent: safe to re-run (IF NOT EXISTS / guarded constraints / ON CONFLICT).
-- ================================================================

-- ════════════════════════════════════════════════════════════════
-- 1. GUARDIANS  (one guardian -> many students; enables siblings)
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS guardians (
    id            SERIAL PRIMARY KEY,
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    phone         TEXT,                          -- fee-reminder SMS target
    relation      TEXT CHECK (relation IS NULL OR relation IN (
                      'father','mother','grandfather','grandmother',
                      'uncle','aunt','brother','sister','guardian','other'
                  )),
    email         TEXT,
    occupation    TEXT,
    address       TEXT,
    is_deleted    BOOLEAN DEFAULT FALSE,
    deleted_at    TIMESTAMP,
    created_at    TIMESTAMP DEFAULT NOW(),
    created_by_id UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_guardians_tenant ON guardians(tenant_id);
CREATE INDEX IF NOT EXISTS idx_guardians_phone  ON guardians(tenant_id, phone);

-- ════════════════════════════════════════════════════════════════
-- 2. STUDENTS: permanent identity columns
-- ════════════════════════════════════════════════════════════════
ALTER TABLE students ADD COLUMN IF NOT EXISTS registration_no TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS admission_date  DATE;
ALTER TABLE students ADD COLUMN IF NOT EXISTS date_of_birth   DATE;
ALTER TABLE students ADD COLUMN IF NOT EXISTS gender          TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS address         TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS guardian_id     INT;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_students_guardian') THEN
        ALTER TABLE students ADD CONSTRAINT fk_students_guardian
            FOREIGN KEY (guardian_id) REFERENCES guardians(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_students_gender') THEN
        ALTER TABLE students ADD CONSTRAINT chk_students_gender
            CHECK (gender IS NULL OR gender IN ('male','female','other'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_students_guardian ON students(guardian_id);

-- ════════════════════════════════════════════════════════════════
-- 3. STUDENT_ENROLLMENTS: per-year class/section/roll/status
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS student_enrollments (
    id               SERIAL PRIMARY KEY,
    tenant_id        UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    student_id       INT  NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    academic_year_id INT  NOT NULL REFERENCES academic_years(id),
    class_id         INT  NOT NULL REFERENCES classes(id),
    section_id       INT  REFERENCES sections(id),     -- nullable: class may have no sections
    roll_no          INT,                               -- nullable until assigned
    status           TEXT NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active','promoted','graduated','transferred','dropped','archived')),
    is_current       BOOLEAN NOT NULL DEFAULT TRUE,     -- the student's current-year enrollment
    enrolled_on      DATE DEFAULT CURRENT_DATE,
    created_at       TIMESTAMP DEFAULT NOW(),
    created_by_id    UUID REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_enrollment_student_year UNIQUE (student_id, academic_year_id)
);

CREATE INDEX IF NOT EXISTS idx_enrollments_tenant  ON student_enrollments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_student ON student_enrollments(student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_year_class
    ON student_enrollments(tenant_id, academic_year_id, class_id, section_id);

-- Roll is unique per (tenant, year, class, section). Partial: only when a roll
-- is assigned; COALESCE handles section-less classes.
CREATE UNIQUE INDEX IF NOT EXISTS uq_enrollment_roll
    ON student_enrollments(tenant_id, academic_year_id, class_id, COALESCE(section_id, 0), roll_no)
    WHERE roll_no IS NOT NULL;

-- Exactly one current enrollment per student.
CREATE UNIQUE INDEX IF NOT EXISTS uq_enrollment_one_current
    ON student_enrollments(student_id) WHERE is_current = TRUE;

-- ════════════════════════════════════════════════════════════════
-- 4. registration number generator (self-healing, via tenant_counters)
--    Format: {admission_year}-{NNNN}, e.g. 2026-0001.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION generate_registration_no(p_tenant_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_year         INT := EXTRACT(YEAR FROM NOW())::INT;
    v_max_existing INT;
    v_next         INT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'generate_registration_no: tenant_id must not be NULL';
    END IF;

    SELECT COALESCE(MAX(substring(registration_no FROM '\d+$')::INT), 0)
    INTO v_max_existing
    FROM students
    WHERE tenant_id = p_tenant_id
      AND registration_no LIKE v_year || '-%';

    INSERT INTO tenant_counters (tenant_id, kind, year, last_value, updated_at)
    VALUES (p_tenant_id, 'registration', v_year, GREATEST(1, v_max_existing + 1), NOW())
    ON CONFLICT (tenant_id, kind, year)
    DO UPDATE SET
        last_value = GREATEST(tenant_counters.last_value + 1, v_max_existing + 1),
        updated_at = NOW()
    RETURNING last_value INTO v_next;

    RETURN v_year || '-' || LPAD(v_next::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════
-- 5. BACKFILL existing data
-- ════════════════════════════════════════════════════════════════

-- 5a. registration_no for every student missing one (sequential per tenant+year)
WITH numbered AS (
    SELECT id,
           EXTRACT(YEAR FROM COALESCE(created_at, NOW()))::INT AS yr,
           ROW_NUMBER() OVER (
               PARTITION BY tenant_id, EXTRACT(YEAR FROM COALESCE(created_at, NOW()))
               ORDER BY id
           ) AS seq
    FROM students
    WHERE registration_no IS NULL
)
UPDATE students s
SET registration_no = n.yr || '-' || LPAD(n.seq::TEXT, 4, '0')
FROM numbered n
WHERE s.id = n.id;

-- 5b. Advance the registration counter so generate_registration_no continues
--     from the backfilled values.
INSERT INTO tenant_counters (tenant_id, kind, year, last_value, updated_at)
SELECT s.tenant_id, 'registration',
       EXTRACT(YEAR FROM COALESCE(s.created_at, NOW()))::INT,
       COUNT(*), NOW()
FROM students s
WHERE s.registration_no IS NOT NULL
GROUP BY s.tenant_id, EXTRACT(YEAR FROM COALESCE(s.created_at, NOW()))::INT
ON CONFLICT (tenant_id, kind, year)
DO UPDATE SET last_value = GREATEST(tenant_counters.last_value, EXCLUDED.last_value),
              updated_at = NOW();

-- 5c. admission_date defaults to when the row was created.
UPDATE students
SET admission_date = created_at::date
WHERE admission_date IS NULL AND created_at IS NOT NULL;

-- 5d. One enrollment row per existing student (from their current placement).
INSERT INTO student_enrollments
    (tenant_id, student_id, academic_year_id, class_id, section_id, status, is_current, enrolled_on)
SELECT s.tenant_id, s.id, s.academic_year_id, s.class_id, s.section_id,
       CASE WHEN COALESCE(s.is_deleted, FALSE) THEN 'archived' ELSE 'active' END,
       NOT COALESCE(s.is_deleted, FALSE),
       COALESCE(s.created_at::date, CURRENT_DATE)
FROM students s
WHERE s.academic_year_id IS NOT NULL
  AND s.class_id IS NOT NULL
ON CONFLICT (student_id, academic_year_id) DO NOTHING;

-- ════════════════════════════════════════════════════════════════
-- 6. Triggers that keep the new structures populated on student insert
--    (so the existing seed + create_student path need no changes yet).
-- ════════════════════════════════════════════════════════════════

-- 6a. Auto-assign registration_no when not supplied.
CREATE OR REPLACE FUNCTION trg_students_registration_no()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.registration_no IS NULL THEN
        NEW.registration_no := generate_registration_no(NEW.tenant_id);
    END IF;
    IF NEW.admission_date IS NULL THEN
        NEW.admission_date := CURRENT_DATE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS students_registration_no ON students;
CREATE TRIGGER students_registration_no
BEFORE INSERT ON students
FOR EACH ROW
EXECUTE FUNCTION trg_students_registration_no();

-- 6b. Mirror the student's current placement into student_enrollments.
--     (Expand phase: enrollment is derived from the legacy columns for now.)
CREATE OR REPLACE FUNCTION trg_students_default_enrollment()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.academic_year_id IS NOT NULL AND NEW.class_id IS NOT NULL THEN
        INSERT INTO student_enrollments
            (tenant_id, student_id, academic_year_id, class_id, section_id, status, is_current, enrolled_on)
        VALUES
            (NEW.tenant_id, NEW.id, NEW.academic_year_id, NEW.class_id, NEW.section_id,
             'active', TRUE, COALESCE(NEW.admission_date, CURRENT_DATE))
        ON CONFLICT (student_id, academic_year_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS students_default_enrollment ON students;
CREATE TRIGGER students_default_enrollment
AFTER INSERT ON students
FOR EACH ROW
EXECUTE FUNCTION trg_students_default_enrollment();

-- ════════════════════════════════════════════════════════════════
-- 7. Lock registration_no (every row now has one; trigger fills future rows)
-- ════════════════════════════════════════════════════════════════
ALTER TABLE students ALTER COLUMN registration_no SET NOT NULL;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_students_tenant_regno') THEN
        ALTER TABLE students ADD CONSTRAINT uq_students_tenant_regno
            UNIQUE (tenant_id, registration_no);
    END IF;
END $$;

COMMENT ON TABLE guardians IS
'Per-tenant guardians. One guardian -> many students (siblings share a guardian_id).';
COMMENT ON TABLE student_enrollments IS
'Per-academic-year placement (class/section/roll/status). Source of truth for a student''s year-by-year history. is_current flags the active year.';
COMMENT ON COLUMN students.registration_no IS
'Permanent admission number {year}-{NNNN}, unique per tenant. Auto-generated via generate_registration_no().';
