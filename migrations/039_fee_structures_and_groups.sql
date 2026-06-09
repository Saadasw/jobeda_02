-- ============================================================================
-- Migration 039: Fee groups, fee structures, fee-type frequency, fee audit
-- ============================================================================
-- PURPOSE
--   Move fee assignment from one-student-at-a-time to templated bulk billing.
--
--   * fee_groups          — a student's fee profile (Residential / Day / Free).
--                           Students in the SAME class can pay DIFFERENT fees.
--   * students.fee_group_id — the student's current group (mirror pattern, like
--                           class_id; may move to student_enrollments later).
--   * fee_structures      — a price list per (academic_year, class, fee_group).
--   * fee_structure_items — the lines of a price list (fee_type + amount +
--                           frequency + due_day).
--   * fee_types.frequency — replaces the coarse is_recurring flag (kept for now).
--   * fee_assignments.created_by_id — who ran the generation batch (audit).
--
-- DECISIONS (owner):
--   - Void handling = "deleted stays deleted": generation skips any existing
--     (tenant, student, fee_type, month). The existing constraint
--     uq_fee_per_tenant_student_type_month (migration 014, NOT partial on
--     is_deleted) is the backstop — left unchanged on purpose.
--   - Fee groups: YES (boarding / day / free).
--
-- IDEMPOTENT: safe to run more than once (IF NOT EXISTS + NOT EXISTS guards).
-- Apply in the Supabase SQL editor on project lltdojrxjdnwbwowqptb.
-- ============================================================================

-- ── 1. Fee groups ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fee_groups (
    id          SERIAL PRIMARY KEY,
    tenant_id   UUID    NOT NULL REFERENCES tenants(id),
    name        TEXT    NOT NULL,
    description TEXT,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);

-- One live group per name per tenant (a soft-deleted one can be replaced).
CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_group_name
    ON fee_groups (tenant_id, name) WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_fee_groups_tenant ON fee_groups (tenant_id);

-- ── 2. students.fee_group_id ─────────────────────────────────────────────────
ALTER TABLE students
    ADD COLUMN IF NOT EXISTS fee_group_id INT REFERENCES fee_groups(id);
CREATE INDEX IF NOT EXISTS idx_students_fee_group ON students (fee_group_id);

-- ── 3. Fee structures (one price list per year × class × group) ──────────────
CREATE TABLE IF NOT EXISTS fee_structures (
    id               SERIAL PRIMARY KEY,
    tenant_id        UUID    NOT NULL REFERENCES tenants(id),
    academic_year_id INT     NOT NULL REFERENCES academic_years(id),
    class_id         INT     NOT NULL REFERENCES classes(id),
    fee_group_id     INT     NOT NULL REFERENCES fee_groups(id),
    name             TEXT,
    is_deleted       BOOLEAN NOT NULL DEFAULT FALSE,
    created_by_id    UUID,
    created_at       TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_structure_year_class_group
    ON fee_structures (tenant_id, academic_year_id, class_id, fee_group_id)
    WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_fee_structures_tenant ON fee_structures (tenant_id);
CREATE INDEX IF NOT EXISTS idx_fee_structures_year_class
    ON fee_structures (academic_year_id, class_id);

-- ── 4. Fee structure items (the price-list lines) ────────────────────────────
CREATE TABLE IF NOT EXISTS fee_structure_items (
    id               SERIAL PRIMARY KEY,
    tenant_id        UUID    NOT NULL REFERENCES tenants(id),
    fee_structure_id INT     NOT NULL REFERENCES fee_structures(id) ON DELETE CASCADE,
    fee_type_id      INT     NOT NULL REFERENCES fee_types(id),
    amount           NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    frequency        TEXT    NOT NULL DEFAULT 'monthly'
                     CHECK (frequency IN ('monthly','termly','annual','one_time')),
    due_day          INT     CHECK (due_day BETWEEN 1 AND 28),
    is_deleted       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_structure_item
    ON fee_structure_items (fee_structure_id, fee_type_id) WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_fee_structure_items_struct
    ON fee_structure_items (fee_structure_id);

-- ── 5. fee_types.frequency (replaces is_recurring; is_recurring kept for now) ─
ALTER TABLE fee_types
    ADD COLUMN IF NOT EXISTS frequency TEXT NOT NULL DEFAULT 'monthly'
    CHECK (frequency IN ('monthly','termly','annual','one_time','adhoc'));

-- Backfill from the legacy flag: recurring -> monthly, otherwise one_time.
UPDATE fee_types
   SET frequency = CASE WHEN is_recurring THEN 'monthly' ELSE 'one_time' END
 WHERE frequency = 'monthly';   -- only rows still at the default (re-run safe)

-- ── 6. fee_assignments.created_by_id (audit: who generated the fee) ──────────
-- UUID because users.id is a UUID.
ALTER TABLE fee_assignments
    ADD COLUMN IF NOT EXISTS created_by_id UUID;

-- ── 7. Seed default groups per tenant + tag ungrouped students as "Day" ──────
DO $$
DECLARE
    t        RECORD;
    v_day_id INT;
BEGIN
    FOR t IN SELECT id FROM tenants LOOP
        INSERT INTO fee_groups (tenant_id, name, description)
        SELECT t.id, g.name, g.description
        FROM (VALUES
            ('Residential', 'Boarding students (e.g. tuition + hostel + meals)'),
            ('Day',         'Day scholars (e.g. tuition only)'),
            ('Free',        'Scholarship / orphan — fees waived')
        ) AS g(name, description)
        WHERE NOT EXISTS (
            SELECT 1 FROM fee_groups fg
            WHERE fg.tenant_id = t.id AND fg.name = g.name AND fg.is_deleted = FALSE
        );

        SELECT id INTO v_day_id FROM fee_groups
        WHERE tenant_id = t.id AND name = 'Day' AND is_deleted = FALSE
        LIMIT 1;

        IF v_day_id IS NOT NULL THEN
            UPDATE students
               SET fee_group_id = v_day_id
             WHERE tenant_id = t.id
               AND fee_group_id IS NULL
               AND is_deleted = FALSE;
        END IF;
    END LOOP;
END $$;

-- ── 8. Documentation ─────────────────────────────────────────────────────────
COMMENT ON TABLE  fee_groups          IS 'Student fee profile (Residential/Day/Free); price lists key on it.';
COMMENT ON TABLE  fee_structures      IS 'A price list for one (academic_year, class, fee_group).';
COMMENT ON TABLE  fee_structure_items IS 'A line of a price list: fee_type + amount + frequency + due_day.';
COMMENT ON COLUMN students.fee_group_id        IS 'Student current fee group; resolves which structure bills them.';
COMMENT ON COLUMN fee_types.frequency          IS 'monthly/termly/annual/one_time/adhoc; supersedes is_recurring.';
COMMENT ON COLUMN fee_assignments.created_by_id IS 'User who created/generated this fee (audit).';
