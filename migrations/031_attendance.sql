-- Migration 031: Student + Staff Attendance
-- ================================================================
-- WHY:
--   Required for almost every school: who came today, who was absent,
--   how many days each teacher worked this month (feeds into payslip
--   absence_deduction).
--
-- DESIGN:
--   * student_attendance — one row per (student, date). Compact.
--   * staff_attendance   — one row per (employee, date). Same shape.
--   * Statuses are constrained TEXTs (not enum types) so future
--     statuses can be added without ALTER TYPE.
--   * Monthly summary FUNCTIONS rather than views — easier to filter
--     by year+month from the API.
--   * apply_staff_attendance_to_payslip(payslip_id) — convenience
--     helper that fills payslip.days_absent + absence_deduction
--     based on the month's attendance and the active salary_structure.
-- ================================================================

-- ════════════════════════════════════════════════════════════════
-- 1. STUDENT ATTENDANCE
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS student_attendance (
    id              SERIAL PRIMARY KEY,
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    student_id      INT  NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    date            DATE NOT NULL,
    status          TEXT NOT NULL CHECK (status IN (
                        'present','absent','late','leave','holiday','half_day'
                    )),
    check_in_time   TIME NULL,
    check_out_time  TIME NULL,
    remarks         TEXT,

    marked_by_id    UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    marked_at       TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP NULL,
    updated_by_id   UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_student_attendance UNIQUE (student_id, date)
);

