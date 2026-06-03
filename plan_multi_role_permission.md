# Multi-Role Permission Architecture Plan

> **Goal:** Fine-grained role-based access control (RBAC) where each user's role determines exactly which modules, endpoints, and operations they can access.
>
> **Auth strategy:** Custom auth (bcrypt + PyJWT) — roles are stored in our `users` table, not Supabase `app_metadata`.
>
> **Depends on:** `plan_multi_tenant.md` (tenant_id) + `plan_multi_user.md` (auth + users table)

---

## Current State

- No authentication — all endpoints are public
- No roles — no concept of "who can do what"
- `created_by` fields exist but are never populated

---

## Role Definitions

### 5 Roles (hierarchical)

| Role | Description | Typical User |
|------|-------------|--------------|
| **owner** | Full control. Can manage everything including users and tenant settings. One per tenant (transferable). | Madrasa founder/principal |
| **admin** | Full operational control. Can manage users (except owner), all modules. Cannot delete tenant or transfer ownership. | Head teacher, vice principal |
| **accountant** | Financial operations. Can manage fees, payments, expenses, income, salary, reports. Cannot manage students, employees, or system settings. | Accounts officer |
| **teacher** | Read-only access to students and classes. Can view their own salary history. Cannot access financial modules. | Class teacher |
| **viewer** | Read-only access to permitted modules. Cannot create, update, or delete anything. | Auditor, board member |

### Role Hierarchy

```
owner > admin > accountant > teacher > viewer
```

Each higher role inherits all permissions of lower roles, **plus** additional permissions.

### Where Roles are Stored (Hybrid Approach)

```
roles table (DB)              →  defines WHAT roles exist (id, name, description)
    ↓
users.role_id → roles.id (FK) →  links user to role (DB-level integrity)
    ↓
JWT payload → role (string)   →  role name embedded at login time
    ↓
CurrentUser object → user.role →  available in every route handler
    ↓
permissions.py (code)          →  ROLE_PERMISSIONS[role] checked per request
```

- **`roles` table** defines which roles exist, with display metadata (description, is_system)
- **`users.role_id`** enforces FK integrity — no invalid role strings
- **JWT** carries the role name (not the ID) for fast permission checks without DB lookups
- **`permissions.py`** maps role names to permission lists in code — fast, no DB queries

---

## Permission Matrix

### Module-Level Permissions

| Module | Endpoint Pattern | owner | admin | accountant | teacher | viewer |
|--------|-----------------|-------|-------|------------|---------|--------|
| **Tenant Settings** | `/tenants/me` | RW | R | — | — | — |
| **User Management** | `/users/*` | RW | RW* | — | — | — |
| **Academic** | `/classes`, `/sections`, `/academic-years` | RW | RW | R | R | R |
| **Students** | `/students` | RW | RW | R | R | R |
| **Students Financial** | `/students/{id}/summary,fees,payments,ledger` | RW | RW | RW | — | R |
| **Employees** | `/employees` | RW | RW | R | — | — |
| **Accounts** | `/accounts` | RW | RW | R | — | — |
| **Fee Types** | `/fee-types` | RW | RW | RW | — | R |
| **Fee Assignment** | `/fees/*` | RW | RW | RW | — | R |
| **Payments** | `/payments/*` | RW | RW | RW | — | R |
| **Salary** | `/salary/*` | RW | RW | RW | — | — |
| **Expenses** | `/expenses/*` | RW | RW | RW | — | R |
| **Income** | `/income/*` | RW | RW | RW | — | R |
| **Reports** | `/reports/*` | R | R | R | — | R |
| **Dashboard** | `/reports/dashboard` | R | R | R | — | R |
| **Journal** | `/journal/*` | R | R | R | — | R |
| **Journal Reversal** | `/journal/{id}/reverse` | RW | RW | RW | — | — |

**Legend:** R = Read, W = Write (create/update/delete), — = No access  
**RW\*** = admin can manage all users except owner

