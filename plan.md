# Jobeda Madrasa ERP — API Implementation Plan

> **Tech Stack:** FastAPI + Supabase (PostgreSQL) + Pydantic  
> **Target:** ~52 endpoints across 14 modules  
> **Architecture:** RESTful, trigger-driven double-entry accounting

---

## Design Principles

| Principle | Rule |
|---|---|
| **RESTful URLs** | Predictable, resource-based paths (`/students`, `/payments/{id}/allocate`) |
| **No frontend logic** | All allocation, journaling, and financial math happens server-side |
| **Accounting is invisible** | Users interact with fees/payments — journals are created automatically by DB triggers |
| **Validation first** | Pydantic models enforce all constraints before hitting the DB |
| **Decimal for money** | All monetary fields use `Decimal` — never `float` |
| **Soft delete** | Records are archived, never hard-deleted — preserves audit trail |
| **Transactional integrity** | Multi-step operations wrapped in DB transactions |
| **Pagination everywhere** | All list endpoints support `?page=1&limit=50` |
| **Date-filtered reports** | All reports accept `?from=` and `?to=` date parameters |
| **Audit fields** | `created_at`, `created_by`, `updated_at`, `updated_by` on all tables |

---

## Pre-Implementation: Schema Migrations

> 🔴 **DO THESE BEFORE WRITING ANY CODE**

### Migration 1: Academic Structure

```sql
CREATE TABLE academic_years (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,           -- e.g. "2026"
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    is_current BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE classes (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,           -- e.g. "Hifz-1", "Nazera-3"
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE sections (
    id SERIAL PRIMARY KEY,
    class_id INT NOT NULL REFERENCES classes(id),
    name TEXT NOT NULL,           -- e.g. "A", "B"
    created_at TIMESTAMP DEFAULT NOW()
);
```

### Migration 2: Update `students` Table

```sql
ALTER TABLE students
ADD COLUMN class_id INT REFERENCES classes(id),
ADD COLUMN section_id INT REFERENCES sections(id),
ADD COLUMN academic_year_id INT REFERENCES academic_years(id),
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN updated_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL,
ADD COLUMN updated_by TEXT NULL;
```

### Migration 3: Soft Delete & Audit Fields on All Tables

```sql
-- employees
ALTER TABLE employees
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN updated_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL,
ADD COLUMN updated_by TEXT NULL;

-- fee_assignments
ALTER TABLE fee_assignments
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL;

-- payments
ALTER TABLE payments
ADD COLUMN status TEXT DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'cancelled', 'refunded')),
ADD COLUMN receipt_no TEXT UNIQUE,
ADD COLUMN cash_account_id INT REFERENCES accounts(id),
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL;

-- expenses
ALTER TABLE expenses
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL;

-- salary_payments
ALTER TABLE salary_payments
ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE,
ADD COLUMN deleted_at TIMESTAMP NULL,
ADD COLUMN created_by TEXT NULL;

-- journal_entries
ALTER TABLE journal_entries
ADD COLUMN is_reversed BOOLEAN DEFAULT FALSE;
```

### Migration 4: Unique Constraints

```sql
ALTER TABLE fee_assignments
ADD CONSTRAINT uq_fee_per_student_per_month
UNIQUE (student_id, fee_type_id, month);
```

### Migration 5: Receipt Number Sequence

```sql
CREATE SEQUENCE receipt_seq START 1;

-- Use in application:
-- receipt_no = f"PAY-{year}-{next_val:04d}"
```

---

## Implementation Phases

### Phase 0 — Schema Hardening (NEW)
> Priority: 🔴 CRITICAL — Do before any API work

- [ ] Run all 5 schema migrations above
- [ ] Verify constraints work (test duplicate fee insert → should fail)
- [ ] Verify soft delete columns exist on all tables
- [ ] Seed academic_years, classes, sections with test data

---

### Phase 1 — Foundation & Core CRUD
> Priority: 🔴 Critical — Everything depends on these

#### 1.1 Project Structure Refactor

