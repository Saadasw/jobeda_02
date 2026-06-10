# HANDOFF — live status & next steps

_Backend pushed through `84371da` (github.com/Saadasw/jobeda_02). Frontend pushed through `f762380` (github.com/Saadasw/jobeda_02_f)._

We are building an **industry-grade React frontend** for the Jobeda ERP one careful, browser-verified feature at a time, and fixing backend data-correctness bugs as they surface. Read `CLAUDE.md` first for run commands / conventions / credentials.

---

## Backend status
Full multi-tenant ERP, migrations `001`–`038`, all route modules in `main.py` (177 routes). Recent work this stretch:

- **Auth**: added httpOnly refresh-token cookie (rotation) on `/auth/login|refresh|logout`; refresh/logout read cookie **or** body. `COOKIE_SECURE` env flag (default false for local http).
- **Student identity slice — migration `038`** (applied + backfilled + verified):
  - `students` gained `registration_no` (permanent, per-tenant, format `YYYY-NNNN`, e.g. `2026-0001`), `admission_date`, `date_of_birth`, `gender` (male/female/other), `address`, `guardian_id`.
  - new **`guardians`** table (name, phone, relation, email, occupation, address; siblings share one guardian).
  - new **`student_enrollments`** table = per-year `class_id`/`section_id`/`roll_no`/`status`/`is_current` (UNIQUE per student+year; one current per student; roll unique per year+class+section).
  - triggers: `trg_students_registration_no` (auto reg_no + admission_date on insert), `trg_students_default_enrollment` (mirror class/section into a current enrollment on insert). `generate_registration_no()` self-heals (GREATEST(counter+1, max+1)) like receipts.
- **API exposes 038 (commit `a373525`)**:
  - student responses include `registration_no` + `section` (name); create/update accept the bio + `guardian_id` fields.
  - `GET /students` filters: `status` (current-enrollment), `has_dues`; list rows now carry the section **name**.
  - `GET /students/{id}/payments` filters: `from`, `to`, `method`, `status`.
  - **Guardians CRUD** (`/guardians`, `+ /guardians/{id}/students`); writes role-gated.
  - **Financial writes role-gated** via `dependencies.get_financial_tenant_id` (owner/admin/accountant, JWT required, no header fallback): fee assign + fee-type C/U/D + payment create/allocate/finalize/manual-alloc. Verified: those endpoints return **401** without a token (an `X-Tenant-ID`-only request, which used to work, is now rejected).
- **roll_no enrichment (commit `3fef556`)**: `list_students` and `get_student` map the current enrollment's `roll_no` onto each student (roll lives on `student_enrollments`, not the student row); `StudentResponse` gained `roll_no`. `get_student` also enriches the section name.

### Verify backend quickly
```
./venv/Scripts/python.exe -c "import main; print(len(main.app.routes))"   # 177
# probe 038 applied:
./venv/Scripts/python.exe -c "from database import supabase as s; print(s.table('student_enrollments').select('id').limit(1).execute().data)"
```

---

## Frontend status (`../jobeda-frontend/` — remote `github.com/Saadasw/jobeda_02_f`)
Commits: `20a4545` scaffold → `abb5743` auth → `d54bb1a` dashboard → `bfaf1f5` hide-pending-KPI → `5c1398b` students → `c856d65` fee-collection → `de5d15b` student-identity UI.