---

## Schema: `roles` Table

```sql
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,         -- 'owner', 'admin', 'accountant', 'teacher', 'viewer'
    description TEXT,                  -- Human-readable, can be in Bengali
    is_system BOOLEAN DEFAULT TRUE,    -- System roles cannot be deleted
    created_at TIMESTAMP DEFAULT NOW()
);

-- Seed the 5 system roles
INSERT INTO roles (name, description, is_system) VALUES
    ('owner', 'Full control — madrasa founder/principal', TRUE),
    ('admin', 'Operational control — head teacher, vice principal', TRUE),
    ('accountant', 'Financial operations — accounts officer', TRUE),
    ('teacher', 'Read-only students + own salary — class teacher', TRUE),
    ('viewer', 'Read-only access — auditor, board member', TRUE);
```

### Updated `users` table (from `plan_multi_user.md`)

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    phone TEXT,
    role_id INT NOT NULL REFERENCES roles(id),   -- FK to roles table
    is_active BOOLEAN DEFAULT TRUE,
    last_login TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP NULL
);
```

### API: List Roles Endpoint

```python
@router.get("/roles")
def list_roles():
    """List all available roles (for dropdowns in user management UI)."""
    resp = supabase.table("roles").select("id, name, description").execute()
    return resp.data
```

### Login: Resolve role name from role_id

```python
# During login, join users with roles to get the role name:
resp = (
    supabase.table("users")
    .select("*, roles(name)")
    .eq("email", email)
    .single()
    .execute()
)
role_name = resp.data["roles"]["name"]  # "owner", "admin", etc.
# Embed role_name in JWT (not role_id) for fast permission checks
```

---

## Implementation Approach: Hybrid (DB Roles + Code Permissions)

| Layer | What | Where | Why |
|-------|------|-------|-----|
| **Role definitions** | What roles exist | `roles` table (DB) | FK integrity, frontend dropdowns, metadata |
| **User-role link** | Which user has which role | `users.role_id → roles.id` (DB) | Referential integrity |
| **Permission definitions** | What each role can do | `permissions.py` (code) | Fast lookups, no DB query per request |
| **Permission checking** | Is this user allowed? | `auth.py` dependency (code) | FastAPI dependency injection |

### Why NOT full DB-driven permissions?

A `role_permissions` table would mean DB queries on every API call. At 5 fixed roles and ~30 permission strings, the hardcoded dict is:
- **Faster** — zero DB overhead per request
- **Simpler** — one file to audit, no join queries
- **Sufficient** — madrasa roles are stable (owner/admin/accountant/teacher/viewer)

> [!NOTE]
> If tenants need custom roles later, we add a `role_permissions` table and swap the data source in `has_permission()`. The permission-checking interface stays the same — only the data source changes.

---

## Application Layer Implementation

### 1. Permission Definitions: `dependencies/permissions.py`

```python
"""
Role-based permission definitions and checking utilities.
Roles and permissions are hardcoded — no database dependency.
"""