```
jobeda/
├── main.py                  # FastAPI app + router registration
├── database.py              # Supabase client init
├── models/                  # Pydantic schemas
│   ├── common.py            # Pagination, audit mixins
│   ├── student.py
│   ├── employee.py
│   ├── account.py
│   ├── fee.py
│   ├── payment.py
│   ├── expense.py
│   ├── income.py
│   ├── salary.py
│   ├── academic.py          # classes, sections, academic_years
│   └── report.py
├── routes/                  # API routers
│   ├── auth.py
│   ├── students.py
│   ├── employees.py
│   ├── accounts.py
│   ├── academic.py          # classes, sections, academic_years
│   ├── fees.py
│   ├── payments.py
│   ├── expenses.py
│   ├── income.py
│   ├── salary.py
│   ├── reports.py
│   └── journal.py
├── services/                # Business logic
│   ├── allocation.py
│   ├── finalization.py
│   ├── receipt.py           # Receipt number generation
│   └── reports.py
├── .env
├── requirements.txt
└── plan.md
```

#### 1.2 Common Models (NEW)

```python
from decimal import Decimal
from pydantic import BaseModel

class PaginationParams(BaseModel):
    page: int = 1
    limit: int = 50

class AuditMixin(BaseModel):
    created_at: str | None = None
    created_by: str | None = None
    updated_at: str | None = None
    updated_by: str | None = None
```

#### 1.3 Module: Auth
> Supabase handles auth mostly — we just need a "who am I" endpoint.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/me` | Returns current user info from Supabase auth |

#### 1.4 Module: Academic Structure (NEW)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/classes` | List all classes |
| `POST` | `/classes` | Create class |
| `PUT` | `/classes/{id}` | Update class |
| `GET` | `/sections` | List sections (filter by `?class_id=`) |
| `POST` | `/sections` | Create section |
| `GET` | `/academic-years` | List academic years |
| `POST` | `/academic-years` | Create academic year |
| `PUT` | `/academic-years/{id}` | Update / set current year |

#### 1.5 Module: Students (✅ Partially done — needs updates)

| Method | Endpoint | Description | Status |
|--------|----------|-------------|--------|
| `GET` | `/students` | List all students (paginated, filter by class/section) | 🔄 Update |
| `POST` | `/students` | Create a student (with class_id, section_id, academic_year_id) | 🔄 Update |
| `GET` | `/students/{id}` | Get student by ID | ✅ Done |
| `PUT` | `/students/{id}` | Update student | 🔄 Update |
| `DELETE` | `/students/{id}` | **Soft delete** (set is_deleted=true) | 🔄 Update |

**Updated Pydantic Model:**
```python
from decimal import Decimal

class StudentCreate(BaseModel):
    name: str
    class_name: str | None = Field(default=None, alias="class")
    class_id: int | None = None
    section_id: int | None = None
    academic_year_id: int | None = None

class StudentUpdate(BaseModel):
    name: str | None = None
    class_name: str | None = Field(default=None, alias="class")
    class_id: int | None = None
    section_id: int | None = None
    is_active: bool | None = None   # soft-delete via is_deleted handled by DELETE
```

#### 1.6 Module: Employees

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/employees` | List all employees (paginated) |
| `POST` | `/employees` | Create employee (teacher/staff/admin) |
| `GET` | `/employees/{id}` | Get employee by ID |
| `PUT` | `/employees/{id}` | Update employee |
| `DELETE` | `/employees/{id}` | **Soft delete** |

**Pydantic Model:**
```python
from decimal import Decimal

class EmployeeCreate(BaseModel):
    name: str
    role: str          # teacher / staff / admin
    phone: str | None = None
    salary: Decimal | None = None       # ✅ Decimal, not float

class EmployeeUpdate(BaseModel):
    name: str | None = None
    role: str | None = None
    phone: str | None = None
    salary: Decimal | None = None       # ✅ Decimal, not float
    is_active: bool | None = None
```

#### 1.7 Module: Accounts (Chart of Accounts)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/accounts` | List all accounts (tree-capable) |
| `POST` | `/accounts` | Create account |
| `PUT` | `/accounts/{id}` | Update account |
| `DELETE` | `/accounts/{id}` | **Soft delete** |

