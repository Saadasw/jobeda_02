# Verify Migrations — Changes & Plan Upgrades

> Audit of `plan_multi_tenant.md`, `plan_multi_user.md`, and
> `plan_multi_role_permission.md` against the existing migrations
> 001–010 and the actual code (`routes/`, `models/`, `services/`).
>
> Output: 15 new migrations under this folder that implement the
> three plans **and** fix the gaps the plans missed.

---

## TL;DR

| Severity | Count | What |
|----------|-------|------|
| 🔴 BUG in current migrations | 1 | `income` table never created (route + trigger reference it) |
| 🔴 SECURITY in plan | 2 | Plaintext invitation tokens; missing password-reset table |
| 🔴 CORRECTNESS in plan | 3 | Receipt seq global; account-name uniqueness; role schema contradiction |
| 🟡 INTEGRITY in plan | 4 | Email uniqueness; created_by as TEXT; one-owner; system-role mutability |
| 🟡 PERFORMANCE in plan | 2 | Missing tenant_id on `journal_lines` / `payment_allocations` |
| 🟢 COMPLETENESS in plan | 3 | Missing `employees.user_id` migration; no audit log; no seed function |

---

## 1. 🔴 BUG — Missing `income` table

**Where it was missing:** Migrations 001–010 never created the
`income` table, but **all of these refer to it**:

* `routes/income.py:30` — `supabase.table("income").insert(data)`
* `routes/income.py:50` — `supabase.table("income").select("*")`
* `database_schema.txt:210-228` — defines `trg_income_journal()` but
  never attaches it to a table with `CREATE TRIGGER`.
* `plan_multi_tenant.md` — lists `income` as a tenant-scoped table.

**Fix:** [`011_create_income_table.sql`](011_create_income_table.sql)
creates the table and attaches the orphan trigger.

---

## 2. Plan: `plan_multi_tenant.md`

### 2a. 🔴 Receipt sequence is global — leaks data between tenants

**Where the plan went wrong:** Phase 1 listed receipt support as
"already done" (migration 005). But `receipt_seq` is a single global
PostgreSQL sequence. With two tenants:

```
Tenant A pays first  → PAY-2026-0001
Tenant B pays second → PAY-2026-0002   ← !!! gap in Tenant A's books
```

This breaks per-tenant numbering and also leaks "how busy are other
madrasas?" as a side-channel.

**Fix:** [`017_per_tenant_receipt_sequence.sql`](017_per_tenant_receipt_sequence.sql)
replaces the function with `generate_receipt_no(tenant_id)` backed by
a `tenant_counters` table keyed by `(tenant_id, kind, year)`.

### 2b. 🔴 Account-name lookup must be tenant-scoped

**Where the plan went wrong:** The plan addressed
`add_journal_line()` (lines 248–273) but did **not** call out that
the triggered lookup `WHERE name = p_account_name` would otherwise
match ANY tenant's row. Without a `UNIQUE (tenant_id, name)`
constraint and the corresponding WHERE clause, a fee assignment in
Tenant A could credit Tenant B's "Tuition Fees" — silently.

**Fix:**
* [`014_tenant_scoped_unique_constraints.sql`](014_tenant_scoped_unique_constraints.sql)
  adds `UNIQUE (tenant_id, name)` on accounts (and on fee_types,
  classes, academic_years).
* [`015_tenant_aware_helpers_and_triggers.sql`](015_tenant_aware_helpers_and_triggers.sql)
  rewrites `add_journal_line` to take and require `p_tenant_id`, plus
  cross-tenant safety checks in every trigger.

### 2c. 🟡 No `tenant_id` on `payment_allocations` / `journal_lines`

**Where the plan went wrong:** Phase 1 listed both tables but called
them "inherited via FK" (lines 87–88). For correctness that's true.
For PERFORMANCE it's catastrophic — every ledger / trial-balance /
income-statement query would have to chain 2–3 joins just to filter
by tenant. With even a few thousand journal lines per tenant the
reports queue.

**Fix:** [`013_add_tenant_id_to_tables.sql`](013_add_tenant_id_to_tables.sql)
denormalizes `tenant_id` onto both tables and indexes them. Trigger
in 015 stamps `tenant_id` on every `journal_lines` row.

### 2d. 🔴 Receipt_no UNIQUE was global

**Where the plan went wrong:** plan didn't address this — but the
underlying constraint from migration 003 was `UNIQUE` on
`payments.receipt_no` alone. Two tenants would clash.

**Fix:** [`014_tenant_scoped_unique_constraints.sql`](014_tenant_scoped_unique_constraints.sql)
drops the global key and adds `UNIQUE (tenant_id, receipt_no)`.

### 2e. 🟢 No seed function for new tenants

**Where the plan went wrong:** Plan says "On tenant creation,
auto-seed default chart of accounts (21 accounts), default fee types,
default academic year" (line 364) and assigns it to
`services/onboarding.py`. That's fine, but doing the seed in app code
means three round-trips and partial-failure risk.

