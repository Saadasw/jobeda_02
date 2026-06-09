# HANDOFF — live status & next steps

_Backend pushed through commit `a373525`. Frontend committed locally through `c856d65` (no remote yet)._

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

### Verify backend quickly
```
./venv/Scripts/python.exe -c "import main; print(len(main.app.routes))"   # 177
# probe 038 applied:
./venv/Scripts/python.exe -c "from database import supabase as s; print(s.table('student_enrollments').select('id').limit(1).execute().data)"
```

---

## Frontend status (`../jobeda-frontend/`, local git only)
Commits: `20a4545` scaffold → `abb5743` auth → `d54bb1a` dashboard → `bfaf1f5` hide-pending-KPI → `5c1398b` students → `c856d65` fee-collection.

Built & **browser-verified**:
- **Auth**: login / refresh / logout, in-memory access token + single-flight 401 refresh, route guards (`ProtectedRoute`, `RoleRoute`), error normalizer (422 field errors vs `{detail}`), Mantine app shell.
- **Owner dashboard**: KPI cards (`/reports/dashboard`) + overdue-aging bars (`/late-fees/aging`). PENDING PAYMENTS card is intentionally hidden.
- **Students**: searchable + paginated list, profile page (summary + discount-aware fee table).
- **Fee collection**: Take-Payment modal (create → auto-allocate → receipt), role-gated, partial-failure safe, invalidates dashboard/student queries. Receipt persists after success.

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
Drifted from the clean seed (test payments: Yusuf/Khadija/Ahmed; one test guardian "Abdul Karim"). **To reset to pristine**: re-run `migrations/007_seed_data.sql` in the Supabase SQL editor — its wipe now also resets `tenant_counters`, so registrations restart at `2026-0001` and the next receipt is `PAY-2026-0011`.

---

## NEXT STEPS (priority order)
1. **Frontend consumption of the 038 fields** (the immediate next task):
   - Admission form: bio fields (dob/gender/address) + **guardian picker** (search existing or create) + section.
   - Students list: show **Reg-No / Section / Roll** columns; wire the `status` + `has_dues` filters.
   - Student detail: **payment-history view** with date-range / method / status filters.
   - All backend support is live as of `a373525`.
2. **Contract-phase migration** (separate, careful — design before coding): flip readers off the legacy `students.class_id/section_id` onto `student_enrollments` joins — affects `student_due_summary`, `fee_detail_summary`, `generate_report_card` (still reads `students.class_id`!), `compute_class_positions`, attendance summaries. Then drop/retire the legacy columns. Fixes the latent bug where promoting a student rewrites their *historical* report cards.
3. **Push the frontend repo** to GitHub (currently local-only).
4. Minor: map `create_payment`'s raw DB error to a clean message.

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