**Pydantic Model:**
```python
class AccountCreate(BaseModel):
    name: str
    type: str          # asset / liability / equity / revenue / expense
    parent_id: int | None = None

class AccountUpdate(BaseModel):
    name: str | None = None
    type: str | None = None
    parent_id: int | None = None
    is_active: bool | None = None
```

---

### Phase 2 — Fee System & Payments
> Priority: 🔴 Critical — Core business flow

#### 2.1 Module: Fee Types

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/fee-types` | List all fee types |
| `POST` | `/fee-types` | Create fee type |
| `PUT` | `/fee-types/{id}` | Update fee type |
| `DELETE` | `/fee-types/{id}` | **Soft delete** |

**Pydantic Model:**
```python
class FeeTypeCreate(BaseModel):
    name: str
    is_recurring: bool
    account_id: int
```

#### 2.2 Module: Fee Assignment

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/fees/assign` | Assign a fee to a student for a month |
| `GET` | `/fees` | List fees (filterable by `student_id`, `month`, paginated) |
| `DELETE` | `/fees/{id}` | **Soft delete** + create reversal journal entry |

**Request Body for `/fees/assign`:**
```json
{
  "student_id": 1,
  "fee_type_id": 1,
  "month": "2026-05-01",
  "amount": "2000.00"
}
```

> **⚠️ TRIGGER:** Inserting into `fee_assignments` fires `trg_fee_assignment_journal()` which auto-creates:
> - **Dr** Accounts Receivable
> - **Cr** Tuition Fees
>
> **🔒 CONSTRAINT:** `UNIQUE(student_id, fee_type_id, month)` prevents duplicate assignments.

#### 2.3 Module: Payments (⚡ CRITICAL)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/payments` | Record a student payment (wrapped in transaction) |
| `GET` | `/payments` | List all payments (paginated, filter by `student_id`, `status`) |
| `GET` | `/payments/{id}` | Get payment details with allocations |
| `POST` | `/payments/{id}/allocate` | Auto-allocate payment against outstanding fees |

**Request Body for `POST /payments`:**
```json
{
  "student_id": 1,
  "amount": "3000.00",
  "date": "2026-05-02",
  "method": "cash",
  "cash_account_id": 5
}
```

> **Response includes auto-generated `receipt_no`:** `"PAY-2026-0001"`

**Manual Allocation (optional):**

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/payment-allocations` | Manually allocate payment to specific fee |

> **⚡ PAYMENT FLOW (transactional):**
> All steps run inside a single DB transaction:
> 1. Insert payment → generate `receipt_no`
> 2. Auto-allocate against oldest unpaid fees
> 3. Remaining → Unearned Revenue
> 4. If any step fails → entire transaction rolls back

#### 2.4 Student Financial Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/students/{id}/summary` | Total fee, paid, due, advance |
| `GET` | `/students/{id}/fees` | List of fee assignments (paginated) |
| `GET` | `/students/{id}/payments` | Payment history (paginated) |
| `GET` | `/students/{id}/ledger` | Full accounting view (advanced) |

**Response for `/students/{id}/summary`:**
```json
{
  "student_id": 1,
  "student_name": "Ahmed",
  "total_fee": "10000.00",
  "total_paid": "7000.00",
  "due": "3000.00",
  "advance": "0.00"
}
```

---

### Phase 3 — Salary, Expenses & Income
> Priority: 🟡 High

#### 3.1 Module: Salary

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/salary/pay` | Pay salary to an employee (transactional) |
| `GET` | `/salary/history` | List all salary payments (paginated, filter by `employee_id`) |

**Request Body:**
```json
{
  "employee_id": 2,
  "amount": "15000.00",
  "date": "2026-05-05"
}
```

> Trigger: `trg_salary_journal()` → **Dr** Salary Expense / **Cr** Cash

#### 3.2 Module: Expenses

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/expenses` | Record an expense |
| `GET` | `/expenses` | List all expenses (paginated, filter by `account_id`, date range) |
| `GET` | `/expenses/{id}` | Get expense details |
| `DELETE` | `/expenses/{id}` | **Soft delete** + reversal journal |

**Request Body:**
```json
{
  "account_id": 41,
  "amount": "5000.00",
  "date": "2026-05-06",
  "description": "Boarding expense"
}
```