**Fix:** [`025_tenant_default_seed_function.sql`](025_tenant_default_seed_function.sql)
adds `seed_tenant_defaults(tenant_id)` — atomic, idempotent, reusable
from both registration and CLI tooling.

---

## 3. Plan: `plan_multi_user.md`

### 3a. 🔴 SECURITY — invitation tokens stored in plaintext

**Where the plan went wrong:** Lines 104–105:

```sql
token TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex')
```

If the DB is leaked (read-only dump, accidental log, support
engineer access), every pending invitation can be hijacked.

**Fix:** [`020_invitations_and_refresh_tokens.sql`](020_invitations_and_refresh_tokens.sql)
stores only `token_hash` (SHA-256 of the secret). Application
generates the secret, shows it to the user once, and stores the hash.

### 3b. 🔴 CONTRADICTION — `role` field shape

**Where the plan went wrong:** `plan_multi_user.md:82` defines users
with `role TEXT CHECK (role IN ('owner','admin',…))`. But
`plan_multi_role_permission.md:119` defines users with
`role_id INT NOT NULL REFERENCES roles(id)`. They cannot both be
right. The role-permission plan is the later/more-detailed one and
supersedes — but the user plan would have been applied first.

**Fix:** [`019_users_table.sql`](019_users_table.sql)
uses `role_id INT NOT NULL REFERENCES roles(id)` from the start. The
roles table is created in [`018_roles_table.sql`](018_roles_table.sql)
so the FK target exists.

### 3c. 🟡 INTEGRITY — global email uniqueness blocks legitimate users

**Where the plan went wrong:** `plan_multi_user.md:78`:

```sql
email TEXT NOT NULL UNIQUE
```

Two madrasas (tenants) cannot both have `admin@madrasa.com` or both
have an "Abdul Karim" registered with his Gmail. That's surprising
in a SaaS product.

**Fix:** [`019_users_table.sql`](019_users_table.sql)
* `UNIQUE (tenant_id, lower(email))` — case-insensitive per tenant
* `email_lower` generated column for efficient lookup

### 3d. 🟢 No `password_resets` table (Q2 deferred)

**Where the plan went wrong:** Q2 in `plan_multi_user.md` punted
password reset to "later". But once you have logins, you have
forgotten passwords. Adding the table now is two columns of effort;
adding it later requires a schema migration on a live system.

**Fix:** [`020_invitations_and_refresh_tokens.sql`](020_invitations_and_refresh_tokens.sql)
adds `password_resets` (1-hour expiry, hashed token, single-use).

### 3e. 🟢 Refresh tokens were "optional"

**Where the plan went wrong:** Plan marked refresh_tokens as
"Optional". For production auth this is required — without it the
choice is between short-lived (15 min) sessions or long-lived
stealable tokens.

**Fix:** Built into [`020_invitations_and_refresh_tokens.sql`](020_invitations_and_refresh_tokens.sql).
Includes `user_agent` and `ip_address` so "log out other sessions"
works.

### 3f. 🟡 `created_by` as TEXT, not FK to users

**Where the plan went wrong:** Migration 003 (existing) added
`created_by TEXT NULL` on every table. Plan said the app would write
`user.user_id` (a UUID) into these — but TEXT means no referential
integrity. A typo, a deleted user, or a wrong literal lands silently.

**Fix:** [`022_audit_fk_user_columns.sql`](022_audit_fk_user_columns.sql)
adds `created_by_id UUID REFERENCES users(id)` and the equivalent
`updated_by_id` on all 12 tables (kept the old TEXT columns to
preserve historical data).

---

## 4. Plan: `plan_multi_role_permission.md`

### 4a. 🟢 `employees.user_id` was promised but never migrated

**Where the plan went wrong:** Section "Special Permission Rules #1
(Teacher Self-Scope)" says (line 536):

> Requires a `user_id UUID REFERENCES users(id)` column on the
> `employees` table. **Added in the multi-user migration.**

But `plan_multi_user.md` never adds this column. If both plans were
implemented as written, teacher salary self-scope would crash at
runtime with "column employees.user_id does not exist".

**Fix:** [`021_employees_user_link.sql`](021_employees_user_link.sql)
adds `employees.user_id` with:
* FK to `users(id) ON DELETE SET NULL`
* `UNIQUE` (one user → at most one employee record)
* trigger ensuring `users.tenant_id = employees.tenant_id` (defense
  against cross-tenant linking)

### 4b. 🟡 No protection on `is_system = TRUE` roles

**Where the plan went wrong:** Plan defines 5 system roles
(`owner`, `admin`, …) and stamps `is_system = TRUE` but doesn't
enforce that flag. A `DELETE FROM roles WHERE name='owner'` or a
rename via `UPDATE` would invalidate every active JWT (which embeds
the role NAME, not ID).

