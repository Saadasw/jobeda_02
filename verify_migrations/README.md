# Verify Migrations — Jobeda Madrasa ERP

This folder contains migrations **011–025** that implement and (where
necessary) **upgrade** the three plan files:

* `plan_multi_tenant.md`
* `plan_multi_user.md`
* `plan_multi_role_permission.md`

The migrations 001–010 in `/migrations` are unchanged. Run these new
migrations IN NUMERIC ORDER, after 001–010 are already applied.

## Run order

| # | File | Purpose | Plan |
|---|------|---------|------|
| 011 | `011_create_income_table.sql` | **GAP FIX** — creates the missing `income` table | (none — bug in 001–010) |
| 012 | `012_create_tenants_table.sql` | `tenants` table + default tenant row | multi-tenant |
| 013 | `013_add_tenant_id_to_tables.sql` | Add `tenant_id` to all 15 tenant-scoped tables (nullable → backfill → NOT NULL → FK → index) | multi-tenant |
| 014 | `014_tenant_scoped_unique_constraints.sql` | Re-scope `receipt_no`, account/fee-type/class/year names to be unique per tenant | multi-tenant |
| 015 | `015_tenant_aware_helpers_and_triggers.sql` | Rewrite `create_journal_entry`, `add_journal_line`, and all 6 journal triggers to be tenant-aware | multi-tenant |
| 016 | `016_tenant_aware_views_and_functions.sql` | Update views to expose `tenant_id`; replace `dashboard_summary` view with a tenant-parameterised function | multi-tenant |
| 017 | `017_per_tenant_receipt_sequence.sql` | Replace global `receipt_seq` with a per-tenant counter (`generate_receipt_no(tenant_id)`) | multi-tenant ✦ upgrade |
| 018 | `018_roles_table.sql` | `roles` table + seed 5 system roles + system-role protection trigger | multi-role |
| 019 | `019_users_table.sql` | `users` table with `role_id` FK + per-tenant email uniqueness + one-owner-per-tenant trigger | multi-user + multi-role |
| 020 | `020_invitations_and_refresh_tokens.sql` | `invitations`, `refresh_tokens`, `password_resets` (token HASHES, not plaintext) | multi-user ✦ security upgrade |
| 021 | `021_employees_user_link.sql` | Add `employees.user_id` (FK + uniqueness + tenant-consistency trigger) for teacher self-scope | multi-role |
| 022 | `022_audit_fk_user_columns.sql` | Add UUID `created_by_id` / `updated_by_id` FK columns next to existing TEXT audit fields | multi-user ✦ integrity upgrade |
| 023 | `023_security_audit_log.sql` | `auth_audit_log` table (append-only) for login + permission events | multi-role ✦ optional |
| 024 | `024_allocation_guard_tenant_aware.sql` | Update allocation guard trigger to also reject cross-tenant allocations | multi-tenant ✦ defense in depth |
| 025 | `025_tenant_default_seed_function.sql` | `seed_tenant_defaults(tenant_id)` for atomic onboarding of accounts + fee types + academic year | multi-tenant ✦ upgrade |

## What "upgrade" means

Migrations marked ✦ go beyond what the plans literally specified.
The plans had **15 verifiable gaps** (security, correctness,
performance, internal contradictions). See `CHANGES.md` in the
project root for the full list of upgrades and where they live.

## Order matters

* `012` must run before `013` (FK target).
* `013` must run before `014` (unique constraints reference `tenant_id`).
* `014` must run before `015` (triggers look up accounts by
  `(tenant_id, name)` which is enforced by 014's unique constraint).
* `018` must run before `019` (users.role_id FK target).
* `019` must run before `020`/`021`/`022` (FK targets).