ROLE_PERMISSIONS: dict[str, list[str]] = {
    "owner": [
        "tenants:read", "tenants:write",
        "users:read", "users:write", "users:invite", "users:change_role",
        "academic:read", "academic:write",
        "students:read", "students:write",
        "students_financial:read", "students_financial:write",
        "employees:read", "employees:write",
        "accounts:read", "accounts:write",
        "fee_types:read", "fee_types:write",
        "fees:read", "fees:write",
        "payments:read", "payments:write",
        "salary:read", "salary:write",
        "expenses:read", "expenses:write",
        "income:read", "income:write",
        "reports:read",
        "journal:read", "journal:reverse",
    ],
    "admin": [
        "tenants:read",
        "users:read", "users:write", "users:invite",
        "academic:read", "academic:write",
        "students:read", "students:write",
        "students_financial:read", "students_financial:write",
        "employees:read", "employees:write",
        "accounts:read", "accounts:write",
        "fee_types:read", "fee_types:write",
        "fees:read", "fees:write",
        "payments:read", "payments:write",
        "salary:read", "salary:write",
        "expenses:read", "expenses:write",
        "income:read", "income:write",
        "reports:read",
        "journal:read", "journal:reverse",
    ],
    "accountant": [
        "academic:read",
        "students:read",
        "students_financial:read", "students_financial:write",
        "employees:read",
        "accounts:read",
        "fee_types:read", "fee_types:write",
        "fees:read", "fees:write",
        "payments:read", "payments:write",
        "salary:read", "salary:write",
        "expenses:read", "expenses:write",
        "income:read", "income:write",
        "reports:read",
        "journal:read", "journal:reverse",
    ],
    "teacher": [
        "academic:read",
        "students:read",
        "salary:read_own",
    ],
    "viewer": [
        "academic:read",
        "students:read",
        "students_financial:read",
        "fee_types:read",
        "fees:read",
        "payments:read",
        "expenses:read",
        "income:read",
        "reports:read",
        "journal:read",
    ],
}


def has_permission(role: str, permission: str) -> bool:
    """Check if a role has a specific permission."""
    return permission in ROLE_PERMISSIONS.get(role, [])


def has_any_permission(role: str, permissions: list[str]) -> bool:
    """Check if a role has ANY of the given permissions."""
    role_perms = set(ROLE_PERMISSIONS.get(role, []))
    return bool(role_perms & set(permissions))
```

### 2. Permission Dependencies: `dependencies/auth.py` (extended)

```python
from dependencies.permissions import has_permission, has_any_permission


def require_permission(permission: str):
    """
    FastAPI dependency factory.
    Returns a dependency that checks if the current user has the required permission.

    Usage:
        @router.post("/students",
                     dependencies=[Depends(require_permission("students:write"))])
        def create_student(...):
    """
    def checker(user: CurrentUser = Depends(get_current_user)):
        if not has_permission(user.role, permission):
            raise HTTPException(
                status_code=403,
                detail=f"Permission denied. Required: {permission}, your role: {user.role}"
            )
        return user
    return checker


def require_any_permission(*permissions: str):
    """Check if user has ANY of the listed permissions."""
    def checker(user: CurrentUser = Depends(get_current_user)):
        if not has_any_permission(user.role, list(permissions)):
            raise HTTPException(
                status_code=403,
                detail=f"Permission denied. Required one of: {permissions}"
            )
        return user
    return checker


def require_role(*roles: str):
    """Shortcut: require user to have one of the specified roles."""
    def checker(user: CurrentUser = Depends(get_current_user)):
        if user.role not in roles:
            raise HTTPException(
                status_code=403,
                detail=f"This action requires role: {', '.join(roles)}"
            )
        return user
    return checker
```

### 3. Route Integration Patterns

#### Pattern A: Permission on individual endpoints (recommended)

```python
@router.post("",
    status_code=201,
    dependencies=[Depends(require_permission("students:write"))],
)
def create_student(
    student: StudentCreate,
    user: CurrentUser = Depends(get_current_user),
):
    data = {
        "name": student.name,
        "tenant_id": user.tenant_id,
        "created_by": user.user_id,
    }
    ...
```

#### Pattern B: Read permission on router, write on individual

```python
# All fee routes require at minimum fee_types:read
router = APIRouter(
    prefix="/fee-types",
    tags=["Fee Types"],
    dependencies=[Depends(get_current_user)],  # auth required for all
)

@router.get("")  # read — checked inline or via additional dependency
def list_fee_types(user: CurrentUser = Depends(require_permission("fee_types:read"))):
    ...

@router.post("", dependencies=[Depends(require_permission("fee_types:write"))])
def create_fee_type(...):
    ...