**Fix:** [`018_roles_table.sql`](018_roles_table.sql)
adds `trg_protect_system_roles` blocking DELETE, rename, and
`is_system` demotion on system roles.

### 4c. 🟡 One-owner-per-tenant invariant unprotected

**Where the plan went wrong:** Plan says "owner: One per tenant
(transferable)" (line 26). No DB constraint enforces this. A bug or
malicious admin could `UPDATE users SET role_id = owner_id` and
create two owners.

**Fix:** [`019_users_table.sql`](019_users_table.sql)
adds `trg_one_owner_per_tenant` trigger.
(Partial unique index can't reference a subquery in PG, so a trigger
is used.)

### 4d. 🟢 No audit log

**Where the plan went wrong:** Plan listed "Audit log" under
"Future Enhancements (Not in Scope Now)" (line 681). For a system
that handles money this is in practice not optional — compliance,
incident response, postmortems all need it.

**Fix:** [`023_security_audit_log.sql`](023_security_audit_log.sql)
adds `auth_audit_log` (append-only via trigger). Application can
write to it from login, permission deny, password change, etc.

---

## 5. Migrations 001–010 — Audit findings

| Migration | Issue | Fixed in |
|-----------|-------|----------|
| **003** | `accounts` got `is_deleted` but no `updated_at` / audit user columns | `022_audit_fk_user_columns.sql` adds `updated_at` |
| **003** | `fee_types` got `is_deleted` but no `updated_at` / audit user columns | `022_audit_fk_user_columns.sql` |
| **003** | `journal_entries` only got `is_reversed`, no `updated_at` | `022_audit_fk_user_columns.sql` |
| **003** | `payment_allocations` got nothing — no soft-delete, no audit | `022_audit_fk_user_columns.sql` adds `updated_at` |
| **(missing)** | `income` table never created despite trigger + route + plan reference | `011_create_income_table.sql` |
| **005** | Global `receipt_seq` (see 2a) | `017_per_tenant_receipt_sequence.sql` |
| **010** | Allocation guard does not enforce tenant consistency | `024_allocation_guard_tenant_aware.sql` |

---

## 6. Files in this folder

```
verify_migrations/
├── 011_create_income_table.sql                  # gap fix
├── 012_create_tenants_table.sql                 # multi-tenant
├── 013_add_tenant_id_to_tables.sql              # multi-tenant
├── 014_tenant_scoped_unique_constraints.sql     # multi-tenant (upgrade)
├── 015_tenant_aware_helpers_and_triggers.sql    # multi-tenant
├── 016_tenant_aware_views_and_functions.sql     # multi-tenant
├── 017_per_tenant_receipt_sequence.sql          # multi-tenant (upgrade)
├── 018_roles_table.sql                          # multi-role
├── 019_users_table.sql                          # multi-user + multi-role
├── 020_invitations_and_refresh_tokens.sql       # multi-user (security upgrade)
├── 021_employees_user_link.sql                  # multi-role
├── 022_audit_fk_user_columns.sql                # multi-user (integrity upgrade)
├── 023_security_audit_log.sql                   # multi-role (optional)
├── 024_allocation_guard_tenant_aware.sql        # multi-tenant
├── 025_tenant_default_seed_function.sql         # multi-tenant (upgrade)
├── README.md
└── CHANGES.md   ← you are here
```

Run order: numeric (011 → 025) after 001–010 are already applied.

---

## 7. What I did NOT change

The user asked to "Upgrade if needed." These are things that would
be tempting to touch but are out of scope:

* **Migrations 001–010** are untouched. New SQL lives in this
  `verify_migrations/` folder only. The existing migrations have
  already been applied to the dev DB (seed data in 007 was run).
  Editing them retroactively would break that.
* **Application code (`routes/`, `models/`, `services/`)** is
  untouched. The plans cover the app-layer changes; this task was
  scoped to migrations.
* **The original `changes.md`** (from 2026-05-08) is untouched.
  Windows is case-insensitive so a root-level `CHANGES.md` would
  collide. Hence this file sits inside `verify_migrations/`.
* **Migration 007 (`seed_data.sql`)** is not rewritten. New tenants
  get their defaults via `seed_tenant_defaults()` from migration
  025. The old seed remains the canonical setup for the `jobeda`
  default tenant.

---

## 8. Outstanding items I noticed but left alone

These are real but the user didn't ask:

* `routes/income.py` uses `float(payload.amount)` instead of keeping
  Decimal — same anti-pattern flagged in the original `changes.md`
  Item 1, but unrelated to the three plans.
* `database.py` still uses the publishable Supabase key.
  `plan_multi_tenant.md` Phase 1 calls for switching to
  `service_role`. That's an app-layer change.
* Migration 007 deletes ALL data before re-seeding (`DELETE FROM …`).
  Once multi-tenant is live, re-running 007 would wipe other
  tenants too. A future migration should guard against re-running.