Built & **browser-verified**:
- **Auth**: login / refresh / logout, in-memory access token + single-flight 401 refresh, route guards (`ProtectedRoute`, `RoleRoute`), error normalizer (422 field errors vs `{detail}`), Mantine app shell.
- **Owner dashboard**: KPI cards (`/reports/dashboard`) + overdue-aging bars (`/late-fees/aging`). PENDING PAYMENTS card is intentionally hidden.
- **Students list**: Reg-No / Section / Roll / **Group** columns; Class + dependent-Section + Status + Has-dues filters; searchable + paginated.
- **Admission** (`AddStudentModal` + `GuardianPicker`, owner/admin): name, class→section, academic year (defaults current), admission date (today), DOB, gender, address, guardian (pick existing or create inline). Creates guardian→student, reg-no auto-assigned by the DB, navigates to the new detail.
- **Student detail**: identity (reg-no · class · section · roll) + bio + guardian (name · phone) + inline fee-group reassign + **Edit** modal (`EditStudentModal` — name/admission/DOB/gender/address/fee-group/guardian; class/section excluded, they're enrollment-managed); discount-aware fee table; **payment history** (`StudentPaymentsTable`) with date-range / method / status filters.
- **Fee collection**: Take-Payment modal (create → auto-allocate → receipt), role-gated, partial-failure safe, invalidates dashboard/student/history queries. Receipt persists after success.
- Feature apis: `features/academic/api.ts` (classes/sections/years), `features/guardians/api.ts` (list/create/get).

Stack: React 18 + TS strict, Vite, Mantine 7, TanStack Query, React Router 6, Zustand, RHF + Zod, axios. `@/`→`src`. Dev proxy `/api`→:8000. Typed client: `npm run gen:api` (from backend `/openapi.json`).

---

## Data-correctness fixes (all found this project, live-verified)
1. **Cash double-count** (`035`): payment-allocation trigger was debiting Cash a 2nd time → changed to `Dr Unearned Revenue / Cr Accounts Receivable` + idempotent backfill. Cash went −37k → correct.
2. **Opening balance**: seed now posts `Dr Cash / Cr Opening Balance` 200,000 so the demo isn't cash-negative. Cash → +130k.
3. **Dashboard `total_due` ignored discounts** (`036`): now `Σgross − Σdiscounts − Σallocations` → 18,000→17,500, matching the students page.
4. **Receipt collision** (`037`): `generate_receipt_no` self-heals past directly-inserted receipts (seed wrote `PAY-2026-0001..0010` without advancing the counter).
5. **auto_allocate used GROSS not NET due** → over-allocated for discounted students. Rewrote `services/allocation.py` to read `fee_detail_summary.due` (net).
6. **Receipt-view wiped on re-render**: `TakePaymentModal` reset effect keyed on `due`; changed to reset only on open.

---

## Demo data state
Drifted from the clean seed: test payments (Yusuf/Khadija/Ahmed), test guardians ("Abdul Karim", "Rafiqul Islam"), and a test student admitted via the UI ("Bilal Ahmed", reg `2026-0009`, Hifz-1/A). The `classes` table also has junk rows from Swagger "try it out" testing (names `string` and `sf69c39b1-…`) that appear in the class dropdown — cosmetic only. **To reset to pristine**: re-run `migrations/007_seed_data.sql` in the Supabase SQL editor — its wipe clears these and resets `tenant_counters`, so registrations restart at `2026-0001` and the next receipt is `PAY-2026-0011`.

---

## NEXT STEPS (priority order)
1. **Roll assignment** (deferred from the admission UI): `create_student` doesn't accept `roll_no`, so the Roll column currently always shows `—`. Build a per-section roll-assignment flow that sets `student_enrollments.roll_no` (unique per year+class+section) — likely a small endpoint (e.g. `PUT /students/{id}/enrollment` or a bulk "assign rolls" action) plus UI.
2. **Contract-phase migration** (separate, careful — design before coding): flip readers off the legacy `students.class_id/section_id` onto `student_enrollments` joins — affects `student_due_summary`, `fee_detail_summary`, `generate_report_card` (still reads `students.class_id`!), `compute_class_positions`, attendance summaries. Then drop/retire the legacy columns. Fixes the latent bug where promoting a student rewrites their *historical* report cards.
3. Minor: map `create_payment`'s raw DB error to a clean message.

### Done recently
- ✅ **Frontend consumption of the 038 fields** — admission form (bio + guardian picker), Reg-No/Section/Roll columns, status/has_dues filters, payment-history view. Frontend `de5d15b`, backend roll enrichment `3fef556`. Browser-verified end-to-end (admitted a test student, reg-no auto-assigned `2026-0009`, guardian linked; has-dues 8→6; payment date filter).

---

## Fee generation — BUILT (backend `be7c87b`+`84371da`, frontend `f762380`)
Templated bulk billing with fee groups. Migrations **039 + 040** applied. Browser-verified end-to-end: Hifz-1 Day price list (Tuition 2,000 + Hostel 1,500/mo); Generate preview "6 fees / ৳10,500" → generated; fees show on student detail; reassign Day→Residential persists.

**What shipped:** fee_groups + fee_structures(+items) tables; group-aware `POST /fees/generate` (dry-run preview, idempotent skip, `no_structure` count) + `/fees/generate-manual`; fee-groups & fee-structures CRUD (finance-gated); Fees UI (nav section, structure editor per class×group, Generate modal preview→confirm, groups CRUD); fee-group select on admission + inline reassign on student detail.

**Deferred (follow-ups):** inline edit of a structure item's amount (currently remove + re-add); per-item selection in the generate run (currently bills all `monthly` items); termly/one-time billing needs a terms concept or manual month pick; auto-generate one-time fees at admission; a scheduled monthly auto-run; **007 seed wipe doesn't clear the new fee_* tables** (re-seeding leaves structures/groups — add them to the wipe later).

**Demo-data note:** the demo was re-seeded (student ids ~10–18, regs `2026-0001..0008`). Fee groups consolidated to **Residential / Free / Day** — a duplicate "Day" from UI testing (renamed "Day1") was archived and the original Day un-archived via a direct table update (the publishable-key client CAN do table writes, just not DDL). Hifz-1 **Day** price list = Tuition ৳2,000 + Hostel ৳1,500; Jun + Aug 2026 fees were generated for the 3 Hifz-1 Day students. 7 students on Day, **Ahmed on Residential** (no Hifz-1 Residential price list yet → he shows `no_structure` on a Hifz-1 generate until one is added or he's moved to Day). Khadija has gender/address set from an Edit-modal test. **Reminder:** the `007` wipe still doesn't clear `fee_groups`/`fee_structures`/`fee_structure_items` — re-seeding leaves these behind (the source of the earlier duplicate-Day tangle).

### Original decided design (for reference)
Owner chose the **fee-groups** variant (different fees within a class).

**Decisions (owner, this session):**
1. Void handling → **deleted stays deleted**: generation skips any existing `(tenant, student, fee_type, month)`, voided or not. **No change** to `uq_fee_per_tenant_student_type_month` (it is NOT partial on is_deleted — confirmed migration 014).
2. **Fee groups YES** — students in the same class pay different fees (boarding / day / free). Price lists are per **(year, class, fee_group)**.
3. UI → new **Fees** nav section (Fee Groups · Fee Types · Fee Structures · Generate Fees).
4. **`created_by_id`** on `fee_assignments` — stamp who ran the batch.

**Schema — migration `039` (next number; applied through 038 + my 035–037):**
- `fee_groups(id, tenant_id, name, description, is_deleted, created_at)`; unique name/tenant (partial WHERE not deleted).
- `students.fee_group_id` (nullable FK) — student's *current* group (mirror pattern, like class_id; could move to enrollment later).
- `fee_structures(id, tenant_id, academic_year_id, class_id, fee_group_id, name, is_deleted, created_by_id, created_at)`; partial-unique `(tenant, year, class, fee_group)` WHERE not deleted.
- `fee_structure_items(id, tenant_id, fee_structure_id→CASCADE, fee_type_id, amount, frequency CHECK monthly/termly/annual/one_time, due_day 1..28, is_deleted)`; partial-unique `(structure, fee_type)`.
- `fee_types.frequency` (CHECK monthly/termly/annual/one_time/adhoc; backfill from is_recurring; keep is_recurring for now).
- `fee_assignments.created_by_id`.

**Generation (group-aware):** `POST /fees/generate {academic_year_id, month, class_id|null, section_id|null, fee_type_ids|null (null=monthly items), dry_run}`. Scope active students via `student_enrollments` (year, class?, section?, status='active'). For each student → find structure for `(year, student.class_id, student.fee_group_id)` → make rows from its items (amount, account=fee_type.account_id, due_date=month@due_day). Result `{created, skipped (already billed), no_structure (no matching price list), students_in_scope, total_amount}`. Core helper `_bulk_assign(tenant, month, rows, dry_run)`: pre-fetch existing for month (any is_deleted) → insert delta in chunks of 200 (journal trigger fires per row) → unique constraint is the race backstop. `dry_run` powers the UI preview. Also a **manual one-off** mode (explicit fee_type+amount, flat charge to a class, ignores structures) for ad-hoc fees.

**Endpoints:** fee-groups CRUD; `fee-structures` CRUD + `…/items` CRUD; `POST /fees/generate`. All writes financial-role (structures setup owner/admin). UI: Fees section (Groups CRUD, Structures editor = per-class accordion of per-group item tables, Generate modal w/ preview→confirm), + **Fee group select on admission form & student detail**.

**Defaults (unless owner objects):** create Residential/Day/Free groups, tag the 9 existing students **Day**; fee_group on `students` (not enrollment) for now.

**Build order:** 039 migration → backend (groups+structures CRUD + generate + smoke) → frontend Fees section → fee-group field on admission/detail → verify + commit per slice.

---

## Design decisions locked (from the admissions discussion)
- `registration_no` (permanent, per-tenant, `YYYY-NNNN`) **≠** `roll_no` (per year/class/section, reassigned yearly).
- `student_enrollments` is the source of truth for per-year class/section/roll/status. **Currently EXPAND phase**: legacy `students.class_id/section_id` kept and mirrored into enrollments via trigger; contract phase (step 2 above) still pending.
- `guardians` is its own table; siblings share `guardian_id`.
- Financial writes require owner/admin/accountant.

## Gotchas learned (don't relearn the hard way)
- **Migrations**: the user applies them in the Supabase SQL editor (I can't run DDL). A `relation "tenants" does not exist` error = SQL editor pointed at the wrong/empty project (`vaiswiwkxcpdwkbzuoax`), not `lltdojrxjdnwbwowqptb`.
- **Browser/preview tooling** (Claude Preview MCP) gets flaky after HMR churn — a Mantine modal can render empty. Restart the Vite dev server fresh before browser E2E.
- **Money serialization** is inconsistent (string vs number) — always go through `formatMoney`/`Number`.
- **Context**: browser screenshots are heavy; this kind of session fills the window fast. Compact at clean commit points.