```

#### Pattern C: Inline permission check (for conditional logic)

```python
@router.get("/salary/history")
def salary_history(
    user: CurrentUser = Depends(get_current_user),
    employee_id: Optional[int] = None,
):
    # Teachers can only see their own salary
    if user.role == "teacher":
        emp = (
            supabase.table("employees")
            .select("id")
            .eq("user_id", user.user_id)
            .eq("tenant_id", user.tenant_id)
            .execute()
        )
        if not emp.data:
            return []
        employee_id = emp.data[0]["id"]
    elif not has_permission(user.role, "salary:read"):
        raise HTTPException(status_code=403, detail="Permission denied")
    ...
```

---

## Route-by-Route Permission Mapping

### Academic Routes (`routes/academic.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /classes` | `academic:read` | all |
| `POST /classes` | `academic:write` | owner, admin |
| `PUT /classes/{id}` | `academic:write` | owner, admin |
| `GET /sections` | `academic:read` | all |
| `POST /sections` | `academic:write` | owner, admin |
| `GET /academic-years` | `academic:read` | all |
| `POST /academic-years` | `academic:write` | owner, admin |
| `PUT /academic-years/{id}` | `academic:write` | owner, admin |

### Student Routes (`routes/students.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /students` | `students:read` | all |
| `POST /students` | `students:write` | owner, admin |
| `GET /students/{id}` | `students:read` | all |
| `PUT /students/{id}` | `students:write` | owner, admin |
| `DELETE /students/{id}` | `students:write` | owner, admin |
| `GET /students/{id}/summary` | `students_financial:read` | owner, admin, accountant, viewer |
| `GET /students/{id}/fees` | `students_financial:read` | owner, admin, accountant, viewer |
| `GET /students/{id}/payments` | `students_financial:read` | owner, admin, accountant, viewer |
| `GET /students/{id}/ledger` | `students_financial:read` | owner, admin, accountant, viewer |

### Employee Routes (`routes/employees.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /employees` | `employees:read` | owner, admin, accountant |
| `POST /employees` | `employees:write` | owner, admin |
| `GET /employees/{id}` | `employees:read` | owner, admin, accountant |
| `PUT /employees/{id}` | `employees:write` | owner, admin |
| `DELETE /employees/{id}` | `employees:write` | owner, admin |

### Account Routes (`routes/accounts.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /accounts` | `accounts:read` | owner, admin, accountant |
| `POST /accounts` | `accounts:write` | owner, admin |
| `PUT /accounts/{id}` | `accounts:write` | owner, admin |
| `DELETE /accounts/{id}` | `accounts:write` | owner, admin |

### Fee Routes (`routes/fees.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /fee-types` | `fee_types:read` | owner, admin, accountant, viewer |
| `POST /fee-types` | `fee_types:write` | owner, admin, accountant |
| `PUT /fee-types/{id}` | `fee_types:write` | owner, admin, accountant |
| `DELETE /fee-types/{id}` | `fee_types:write` | owner, admin, accountant |
| `POST /fees/assign` | `fees:write` | owner, admin, accountant |
| `GET /fees` | `fees:read` | owner, admin, accountant, viewer |
| `DELETE /fees/{id}` | `fees:write` | owner, admin, accountant |

### Payment Routes (`routes/payments.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `POST /payments` | `payments:write` | owner, admin, accountant |
| `GET /payments` | `payments:read` | owner, admin, accountant, viewer |
| `GET /payments/{id}` | `payments:read` | owner, admin, accountant, viewer |
| `POST /payments/{id}/allocate` | `payments:write` | owner, admin, accountant |
| `POST /payments/{id}/finalize` | `payments:write` | owner, admin, accountant |
| `POST /payments/payment-allocations` | `payments:write` | owner, admin, accountant |

### Salary Routes (`routes/salary.py`)

| Endpoint | Permission | Roles | Notes |
|----------|------------|-------|-------|
| `POST /salary/pay` | `salary:write` | owner, admin, accountant | |
| `GET /salary/history` | `salary:read` or `salary:read_own` | owner, admin, accountant, teacher | Teacher: own salary only |