> **TRIGGER:** `trg_expense_journal()` → **Dr** Expense Account / **Cr** Cash
>
> **On DELETE:** Creates a reversal entry (**Dr** Cash / **Cr** Expense) instead of hard delete.

#### 3.3 Module: Income (Non-student)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/income` | Record non-student income (donation, zakat, mahfil) |
| `GET` | `/income` | List all income records (paginated) |

> **TRIGGER:** `trg_income_journal()` → **Dr** Cash / **Cr** Income Account

---

### Phase 4 — Reports & Dashboard
> Priority: 🟡 High — What makes this an ERP

#### 4.1 Module: Reports

All report endpoints support date filtering: `?from=2026-01-01&to=2026-12-31`

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/reports/trial-balance` | Trial balance across all accounts |
| `GET` | `/reports/income-statement` | Revenue vs Expenses summary |
| `GET` | `/reports/balance-sheet` | Assets = Liabilities + Equity |
| `GET` | `/reports/ledger` | Account ledger (`?account_id=1&from=&to=`) |
| `GET` | `/reports/students-due` | All students with outstanding balances (paginated) |
| `GET` | `/reports/dashboard` | High-level financial summary |

**Response for `/reports/dashboard`:**
```json
{
  "period": { "from": "2026-01-01", "to": "2026-12-31" },
  "total_income": "500000.00",
  "total_expense": "320000.00",
  "total_due": "45000.00",
  "total_collected": "455000.00"
}
```

**Report Query Logic (via `journal_lines`):**
```sql
-- Trial Balance (with date filter)
SELECT a.name, a.type,
       SUM(jl.debit) as total_debit,
       SUM(jl.credit) as total_credit
FROM journal_lines jl
JOIN accounts a ON jl.account_id = a.id
JOIN journal_entries je ON jl.journal_id = je.id
WHERE je.date BETWEEN :from_date AND :to_date
  AND je.is_reversed = FALSE
GROUP BY a.id, a.name, a.type;

-- Income Statement
-- Filter accounts WHERE type IN ('revenue', 'expense')

-- Balance Sheet
-- Filter accounts WHERE type IN ('asset', 'liability', 'equity')
```

---

### Phase 5 — Journal & Reversal System
> Priority: 🟢 Enhancement

#### 5.1 Module: Journal (Read-Only + Reversal)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/journal` | List all journal entries (paginated) |
| `GET` | `/journal/{id}` | Get journal entry with lines |
| `POST` | `/journal/{id}/reverse` | Create a reversal entry (swaps Dr/Cr) |

> **🚨 CAUTION:** Journal entries are **read-only** except for reversal. They are created exclusively by database triggers. Never expose update/delete.

**Reversal Logic:**
```
Original:  Dr Expense 5000 / Cr Cash 5000
Reversal:  Dr Cash 5000 / Cr Expense 5000
           + mark original as is_reversed = TRUE
```

#### 5.2 Finalize Payment

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/payments/{id}/finalize` | Handle advance/remaining as Unearned Revenue |

> **Note:** Auto-allocation moved from `/utils/` to `/payments/{id}/allocate` (Phase 2) — it belongs in the payment domain.

---

## Ideal Business Flows

### 🧾 Collect Fee from Student (Transactional)

```
Client → POST /payments
  ┌─ BEGIN TRANSACTION ─────────────────────────────┐
  │  1. INSERT payment → generate receipt_no         │
  │  2. Auto-allocate against unpaid fees            │
  │     → TRIGGER: journal (Dr Cash / Cr AR)         │
  │  3. Remaining → finalize                         │
  │     → journal (Dr Cash / Cr Unearned Revenue)    │
  │  4. If ANY step fails → ROLLBACK                 │
  └─────────────────────────────────────────────────┘
Client ← { payment, receipt_no, allocated, advance }
```

### 📝 Assign Fee

```
Client → POST /fees/assign                 → Insert into fee_assignments
  UNIQUE constraint check → prevent duplicates
  DB TRIGGER → journal entry (Dr Accounts Receivable / Cr Tuition Fees)
Client ← { fee_assignment }
```

### 💸 Record Expense

```
Client → POST /expenses                    → Insert into expenses
  DB TRIGGER → journal entry (Dr Expense Account / Cr Cash)
