# Multi-Tenant Architecture Plan

> **Goal:** Transform Jobeda from a single-madrasa system into a SaaS platform where multiple madrasas (tenants) share one database with complete data isolation.
>
> **Auth strategy:** Custom auth (bcrypt + PyJWT) — Supabase is used **only as a database**, not for authentication.

---

## Current State

- Single-tenant: all data belongs to one madrasa
- No tenant concept anywhere in the schema
- 15 tables, 3 views, 6 triggers — none tenant-aware
- Supabase client uses the publishable key — no RLS enforced
- Auth is a placeholder (`/me` returns a static message)
- Supabase is used only for database operations (`.table().select()`, `.insert()`, etc.)

---

## Architecture Decision: Shared Database + Application-Level Isolation

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Separate database per tenant** | Maximum isolation | Unmaintainable, Supabase doesn't support it | ❌ |
| **Schema per tenant** | Good isolation | Migration nightmare, connection pooling issues | ❌ |
| **Shared DB + RLS (Supabase Auth)** | Supabase-native | Locks us into Supabase Auth | ❌ |
| **Shared DB + tenant_id + App-level filtering** | Portable, no vendor lock-in, simple | Must be disciplined with queries | ✅ **Chosen** |

### How it works

```
User logs in → Our backend validates credentials → Issues our own JWT (contains tenant_id)
  → Every API request includes JWT in Authorization header
  → FastAPI dependency extracts tenant_id from JWT
  → Every query includes .eq("tenant_id", tenant_id)
  → User only sees their madrasa's data
```

### Why NOT Supabase RLS?

- RLS depends on `auth.jwt()` which requires Supabase Auth
- We want auth to be **platform-independent** (can switch from Supabase to any PostgreSQL)
- Application-level filtering is simpler to debug and test
- We use the **service_role key** (bypasses RLS) — RLS would have no effect anyway

---

## Schema Changes

### New Table: `tenants`

```sql
CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,                    -- "Jobeda Hafizia Madrasa"
    slug TEXT NOT NULL UNIQUE,             -- "jobeda" (URL-friendly)
    address TEXT,
    phone TEXT,
    email TEXT,
    logo_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP NULL
);
```

### Add `tenant_id` to ALL tenant-scoped tables

Every table that holds tenant-specific data gets a new column:

```sql
ALTER TABLE <table> ADD COLUMN tenant_id UUID NOT NULL REFERENCES tenants(id);
CREATE INDEX idx_<table>_tenant ON <table>(tenant_id);
```

**Tables requiring `tenant_id`:**

| Table | Notes |
|-------|-------|
| `accounts` | Chart of accounts is per-madrasa |
| `journal_entries` | Financial data per-madrasa |
| `journal_lines` | Inherited via journal_entries FK, but index for query performance |
| `students` | Core tenant data |
| `employees` | Core tenant data |
| `fee_types` | Fee structures differ per madrasa |
| `fee_assignments` | Student fees per-madrasa |
| `payments` | Payment records per-madrasa |
| `payment_allocations` | Linked to payments (inherits tenant scope) |
| `salary_payments` | Employee salaries per-madrasa |
| `expenses` | Expenses per-madrasa |
| `income` | Income per-madrasa |
| `academic_years` | Academic calendar per-madrasa |
| `classes` | Class structure per-madrasa |
| `sections` | Sections per-madrasa |

**Tables that do NOT need `tenant_id`:**
- None — all 15 data tables are tenant-scoped

---

## Tenant Isolation: Application-Level Enforcement

Since we're NOT using Supabase RLS, tenant isolation is enforced by the **FastAPI application layer**:

### Rule 1: Every SELECT must filter by tenant_id

```python
# BEFORE (single-tenant):
resp = supabase.table("students").select("*").eq("is_deleted", False).execute()

# AFTER (multi-tenant):
resp = (
    supabase.table("students")
    .select("*")
    .eq("tenant_id", user.tenant_id)   # ← ALWAYS
    .eq("is_deleted", False)
    .execute()
)
```

### Rule 2: Every INSERT must include tenant_id

```python
# BEFORE:
data = {"name": student.name, "class_id": student.class_id}

# AFTER:
data = {"name": student.name, "class_id": student.class_id, "tenant_id": user.tenant_id}
```

### Rule 3: Every UPDATE/DELETE must scope by tenant_id

```python
# BEFORE:
supabase.table("students").update(data).eq("id", student_id).execute()

# AFTER:
supabase.table("students").update(data).eq("id", student_id).eq("tenant_id", user.tenant_id).execute()
```