### Expense Routes (`routes/expenses.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `POST /expenses` | `expenses:write` | owner, admin, accountant |
| `GET /expenses` | `expenses:read` | owner, admin, accountant, viewer |
| `GET /expenses/{id}` | `expenses:read` | owner, admin, accountant, viewer |
| `DELETE /expenses/{id}` | `expenses:write` | owner, admin, accountant |

### Income Routes (`routes/income.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `POST /income` | `income:write` | owner, admin, accountant |
| `GET /income` | `income:read` | owner, admin, accountant, viewer |
| `GET /income/{id}` | `income:read` | owner, admin, accountant, viewer |
| `DELETE /income/{id}` | `income:write` | owner, admin, accountant |

### Report Routes (`routes/reports.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /reports/trial-balance` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/income-statement` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/balance-sheet` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/ledger` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/students-due` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/fee-details` | `reports:read` | owner, admin, accountant, viewer |
| `GET /reports/dashboard` | `reports:read` | owner, admin, accountant, viewer |

### Journal Routes (`routes/journal.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `GET /journal` | `journal:read` | owner, admin, accountant, viewer |
| `GET /journal/{id}` | `journal:read` | owner, admin, accountant, viewer |
| `POST /journal/{id}/reverse` | `journal:reverse` | owner, admin, accountant |

### User Management Routes (`routes/users.py`)

| Endpoint | Permission | Roles |
|----------|------------|-------|
| `POST /users/invite` | `users:invite` | owner, admin |
| `GET /users` | `users:read` | owner, admin |
| `GET /users/{id}` | `users:read` | owner, admin (or self) |
| `PUT /users/{id}` | `users:write` | owner, admin (or self for profile) |
| `DELETE /users/{id}` | `users:write` | owner, admin |
| `PUT /users/{id}/role` | `users:change_role` | owner only |

---

## Special Permission Rules

### 1. Teacher Self-Scope (salary)

Teachers can only see their own salary. Requires `user_id` column on `employees` table:

```python
@router.get("/salary/history")
def salary_history(user: CurrentUser = Depends(get_current_user)):
    if user.role == "teacher":
        emp = (
            supabase.table("employees")
            .select("id")
            .eq("user_id", user.user_id)
            .eq("tenant_id", user.tenant_id)
            .execute()
        )
        if not emp.data:
            return []
        # Only query salary for this employee
        query = query.eq("employee_id", emp.data[0]["id"])
```

> [!NOTE]
> Requires a `user_id UUID REFERENCES users(id)` column on the `employees` table. Added in the multi-user migration.

### 2. Admin Cannot Modify Owner

```python
@router.put("/users/{id}/role")
def change_role(id: str, user: CurrentUser = Depends(require_role("owner"))):
    target = get_user_profile(id)
    if target["role"] == "owner":
        raise HTTPException(403, "Cannot modify the owner's role")
```

### 3. Self-Profile Updates

Any user can update their own name and phone:

```python
@router.put("/users/{id}")
def update_user(id: str, user: CurrentUser = Depends(get_current_user)):
    if id == user.user_id:
        allowed_fields = ["full_name", "phone"]  # self-update limited
    elif has_permission(user.role, "users:write"):
        allowed_fields = ["full_name", "phone", "is_active"]  # admin/owner
    else:
        raise HTTPException(403, "Permission denied")
```

### 4. Owner Cannot Be Deactivated

```python
@router.delete("/users/{id}")
def deactivate_user(id: str, user: CurrentUser = Depends(require_permission("users:write"))):
    target = get_user_profile(id)
    if target["role"] == "owner":
        raise HTTPException(403, "Cannot deactivate the owner")
    if id == user.user_id:
        raise HTTPException(403, "Cannot deactivate yourself")
```

---

## Error Responses

Consistent permission error format:

