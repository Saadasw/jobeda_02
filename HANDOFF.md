# Jobeda Madrasa ERP — HANDOFF (project status)

> **Read `CLAUDE.md` first** (run commands, Supabase project id, conventions, git rules).
> This file = the living picture: **what's built, what's not, and why.** Read it top-to-bottom to get oriented.

_Repos — backend: `github.com/Saadasw/jobeda_02` · frontend: `github.com/Saadasw/jobeda_02_f` (both pushed). Migrations applied through **040**. Backend ≈191 routes. Latest commits at time of writing: backend `b2ddc30`, frontend `57f04f1` — check `git log` for newer._

---

## 1. What this project is
A multi-tenant madrasa/school ERP, built as two sibling repos:
- **`jobeda/`** — FastAPI + Supabase/PostgreSQL backend (mature: full accounting, fees, payroll, exams, attendance).
- **`../jobeda-frontend/`** — React + TS + Vite + Mantine SPA (newer: built feature-by-feature on the backend).

Working style this project: build the frontend **one careful, browser-verified feature at a time**, and fix backend data-correctness bugs as they surface. Commit per slice.

## 2. How it fits together (mental model)
```
React SPA (:5173) --/api proxy--> FastAPI (:8000) --Supabase REST/PostgREST--> Postgres
```
- **Auth:** custom `users` table (NOT Supabase auth). Login → JWT access token (~30 min) + httpOnly **refresh cookie** (rotated). SPA holds the access token in memory and does a single-flight refresh on 401.
- **Multi-tenant:** every table has `tenant_id`; every query filters by it. Active tenant = `f69c39b1-19ef-4a31-8658-e96d0140517c`.
- **Accounting is automatic:** DB triggers post double-entry journals on fee/payment/discount inserts (look up GL accounts by name/id). So creating a fee or payment moves AR/income/cash and the dashboard. Generated columns are read-only.
- **Migrations:** plain SQL in `migrations/NNN_*.sql`, **applied by the USER in the Supabase SQL editor** — the backend's publishable key can run table reads/writes but **not DDL**. After the user applies one, verify with a read probe.

## 3. Core domain concepts (clears up common confusion)
- **User ≠ Employee.** A *user* is a login account (email+password, one tenant, one role). An *employee* is a staff/payroll record with no login. The same words ("teacher", "admin") appear in both tables — different things. Demo login `owner@jobeda.com` is a user; the seeded teachers/admin are employees.
- **Roles:** `owner, admin, accountant, teacher, viewer` (`roles` table, migration 018). One owner per tenant.
- **Student identity:** `registration_no` (permanent, per-tenant `YYYY-NNNN`) **≠** `roll_no` (per year/class/section, reassigned). `student_enrollments` is the **source of truth** for per-year class/section/roll/status. Legacy `students.class_id/section_id` are still kept & mirrored into enrollments via trigger → this is the **EXPAND phase** (contract phase pending, see backlog).
- **Guardian:** own table; siblings share one `guardian_id`.
- **Fee model (the chain):** `fee_types` (catalog: Tuition/Hostel/Exam…) → `fee_groups` (Residential/Day/Free; each student is in one) → `fee_structures` (a price list per **year × class × group**) → `fee_structure_items` (fee_type + amount + frequency + due_day) → **fee generation** materializes `fee_assignments` (the actual dues) → **payments** allocate against them.

---

## 4. ✅ WHAT'S BUILT (done & working)

### Backend (migrations 001–040; FastAPI)
- **Auth/sessions:** register (founding owner), login, refresh (rotating httpOnly cookie), logout, `/auth/me`, change-password, password-reset request/confirm, account lockout. `COOKIE_SECURE` env flag (false for local http).
- **Users & invitations API** (owner/admin): list/get/create/update/deactivate users; create/list/revoke invitations + `/auth/accept-invitation`. **(API only — no UI yet.)** Invite tokens are returned in the response (no email transport yet).
- **Students:** CRUD + soft delete; identity fields (038); list enriched with section **name**, **roll_no**, **fee_group name**; filters class/section/status/has_dues/search; sub-endpoints summary/fees/payments(+date/method/status filters)/ledger.
- **Guardians:** CRUD + `/guardians/{id}/students`.
- **Academic:** classes / sections / academic-years CRUD.
- **Fees:** fee-types CRUD; assign; **fee_groups** CRUD; **fee_structures**(+items) CRUD; **group-aware generation** `POST /fees/generate` (dry-run preview, idempotent skip, `no_structure` count) + `/fees/generate-manual`.
- **Payments:** create → auto-allocate → finalize; manual allocation; receipts (`generate_receipt_no`, self-healing).
- **Money modules:** salary, payroll, expenses, income; accounts, journal, accounting_reports; reports (dashboard summary, fee-details, late-fee aging); discounts/waivers (027); due-dates + late fees (028).
- **Plumbing:** double-entry journal triggers; `tenant_counters` (per-tenant/year sequences for receipts + registrations).

