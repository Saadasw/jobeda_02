-- Migration 021: Link Employees to Users (for Teacher Self-Scope)
-- ================================================================
-- Implements plan_multi_role_permission.md Special Rule #1
-- (Teacher Self-Scope on salary) and answers Open Question Q1
-- (recommendation: yes — auto-link teachers to employee records).
--
-- WHY:
--   The teacher role gets `salary:read_own` — it can see only its
--   own salary history. The route filter is:
--       WHERE employees.user_id = current_user.user_id
--   Without `employees.user_id`, that filter is impossible.
--
-- PLAN VERIFICATION FINDINGS — ADDRESSED HERE:
--   * The plan textually says "Requires a user_id UUID REFERENCES
--     users(id) column on the employees table. Added in the
--     multi-user migration." But plan_multi_user.md NEVER adds
--     this column. It would have been silently missing.
--
-- ADDITIONAL UPGRADE:
--   * UNIQUE (user_id) so a single user cannot be linked to two
--     employee records (would double-count salary).
--   * tenant_id sanity: user.tenant_id must match employee.tenant_id.
--     Enforced via trigger.
-- ================================================================

ALTER TABLE employees
    ADD COLUMN IF NOT EXISTS user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL;

-- A user can be linked to at most one employee record.
CREATE UNIQUE INDEX IF NOT EXISTS uq_employees_user
    ON employees(user_id)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_employees_user ON employees(user_id);

-- Tenant-consistency guard: user.tenant_id MUST match employee.tenant_id.
CREATE OR REPLACE FUNCTION trg_employee_user_tenant_match()
RETURNS TRIGGER AS $$
DECLARE
    v_user_tenant UUID;
BEGIN
    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT tenant_id INTO v_user_tenant FROM users WHERE id = NEW.user_id;

    IF v_user_tenant IS NULL THEN
        RAISE EXCEPTION 'employees.user_id % does not exist in users', NEW.user_id;
    END IF;

    IF v_user_tenant <> NEW.tenant_id THEN
        RAISE EXCEPTION 'Cross-tenant link forbidden: employee tenant %, user % tenant %',
            NEW.tenant_id, NEW.user_id, v_user_tenant;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS employee_user_tenant_match ON employees;
CREATE TRIGGER employee_user_tenant_match
BEFORE INSERT OR UPDATE OF user_id, tenant_id ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_employee_user_tenant_match();