### Safety Net: Tenant-Scoped Query Helper

To prevent developers from forgetting `.eq("tenant_id", ...)`, create a helper:

```python
# helpers/tenant.py
def tenant_query(table: str, tenant_id: str):
    """Returns a Supabase query pre-scoped to the tenant."""
    return supabase.table(table).select("*").eq("tenant_id", tenant_id)

def tenant_insert(table: str, data: dict, tenant_id: str):
    """Inserts a row with tenant_id automatically injected."""
    data["tenant_id"] = tenant_id
    return supabase.table(table).insert(data).execute()
```

---

## Database Client Changes

### `database.py` — Use service_role key

```python
import os
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL: str = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY: str = os.environ.get("SUPABASE_SERVICE_KEY", "")

if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
    raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in .env")

# Use service_role key — bypasses RLS, full database access
# Auth is handled at the application layer, not by Supabase
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)
```

### `.env` update

```env
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGciOiJIUzI1NiIs...  # service_role key (from Supabase dashboard)
JWT_SECRET=your-secret-key-min-32-chars         # For our custom JWT signing
JWT_ALGORITHM=HS256
JWT_EXPIRY_HOURS=24
```

---

## Migration Strategy

### Phase 1: Schema Preparation

```
1. Create tenants table
2. Create a "default tenant" for existing data
3. Add tenant_id column to all tables (nullable initially)
4. Backfill existing rows with the default tenant ID
5. Set tenant_id to NOT NULL
6. Add foreign key constraints
7. Add indexes on all tenant_id columns
```

### Phase 2: View Updates

All 3 SQL views must include `tenant_id` for filtering:

#### `student_due_summary`
```sql
-- Add tenant_id column to the view output
-- Add s.tenant_id to WHERE/JOIN conditions are already safe
-- because we query the view with .eq("tenant_id", ...)
DROP VIEW IF EXISTS student_due_summary;
CREATE VIEW student_due_summary AS
SELECT
    s.id,
    s.name,
    s.class,
    s.tenant_id,           -- ADD THIS
    COALESCE(fees.total, 0) AS total_fee,
    ...
```

#### `fee_detail_summary`
- Add `s.tenant_id` (or `f.tenant_id`) to the view columns

#### `dashboard_summary`
- This single-row aggregate view **cannot** be filtered by tenant via `.eq()`
- **Must be replaced** with a parameterized function:
  ```sql
  CREATE OR REPLACE FUNCTION get_dashboard_summary(p_tenant_id UUID)
  RETURNS TABLE (...) AS $$ ... $$;
  ```
  Called via: `supabase.rpc("get_dashboard_summary", {"p_tenant_id": tenant_id})`

### Phase 3: Trigger Updates

All 6 triggers and 2 helper functions need tenant awareness:

#### `add_journal_line()` — Critical fix

```sql
-- BEFORE: looks up account by name (not unique across tenants!)
SELECT id INTO v_account_id FROM accounts WHERE name = p_account_name LIMIT 1;

-- AFTER: scoped by tenant
CREATE OR REPLACE FUNCTION add_journal_line(
    p_journal_id INT,
    p_account_name TEXT,
    p_debit NUMERIC,
    p_credit NUMERIC,
    p_tenant_id UUID            -- NEW PARAMETER
) RETURNS VOID AS $$
DECLARE
    v_account_id INT;
BEGIN
    SELECT id INTO v_account_id
    FROM accounts
    WHERE name = p_account_name
      AND tenant_id = p_tenant_id    -- TENANT SCOPED
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Account not found: % (tenant: %)', p_account_name, p_tenant_id;
    END IF;

    INSERT INTO journal_lines (journal_id, account_id, debit, credit)
    VALUES (p_journal_id, v_account_id, p_debit, p_credit);
END;
$$ LANGUAGE plpgsql;
```

#### `create_journal_entry()` — Add tenant_id

```sql
CREATE OR REPLACE FUNCTION create_journal_entry(
    p_date DATE,
    p_description TEXT,
    p_tenant_id UUID            -- NEW PARAMETER
) RETURNS INT AS $$
DECLARE
    v_journal_id INT;
BEGIN
    INSERT INTO journal_entries (date, description, tenant_id)
    VALUES (p_date, p_description, p_tenant_id)
    RETURNING id INTO v_journal_id;

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;
```

#### All 6 trigger functions — Pass `NEW.tenant_id`