### Frontend (React SPA; remote `jobeda_02_f`)
Commits: `20a4545` scaffold → auth → dashboard → students → fee-collection → student-identity UI → fees UI → group column → student edit (`57f04f1`).
- **Auth:** login, guards (`ProtectedRoute`/`RoleRoute`), in-memory token + single-flight 401 refresh, error normalizer, Mantine app shell with role-gated nav.
- **Owner dashboard:** KPI cards + overdue-aging bars (PENDING-PAYMENTS card intentionally hidden).
- **Students:** list (Reg-No/Section/Roll/**Group** columns; Class+Section+Status+Has-dues filters; search+paginate); **admission** modal (bio + guardian picker, owner/admin); **detail** (identity+bio+guardian, inline fee-group reassign, **Edit** modal, discount-aware fee table, **payment history** with filters).
- **Fees section** (owner/admin/accountant): **Fee Types CRUD** (frequency + revenue-account picker), Fee Groups CRUD, Fee Structures editor (per class → per-group price lists), **Generate Fees** modal (From-structures / Manual, preview→confirm).
- **Accounts** (Chart of Accounts, owner/admin/accountant): grouped by type; add account (e.g. "Meals Income") + rename non-system accounts; trigger-referenced **system accounts are locked**.
- **Expenses / Income** (owner/admin/accountant): record money out / non-fee money in (date · account · amount · note), posts journals via triggers. Shared `MoneyEntryPage` with a **date-range filter** (This month default · Last month · This year · All · Custom) and a correct period total (pulls the full range, not just a page). Income list now supports `from`/`to`/`account_id` (parity with expenses). No void/reversal yet (soft-delete wouldn't reverse the journal); period total is fetch-all-in-range (limit 1000) — a server aggregate is the path beyond that scale.
- **Take Payment** modal (create→allocate→receipt, partial-failure safe, query invalidation).
- Shared: `formatMoney`, date helpers, `AsyncBoundary`, `StatCard`; feature apis for academic/guardians/fees.

Stack: React 18 + TS strict · Vite · Mantine 7 · TanStack Query · React Router 6 · Zustand · RHF+Zod · axios. `@/`→`src`. Dev proxy `/api`→:8000. Regenerate types: `npm run gen:api`.

---

## 5. 🚧 WHAT'S NOT DONE (backlog)
Priority 🔴 high / 🟡 medium / 🟢 nice-to-have · size S/M/L.

**Security / hardening**
- 🔴 S — **Role-gate the remaining open writes.** Student create/edit/delete, academic CRUD, salary/payroll, exams/attendance are **not role-gated** (any logged-in user can do them). Make teacher/viewer truly read-only. (Gated today: fees, payments, discounts, guardians, users, **expenses, income** — see §6.)
- 🟡 M — Optional `role_permissions` table (data-driven) instead of scattered `require_roles`.
- 🟢 S — Tighten the `X-Tenant-ID` header fallback (lets non-financial endpoints be hit without a JWT).

**Missing UI (backend exists, no screen)**
- 🟡 M — **Users management** (list/invite/change-role/deactivate) — currently API-only.
- 🟢 S — **Account archive/delete + parent hierarchy.** The Accounts UI (✅ done, frontend `f38ec3c`) does **create + rename** only; system accounts (trigger-referenced) are locked. Deferred: archiving an account (needs guardrails — block if a fee type or journal uses it) and setting `parent_id` for CoA nesting (new accounts are top-level today). _(Fee Types screen: ✅ done `b365b5f`.)_
- 🟡 M — **Salary/Payroll, Journal viewer, Accounting reports** (income statement / balance sheet / trial balance). _(Expenses + Income ✅ done `7aefced`; Accounts UI ✅ done.)_
- 🟢 M — Employees, Exams, Attendance, Discounts UI, Notifications.

**Students / enrollment**
- 🔴 M — **Roll assignment** (per section). `create_student` doesn't take a roll → Roll column always "—". Needs an endpoint (e.g. `PUT /students/{id}/enrollment` or bulk assign) + UI.
- 🔴 M — **Class transfer / promotion flow** that updates the per-year **enrollment** (the Edit modal omits class for exactly this reason).
- 🟡 L — **Contract-phase migration:** flip readers (`student_due_summary`, `fee_detail_summary`, `generate_report_card` — still reads `students.class_id`! — `compute_class_positions`, attendance summaries) onto `student_enrollments`; then retire legacy `students.class_id/section_id`. **Fixes a latent bug:** promoting a student currently rewrites their *historical* report cards. (Could also move `fee_group_id` to the enrollment for per-year groups.)

**Fee system follow-ups**
- 🟡 S — Inline **edit of a structure item's amount** (today: remove + re-add).
- 🟡 S — **Per-item selection** in Generate (today bills all `monthly` items).
- 🟢 M — **Termly / one-time billing** (needs a "terms" concept or manual month pick).
- 🟢 M — Auto-generate one-time fees **at admission** + a **scheduled monthly auto-run**.

**Data / infra / ops**
- 🟡 S — **`007` seed wipe doesn't clear `fee_groups`/`fee_structures`/`fee_structure_items`** → re-seeding strands them (caused the duplicate-"Day" tangle). Add them to the wipe.
- 🟡 S — **Populate `journal_entries.reference_type` / `reference_id` in all 6 journal triggers.** The columns exist but every trigger leaves them NULL, so journals have **no link to their source row** — which is why the `042` backfill had to match by description/amount. Wiring these (e.g. `'fee_assignment'` + `NEW.id`) enables clean audit, reversals, and exact backfills. (Check the column's CHECK constraint first — it's in the base schema, not a migration.)
- 🟡 M — **Email transport** for invitations + password reset (tokens currently returned in API response).
- 🟡 M — **Deployment** (nothing hosted) + prod config (`VITE_API_BASE_URL`, `COOKIE_SECURE=true`).
- 🟢 M — **Automated tests** (only manual smoke tests today).
- 🟢 S — Standardize money serialization (string vs number); frontend code-splitting (bundle >500 kB).

**Small fixes / demo cleanup**
- 🟢 S — `create_payment` raw DB error → clean message.
- 🟢 S — Junk `classes` rows (`string`, `sf69c39b1…` from Swagger testing) — cosmetic; cleared by re-seed.
- 🟢 S — Demo: add a **Hifz-1 Residential** price list (so Ahmed bills) or move Ahmed back to Day.

**Top 3 to do next:** ① role-gate the open writes · ② contract-phase migration · ③ roll assignment + class transfer.

---

## 6. Roles & permissions — ACTUAL enforcement
No permissions table; roles are enforced inline per endpoint. Today:

| Capability | owner | admin | accountant | teacher | viewer |
|---|:--:|:--:|:--:|:--:|:--:|
| Users + invitations | ✓ | ✓ | — | — | — |
| Fees (assign/types/generate, groups, structures) | ✓ | ✓ | ✓ | — | — |
| Payments / discounts / guardians writes | ✓ | ✓ | ✓ | — | — |
| **Students, academic, salary, expenses, income, exams, attendance writes** | ✓ | ✓ | ✓ | ✓ | ✓ |  ← ⚠️ **NOT gated** (any auth) |
| All reads | open to any authenticated user |

`get_financial_tenant_id` (owner/admin/accountant, JWT required) gates the fee/payment writes; `require_roles("owner","admin")` gates users. **Gap:** the descriptions call teacher/viewer "read-only," but the API doesn't enforce that on the non-fee write endpoints yet (top backlog item).

---

## 7. Data-correctness fixes (found & fixed this project, live-verified)
1. **Cash double-count** (`035`): allocation trigger double-debited Cash → `Dr Unearned / Cr A/R` + backfill.
2. **Opening balance** (seed): posts `Dr Cash / Cr Opening Balance` 200,000 so the demo isn't cash-negative.
3. **Dashboard `total_due` ignored discounts** (`036`): now `Σgross − Σdiscounts − Σallocations`.
4. **Receipt collision** (`037`): `generate_receipt_no` self-heals past directly-inserted receipts.
5. **auto_allocate used GROSS not NET due** → rewrote `services/allocation.py` to use `fee_detail_summary.due`.
6. **Receipt-view wiped on re-render**: `TakePaymentModal` reset effect now keyed on open only.
7. **Fee revenue all booked to "Tuition Fees"** (`041`): `trg_fee_assignment_journal` hardcoded the credit and ignored `fee_assignments.account_id`, so Hostel/Exam/Meals income posted as Tuition in the GL (dues/balances unaffected — they derive from the amount, not the account). Fixed to resolve the account from `account_id` (mirrors `trg_income_journal`); `042` backfills historical lines (guarded, unique-match only).

---

## 8. Migrations
Applied **through 040**. Workflow: I write `migrations/NNN_*.sql` → **user runs it in the Supabase SQL editor** → I verify via probe. Key recent ones:
- `038` student identity, guardians, `student_enrollments` (+ reg-no/enrollment triggers).
- `039` fee groups, fee structures(+items), `students.fee_group_id`, `fee_types.frequency`, `fee_assignments.created_by_id`; seeds Residential/Day/Free + tags students Day.
- `040` fix `created_by_id` to **UUID** (users.id is UUID — `039` wrongly made it INT).
- `041` fee journal credits the fee's own revenue account (was hardcoded 'Tuition Fees'). `042` (optional, apply after 041) backfills historical fee journal lines, guarded/unique-match/idempotent.

**Fee generation schema/endpoints (reference):** `fee_groups`; `fee_structures(year,class,fee_group)`; `fee_structure_items(fee_type,amount,frequency,due_day)`. `POST /fees/generate {academic_year_id, month, class_id?, section_id?, fee_type_ids?, dry_run}` → scopes active students via `student_enrollments`, resolves each to their `(class, fee_group)` structure, inserts `fee_assignments` for the chosen items (default: monthly), **skipping already-billed** (the `uq_fee_per_tenant_student_type_month` UNIQUE — NOT partial on is_deleted — is the backstop). Decision: **deleted-fee stays deleted** (generation skips it).

---

## 9. Demo data state (current)
- Re-seeded at some point → student ids ~10–18, regs `2026-0001..0008`.
- Fee groups consolidated to **Residential / Free / Day** (an accidental duplicate "Day"/"Day1" was archived; original Day restored via a direct table update — the publishable key CAN do table writes, just not DDL).
- Hifz-1 **Day** price list = Tuition ৳2,000 + Hostel ৳1,500; June + August 2026 fees generated for the 3 Hifz-1 Day students.
- 7 students on Day; **Ahmed Hossain on Residential** (no Hifz-1 Residential price list yet → `no_structure` on a Hifz-1 generate until one is added or he's moved back to Day). Khadija has gender/address from an Edit test.
- **Reset to pristine:** re-run `migrations/007_seed_data.sql` (resets `tenant_counters`) — but note it does **not** clear the `fee_*` tables (backlog item).

---

## 10. Gotchas (don't relearn the hard way)
- **Wrong Supabase project:** `relation "tenants" does not exist` = SQL editor on the empty `vaiswiwkxcpdwkbzuoax` instead of the active `lltdojrxjdnwbwowqptb`.
- **Preview tooling flaky after HMR churn:** Mantine modals/routes can render stale. Restart the Vite dev server (or `preview_stop`+`preview_start`) fresh before browser E2E; reload to bust React Query's cached rows after a backend shape change.
- **`users.id` is a UUID** (not int) — any `created_by`/FK column referencing it must be UUID.
- **Money serialization** inconsistent (string vs number) — always go through `formatMoney`/`Number`.
- **Never commit** `.env` / `.env.example` (real Supabase keys) / `.claude/` / `venv/`.
- **Context fills fast** (browser screenshots are heavy) — compact at clean commit points.

## 11. Quick reference
```
# backend
cd jobeda && ./venv/Scripts/python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000
./venv/Scripts/python.exe -c "import main; print(len(main.app.routes))"   # ~191
# frontend
cd jobeda-frontend && npm run dev        # http://localhost:5173
# demo login: owner@jobeda.com / Owner@123 / tenant slug: jobeda
```