CREATE INDEX IF NOT EXISTS idx_student_attendance_tenant_date
    ON student_attendance(tenant_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_student_attendance_student_date
    ON student_attendance(student_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_student_attendance_status
    ON student_attendance(tenant_id, date, status);

-- Tenant consistency: student.tenant_id must match attendance.tenant_id
CREATE OR REPLACE FUNCTION trg_student_attendance_tenant_match()
RETURNS TRIGGER AS $$
DECLARE
    v_student_tenant UUID;
BEGIN
    SELECT tenant_id INTO v_student_tenant FROM students WHERE id = NEW.student_id;
    IF v_student_tenant IS NULL THEN
        RAISE EXCEPTION 'student % not found', NEW.student_id;
    END IF;
    IF v_student_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant attendance forbidden: student tenant %, attendance tenant %',
            v_student_tenant, NEW.tenant_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS student_attendance_tenant_match ON student_attendance;
CREATE TRIGGER student_attendance_tenant_match
BEFORE INSERT OR UPDATE OF student_id, tenant_id ON student_attendance
FOR EACH ROW
EXECUTE FUNCTION trg_student_attendance_tenant_match();

-- ════════════════════════════════════════════════════════════════
-- 2. STAFF ATTENDANCE
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS staff_attendance (
    id              SERIAL PRIMARY KEY,
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    employee_id     INT  NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    date            DATE NOT NULL,
    status          TEXT NOT NULL CHECK (status IN (
                        'present','absent','late','leave','holiday','half_day','on_duty'
                    )),
    leave_type      TEXT NULL CHECK (leave_type IS NULL OR leave_type IN (
                        'casual','sick','annual','unpaid','maternity','hajj','other'
                    )),
    check_in_time   TIME NULL,
    check_out_time  TIME NULL,
    remarks         TEXT,

    marked_by_id    UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    marked_at       TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP NULL,
    updated_by_id   UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_staff_attendance UNIQUE (employee_id, date)
);

CREATE INDEX IF NOT EXISTS idx_staff_attendance_tenant_date
    ON staff_attendance(tenant_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_staff_attendance_employee_date
    ON staff_attendance(employee_id, date DESC);

CREATE OR REPLACE FUNCTION trg_staff_attendance_tenant_match()
RETURNS TRIGGER AS $$
DECLARE
    v_emp_tenant UUID;
BEGIN
    SELECT tenant_id INTO v_emp_tenant FROM employees WHERE id = NEW.employee_id;
    IF v_emp_tenant IS NULL THEN
        RAISE EXCEPTION 'employee % not found', NEW.employee_id;
    END IF;
    IF v_emp_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant attendance forbidden: employee tenant %, attendance tenant %',
            v_emp_tenant, NEW.tenant_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS staff_attendance_tenant_match ON staff_attendance;
CREATE TRIGGER staff_attendance_tenant_match
BEFORE INSERT OR UPDATE OF employee_id, tenant_id ON staff_attendance
FOR EACH ROW
EXECUTE FUNCTION trg_staff_attendance_tenant_match();

-- ════════════════════════════════════════════════════════════════
-- 3. MONTHLY SUMMARY FUNCTIONS
-- ════════════════════════════════════════════════════════════════

-- Per-student per-month: counts and percentage
CREATE OR REPLACE FUNCTION get_student_attendance_summary(
    p_tenant_id UUID,
    p_year      SMALLINT,
    p_month     SMALLINT,
    p_class_id  INT DEFAULT NULL,
    p_section_id INT DEFAULT NULL
) RETURNS TABLE (
    student_id    INT,
    student_name  TEXT,
    class_id      INT,
    section_id    INT,
    present_days  BIGINT,
    absent_days   BIGINT,
    late_days     BIGINT,
    leave_days    BIGINT,
    holiday_days  BIGINT,
    half_days     BIGINT,
    total_marked  BIGINT,
    attendance_pct NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        s.id          AS student_id,
        s.name        AS student_name,
        s.class_id,
        s.section_id,
        COUNT(*) FILTER (WHERE a.status = 'present')   AS present_days,
        COUNT(*) FILTER (WHERE a.status = 'absent')    AS absent_days,
        COUNT(*) FILTER (WHERE a.status = 'late')      AS late_days,
        COUNT(*) FILTER (WHERE a.status = 'leave')     AS leave_days,
        COUNT(*) FILTER (WHERE a.status = 'holiday')   AS holiday_days,
        COUNT(*) FILTER (WHERE a.status = 'half_day')  AS half_days,
        COUNT(*)                                       AS total_marked,
        CASE WHEN COUNT(*) FILTER (WHERE a.status <> 'holiday') > 0
             THEN ROUND(
                 100.0 *
                 (COUNT(*) FILTER (WHERE a.status IN ('present','late','half_day'))
                  + 0.5 * COUNT(*) FILTER (WHERE a.status = 'half_day')   -- half_day = 0.5 (added to the 1 above ⇒ 1.5; subtract 0.5 below)
                  - 0.5 * COUNT(*) FILTER (WHERE a.status = 'half_day')
                 )::NUMERIC
                 / COUNT(*) FILTER (WHERE a.status <> 'holiday')
             , 2)
             ELSE 0 END                                AS attendance_pct
    FROM students s
    LEFT JOIN student_attendance a
        ON a.student_id = s.id
       AND EXTRACT(YEAR  FROM a.date) = p_year
       AND EXTRACT(MONTH FROM a.date) = p_month
       AND a.tenant_id = p_tenant_id
    WHERE s.tenant_id  = p_tenant_id
      AND s.is_deleted = FALSE
      AND (p_class_id   IS NULL OR s.class_id   = p_class_id)
      AND (p_section_id IS NULL OR s.section_id = p_section_id)
    GROUP BY s.id, s.name, s.class_id, s.section_id
    ORDER BY s.name;
$$;

-- Per-staff per-month: counts and days that count for payroll
CREATE OR REPLACE FUNCTION get_staff_attendance_summary(
    p_tenant_id UUID,
    p_year      SMALLINT,
    p_month     SMALLINT
) RETURNS TABLE (
    employee_id   INT,
    employee_name TEXT,
    present_days  BIGINT,
    absent_days   BIGINT,
    leave_days    BIGINT,
    unpaid_leave  BIGINT,
    half_days     BIGINT,
    holiday_days  BIGINT,
    payable_days  NUMERIC      -- present + paid_leave + half_day*0.5 + holiday
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        e.id   AS employee_id,
        e.name AS employee_name,
        COUNT(*) FILTER (WHERE a.status = 'present')                                                AS present_days,
        COUNT(*) FILTER (WHERE a.status = 'absent')                                                 AS absent_days,
        COUNT(*) FILTER (WHERE a.status = 'leave')                                                  AS leave_days,
        COUNT(*) FILTER (WHERE a.status = 'leave' AND a.leave_type = 'unpaid')                      AS unpaid_leave,
        COUNT(*) FILTER (WHERE a.status = 'half_day')                                               AS half_days,
        COUNT(*) FILTER (WHERE a.status = 'holiday')                                                AS holiday_days,
        (
            COUNT(*) FILTER (WHERE a.status IN ('present','late','on_duty','holiday'))
            + COUNT(*) FILTER (WHERE a.status = 'leave' AND COALESCE(a.leave_type,'') <> 'unpaid')
            + 0.5 * COUNT(*) FILTER (WHERE a.status = 'half_day')
        )::NUMERIC                                                                                  AS payable_days
    FROM employees e
    LEFT JOIN staff_attendance a
        ON a.employee_id = e.id
       AND EXTRACT(YEAR  FROM a.date) = p_year
       AND EXTRACT(MONTH FROM a.date) = p_month
       AND a.tenant_id = p_tenant_id
    WHERE e.tenant_id  = p_tenant_id
      AND e.is_deleted = FALSE
    GROUP BY e.id, e.name
    ORDER BY e.name;
$$;

-- ════════════════════════════════════════════════════════════════
-- 4. apply_staff_attendance_to_payslip
--    Fills payslip.days_absent + absence_deduction from the month's
--    attendance, using the active salary_structure for the per-day
--    rate. Only operates on payslips in 'draft' status.
-- ════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION apply_staff_attendance_to_payslip(
    p_payslip_id INT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    p             payslips%ROWTYPE;
    v_present_eq  NUMERIC;
    v_days_in_mon INT;
    v_absent_eq   NUMERIC;
    v_per_day     NUMERIC;
    v_deduction   NUMERIC;
BEGIN
    SELECT * INTO p FROM payslips WHERE id = p_payslip_id;
    IF p.id IS NULL THEN
        RAISE EXCEPTION 'payslip % not found', p_payslip_id;
    END IF;
    IF p.status <> 'draft' THEN
        RAISE EXCEPTION 'payslip % is not in draft status (currently %)', p_payslip_id, p.status;
    END IF;

    -- payable days from attendance
    SELECT (
        COUNT(*) FILTER (WHERE a.status IN ('present','late','on_duty','holiday'))
        + COUNT(*) FILTER (WHERE a.status = 'leave' AND COALESCE(a.leave_type,'') <> 'unpaid')
        + 0.5 * COUNT(*) FILTER (WHERE a.status = 'half_day')
    )::NUMERIC INTO v_present_eq
    FROM staff_attendance a
    WHERE a.employee_id = p.employee_id
      AND EXTRACT(YEAR  FROM a.date) = p.year
      AND EXTRACT(MONTH FROM a.date) = p.month;

    v_days_in_mon := EXTRACT(DAY FROM
        (DATE_TRUNC('month', MAKE_DATE(p.year, p.month, 1))
         + INTERVAL '1 month - 1 day')::DATE
    )::INT;

    v_absent_eq := v_days_in_mon - COALESCE(v_present_eq, 0);
    IF v_absent_eq < 0 THEN v_absent_eq := 0; END IF;

    v_per_day := p.gross / NULLIF(v_days_in_mon, 0);
    v_deduction := ROUND((v_absent_eq * COALESCE(v_per_day, 0))::NUMERIC, 2);

    UPDATE payslips
    SET days_absent       = v_absent_eq,
        absence_deduction = v_deduction
    WHERE id = p_payslip_id;
END;
$$;

COMMENT ON TABLE student_attendance IS
'Daily attendance per student. UNIQUE(student_id, date).';
COMMENT ON TABLE staff_attendance IS
'Daily attendance per employee. Feeds into payslip absence_deduction.';