Every trigger function must pass `NEW.tenant_id` to both `create_journal_entry()` and `add_journal_line()`. Example:

```sql
CREATE OR REPLACE FUNCTION trg_fee_assignment_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_journal_id INT;
BEGIN
    v_journal_id := create_journal_entry(
        NEW.month,
        'Fee assigned for student ' || NEW.student_id,
        NEW.tenant_id                                    -- PASS TENANT
    );

    PERFORM add_journal_line(v_journal_id, 'Accounts Receivable', NEW.amount, 0, NEW.tenant_id);
    PERFORM add_journal_line(v_journal_id, 'Tuition Fees', 0, NEW.amount, NEW.tenant_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Same pattern for: `trg_payment_allocation_journal`, `trg_payment_advance_journal`, `trg_expense_journal`, `trg_salary_journal`, `trg_income_journal`.

### Phase 4: Unique Constraint Update

```sql
-- BEFORE: unique per student per fee type per month (globally)
UNIQUE (student_id, fee_type_id, month)

-- No change needed — student_id is already tenant-scoped
-- But if we want to allow same student IDs across tenants (SERIAL), this is fine
```

### Phase 5: Seed Data

- Create a new migration that creates a default tenant
- Update seed data to include `tenant_id` on all inserts
- Or: create a new `seed_multi_tenant.sql` migration

---

## Application Layer Changes

### Every route handler — 3 changes per endpoint

```python
# 1. Accept auth dependency (provides tenant_id)
def list_students(user: CurrentUser = Depends(get_current_user)):

# 2. Filter by tenant_id on reads
    .eq("tenant_id", user.tenant_id)

# 3. Include tenant_id on writes
    data["tenant_id"] = user.tenant_id
```

### Tenant Onboarding Flow

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/auth/register` | ❌ | Create tenant + owner user |
| `GET` | `/tenants/me` | ✅ | Get current tenant info |
| `PUT` | `/tenants/me` | ✅ | Update tenant info (owner only) |

On tenant creation, auto-seed:
- Default chart of accounts (21 accounts)
- Default fee types (Tuition, Exam, Hostel)
- Default academic year (current year)
- Owner user account

---

## Impact Assessment

| Area | Files Affected | Severity |
|------|---------------|----------|
| Database schema | All 15 tables | 🔥 Critical |
| SQL views | 3 views (2 updated, 1 replaced with function) | 🔥 Critical |
| SQL triggers | 6 triggers + 2 helper functions | 🔥 Critical |
| Route handlers | All 12 route files | 🔥 Critical |
| Services | All 4 service files | 🔥 Critical |
| Models | All model files (add tenant_id) | 🟡 Medium |
| Database client | `database.py` → service_role key | 🟡 Medium |
| New files | `helpers/tenant.py`, `routes/tenants.py`, `models/tenant.py` | 🟢 New |
| Seed data | New migration | 🟡 Medium |

---

## Execution Order

> ⚠️ Multi-tenant must be implemented BEFORE multi-user and roles, because both depend on tenant_id being in place.

```
1. Create tenants table + default tenant
2. Add tenant_id to all tables (nullable, backfill, then NOT NULL)
3. Update helper functions (create_journal_entry, add_journal_line) for tenant_id
4. Update all 6 trigger functions to pass NEW.tenant_id
5. Update SQL views for tenant_id (dashboard → function)
6. Switch database.py to service_role key
7. Create helpers/tenant.py (tenant-scoped query helpers)
8. Update all routes to filter/inject tenant_id
9. Create tenant onboarding endpoints
10. Update seed data
11. Test: create 2 tenants, verify complete isolation
```

---

## Open Questions

> [!IMPORTANT]
> **Q1: Tenant slug usage** — Will the frontend use subdomain routing (`jobeda.app.com`) or path-based (`app.com/jobeda`)? The backend doesn't care — it uses JWT.

> [!WARNING]
> **Q2: Existing data** — Is the current database just development/seed data, or is there real production data that needs to be migrated? If production data exists, we need a zero-downtime migration strategy.

> [!IMPORTANT]
> **Q3: Tenant limits** — Should there be limits per tenant? (max students, max users, etc.) This affects the schema and would need a `tenant_plans` table.

> [!IMPORTANT]
> **Q4: Cross-tenant reporting** — Will there ever be a "super admin" who can see data across all tenants? (e.g., a central madrasa board). If yes, we need a separate admin role that bypasses tenant filtering.