Client ← { expense }
```

### 🗑️ Delete Expense (Soft Delete + Reversal)

```
Client → DELETE /expenses/{id}
  1. Set is_deleted = TRUE, deleted_at = NOW()
  2. Create reversal journal (Dr Cash / Cr Expense)
  3. Mark original journal as is_reversed = TRUE
Client ← { message: "Expense reversed and archived" }
```

---

## Implementation Checklist

### Phase 0 — Schema Hardening 🔴
- [ ] Run Migration 1: Academic structure tables
- [ ] Run Migration 2: Update students table
- [ ] Run Migration 3: Soft delete + audit fields on all tables
- [ ] Run Migration 4: Unique constraints
- [ ] Run Migration 5: Receipt number sequence
- [ ] Seed test data for classes, sections, academic years
- [ ] Verify UNIQUE constraint blocks duplicate fee assignments

### Phase 1 — Foundation & Core CRUD
- [ ] Refactor project into modular structure (`routes/`, `models/`, `services/`)
- [ ] Create `database.py` (extract Supabase client)
- [ ] Create `models/common.py` (Pagination, AuditMixin)
- [ ] Implement `GET /me`
- [ ] Implement Academic CRUD (classes, sections, academic_years)
- [ ] Update Students CRUD (add class_id, section_id, soft delete, pagination)
- [ ] Implement Employees CRUD (Decimal salary, soft delete, pagination)
- [ ] Implement Accounts CRUD (soft delete)

### Phase 2 — Fee System & Payments
- [ ] Implement Fee Types CRUD (soft delete)
- [ ] Implement `POST /fees/assign` (with unique constraint validation)
- [ ] Implement `GET /fees` with query filters + pagination
- [ ] Implement `DELETE /fees/{id}` (soft delete + reversal journal)
- [ ] Implement `POST /payments` (transactional, receipt_no generation)
- [ ] Implement `GET /payments` and `GET /payments/{id}` (paginated)
- [ ] Implement `POST /payments/{id}/allocate` (auto-allocation)
- [ ] Implement `POST /payment-allocations` (manual)
- [ ] Implement `GET /students/{id}/summary`
- [ ] Implement `GET /students/{id}/fees`
- [ ] Implement `GET /students/{id}/payments`
- [ ] Implement `GET /students/{id}/ledger`

### Phase 3 — Salary, Expenses & Income
- [ ] Implement `POST /salary/pay` (transactional)
- [ ] Implement `GET /salary/history` (paginated)
- [ ] Implement Expenses CRUD (soft delete + reversal)
- [ ] Implement Income endpoints (paginated)

### Phase 4 — Reports & Dashboard
- [ ] Implement `GET /reports/trial-balance` (date-filtered)
- [ ] Implement `GET /reports/income-statement` (date-filtered)
- [ ] Implement `GET /reports/balance-sheet` (date-filtered)
- [ ] Implement `GET /reports/ledger` (date-filtered)
- [ ] Implement `GET /reports/students-due` (paginated)
- [ ] Implement `GET /reports/dashboard` (date-filtered)

### Phase 5 — Journal & Reversal
- [ ] Implement `GET /journal` and `GET /journal/{id}` (paginated)
- [ ] Implement `POST /journal/{id}/reverse`
- [ ] Implement `POST /payments/{id}/finalize`

---

## Endpoint Summary

| Module | Endpoints | Priority |
|--------|-----------|----------|
| Auth | 1 | 🔴 |
| Academic | 8 (classes, sections, years) | 🔴 |
| Students | 9 (5 CRUD + 4 financial) | 🔴 |
| Employees | 5 | 🔴 |
| Accounts | 4 | 🔴 |
| Fee Types | 4 | 🔴 |
| Fee Assignment | 3 | 🔴 |
| Payments | 5 | 🔴 |
| Salary | 2 | 🟡 |
| Expenses | 4 | 🟡 |
| Income | 2 | 🟡 |
| Reports | 6 | 🟡 |
| Journal | 3 (read + reverse) | 🟢 |
| Finalize | 1 | 🟢 |
| **Total** | **~57** | |