```json
// 401 — Not authenticated
{
    "detail": "Invalid or expired token"
}

// 403 — Authenticated but not authorized
{
    "detail": "Permission denied. Required: payments:write, your role: teacher"
}

// 403 — Role restriction
{
    "detail": "This action requires role: owner"
}
```

---

## New Files

| File | Purpose |
|------|---------|
| `dependencies/permissions.py` | Role definitions, `has_permission()`, `has_any_permission()` |
| `dependencies/auth.py` (extended) | `require_permission()`, `require_role()`, `require_any_permission()` |

**Modified files:** All 12+ route files (add permission dependencies to every endpoint)

---

## Testing Strategy

### Unit Tests

```python
def test_owner_has_all_permissions():
    assert has_permission("owner", "students:write")
    assert has_permission("owner", "users:change_role")
    assert has_permission("owner", "tenants:write")

def test_teacher_limited():
    assert has_permission("teacher", "students:read")
    assert has_permission("teacher", "academic:read")
    assert not has_permission("teacher", "students:write")
    assert not has_permission("teacher", "payments:read")
    assert not has_permission("teacher", "salary:write")

def test_viewer_read_only():
    viewer_perms = ROLE_PERMISSIONS["viewer"]
    assert all(":read" in p for p in viewer_perms)

def test_accountant_no_student_write():
    assert has_permission("accountant", "students:read")
    assert not has_permission("accountant", "students:write")
```

### Integration Tests

```
1. Register tenant (owner created)
2. Owner invites admin → admin can create students ✅
3. Owner invites teacher → teacher CANNOT create students ✅
4. Owner invites viewer → viewer can only read ✅
5. Teacher accesses salary → only own salary returned ✅
6. Admin tries to change owner role → 403 ✅
7. Viewer tries to record payment → 403 ✅
8. Accountant creates payment → ✅, tries to create student → 403 ✅
```

---

## Execution Order

> ⚠️ Must be done AFTER multi-user is in place (auth dependency exists).

```
1. Create dependencies/permissions.py (role definitions)
2. Extend dependencies/auth.py (require_permission, require_role)
3. Update routes/academic.py — add permission checks
4. Update routes/students.py — add permission checks
5. Update routes/employees.py — add permission checks
6. Update routes/accounts.py — add permission checks
7. Update routes/fees.py — add permission checks
8. Update routes/payments.py — add permission checks
9. Update routes/salary.py — add permission checks + teacher self-scope
10. Update routes/expenses.py — add permission checks
11. Update routes/income.py — add permission checks
12. Update routes/reports.py — add permission checks
13. Update routes/journal.py — add permission checks
14. Create/update routes/users.py — with role-based access
15. Write unit tests for permission matrix
16. Integration test: full role flow
```

---

## Future Enhancements (Not in Scope Now)

| Enhancement | Description |
|-------------|-------------|
| **Custom roles** | Let owners define custom roles with specific permissions (DB-driven Option B) |
| **Module toggle** | Enable/disable entire modules per tenant |
| **Audit log** | Log every permission check (who tried to do what, granted/denied) |
| **API key auth** | Service accounts with API keys for automated integrations |
| **2FA** | Two-factor authentication for owner/admin roles |
| **IP allowlisting** | Restrict access by IP for sensitive roles |

---

## Open Questions

> [!IMPORTANT]
> **Q1: Teacher-employee linking** — Should teachers be auto-linked to employee records via `user_id` on the `employees` table? This enables self-service salary viewing. Recommendation: yes.

> [!IMPORTANT]
> **Q2: Accountant scope** — Should the accountant role be split into "fee collector" (only payments) and "full accountant" (everything financial)? Relevant for larger madrasas.

> [!WARNING]
> **Q3: Viewer granularity** — Should viewers see ALL financial data (expenses, salary amounts) or just student-related data? Board members may need reports but not individual salary figures.

> [!IMPORTANT]
> **Q4: Offline access** — Do teachers need to work offline? If yes, we need a different token validation approach for mobile apps (longer-lived tokens, local caching).
