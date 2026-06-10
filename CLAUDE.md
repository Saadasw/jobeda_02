# Jobeda Madrasa ERP — project guide

> **Read `HANDOFF.md` (this folder) for live status, recent fixes, pending work, and the exact next step.**

Multi-tenant madrasa/school ERP. Two sibling projects:
- `jobeda/` (this repo) — **FastAPI + Supabase/PostgreSQL** backend. Git remote: `github.com/Saadasw/jobeda_02` (pushed).
- `../jobeda-frontend/` — **React + TS + Vite + Mantine** SPA. Git remote: `github.com/Saadasw/jobeda_02_f` (pushed).

## Run
```
# backend (port 8000)
cd jobeda && ./venv/Scripts/python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000
# frontend (port 5173, proxies /api -> backend)
cd jobeda-frontend && npm run dev
```
Open http://localhost:5173 — demo login **owner@jobeda.com / Owner@123 / tenant slug `jobeda`**.

## Supabase / env (CRITICAL)
- Active project: **`lltdojrxjdnwbwowqptb`** (in `.env`, gitignored). A second EMPTY project is commented out (`vaiswiwkxcpdwkbzuoax`). **If you see `relation "tenants" does not exist`, the SQL editor is on the wrong project.**
- jobeda tenant id: `f69c39b1-19ef-4a31-8658-e96d0140517c`.

## Migrations (IMPORTANT)
- The backend only has the Supabase REST client (publishable key) — it **cannot run DDL/arbitrary SQL**. New `migrations/NNN_*.sql` must be **applied by the user in the Supabase SQL editor**; then verify via a read-only probe (`supabase.table(...).select(...)`) or the API.
- `007_seed_data.sql` = full post-migration seed; self-skips if run mid-sequence. Its wipe resets `tenant_counters` for pristine demo numbers.
- Applied through **040** (student identity 038; fee groups/structures 039; created_by UUID fix 040). See `HANDOFF.md §8` for the migration log.

## Backend conventions
- FastAPI routers, **no global prefix**, explicit paths, registered in `main.py`.
- Auth = custom `users` table (NOT Supabase auth). JWT access (~30m) + refresh token (httpOnly cookie on `/auth/login|refresh|logout`, also in body). `dependencies.py`: `get_current_user` (401), `get_tenant_id` (user tenant **or** `X-Tenant-ID` header), `require_roles(*roles)` (403), `get_financial_tenant_id` (owner/admin/accountant, **JWT required** — used on financial writes).
- Multi-tenant: every table has `tenant_id`; every query filters by it.
- DB triggers auto-post tenant-aware double-entry journals (look up accounts by name). Generated columns are read-only — never write them.
- Money = `Decimal`; `float(x)` on insert. **Serialization is inconsistent** — some endpoints return strings (`"10000.0"`), some numbers. Handle both.
- Timestamps = naive UTC ISO: `datetime.now(timezone.utc).replace(tzinfo=None).isoformat()`.
- Error shapes: 422 = `{"detail":[{"loc","msg"}]}`; business = `{"detail":"string"}`.
- Smoke test: `./venv/Scripts/python.exe -c "import main; print(len(main.app.routes))"`.

## Roles
`owner, admin, accountant, teacher, viewer` (global `roles` table, seeded migration 018). One owner per tenant. **Financial writes require owner/admin/accountant.**

## Git
- Commit only when asked; on the default branch, branch first. End commit messages with the `Co-Authored-By: Claude ...` trailer.
- **NEVER commit** `.env` / `.env.example` (real keys) / `.claude/` / `venv/` / `__pycache__`. `.gitignore` covers it — always verify staged files before committing.
