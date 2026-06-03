# Changes Log — plan.md Updates

> **Date:** 2026-05-08  
> **Reason:** Production-grade improvements based on architectural review  
> **Impact:** 13 changes across schema, models, endpoints, and design principles

---

## Summary of Changes

| # | Change | Severity | Area |
|---|--------|----------|------|
| 1 | Decimal for money | 🔥 Critical | Models |
| 2 | Transaction safety | 🔥 Critical | Architecture |
| 3 | Soft delete | 🔥 Critical | Schema + API |
| 4 | Academic structure | 🔥 Critical | Schema + API |
| 5 | Unique constraints | 🔥 Critical | Schema |
| 6 | Status columns | 🔥 Important | Schema |
| 7 | Audit fields | 🔥 Important | Schema |
| 8 | Journal reversal | 🔥 Important | API + Schema |
| 9 | Date-filtered reports | ⚡ Important | API |
| 10 | Pagination | ⚡ Important | API |
| 11 | Allocation routing | ⚡ Architecture | API |
| 12 | Receipt numbers | ⚡ Feature | Schema + API |
| 13 | Cash account support | ⚡ Future-proof | Schema |

---

## Detailed Changes

### 🔥 1. Decimal for Money (NOT float)

**Before:**
```python
salary: float | None = None
```

**After:**
```python
from decimal import Decimal
salary: Decimal | None = None
amount: Decimal | None = None
```

**Why:** `0.1 + 0.2 != 0.3` in floating point. This causes real accounting errors in production. All monetary fields across all models now use `Decimal`.

**Files affected:** All Pydantic models (`employee.py`, `payment.py`, `fee.py`, `salary.py`, `expense.py`, `income.py`, `report.py`)

---

### 🔥 2. Transaction Safety

**Before:**
```
POST /payments         → step 1
POST /allocate         → step 2 (if this fails, step 1 already committed!)
POST /finalize         → step 3
```

**After:**
```python
async with db.transaction():
    create_payment()
    allocate()
    finalize()
    # If ANY step fails → entire transaction rolls back
```

**Why:** Without transactions, a failure mid-flow creates orphan records and inconsistent accounting state. This is the #1 cause of financial data corruption.

**Affected flows:** Payment creation, salary payment, expense deletion (reversal)

---

### 🔥 3. Soft Delete Instead of Hard Delete

**Before:**
```python
# DELETE /students/{id} → actually removes row from DB
supabase.table('students').delete().eq('id', student_id).execute()
```

**After:**
```python
# DELETE /students/{id} → archives the record
supabase.table('students').update({
    "is_deleted": True,
    "deleted_at": datetime.now().isoformat()
}).eq('id', student_id).execute()
```

**Schema additions on ALL major tables:**
```sql
is_deleted BOOLEAN DEFAULT FALSE
deleted_at TIMESTAMP NULL
```

**All GET endpoints now filter:** `WHERE is_deleted = FALSE`

**Affected tables:** `students`, `employees`, `fee_assignments`, `payments`, `expenses`, `salary_payments`, `accounts`, `fee_types`

---

### 🔥 4. Academic Structure (NEW Tables + Endpoints)

**Added 3 new tables:**

```sql
academic_years (id, name, start_date, end_date, is_current)
classes        (id, name)
sections       (id, class_id, name)
```

**Updated `students` table:**
```sql
ALTER TABLE students ADD COLUMN class_id INT REFERENCES classes(id);
ALTER TABLE students ADD COLUMN section_id INT REFERENCES sections(id);
ALTER TABLE students ADD COLUMN academic_year_id INT REFERENCES academic_years(id);
```

**Added 8 new endpoints:**

| Method | Endpoint |
|--------|----------|
| `GET` | `/classes` |
| `POST` | `/classes` |
| `PUT` | `/classes/{id}` |
| `GET` | `/sections` |
| `POST` | `/sections` |
| `GET` | `/academic-years` |
| `POST` | `/academic-years` |
| `PUT` | `/academic-years/{id}` |

**Why:** Without this, you can't filter students by class, generate class-wise reports, or handle year-end promotions. Adding this later requires painful migrations.

---

### 🔥 5. Unique Constraints

**Added:**
```sql
UNIQUE (student_id, fee_type_id, month)
```

**Why:** Prevents accidental duplicate fee assignments (e.g., May Tuition inserted twice). Without this, financial data gets silently corrupted.

---

### 🔥 6. Status Columns

**Added to `payments`:**
```sql
status TEXT DEFAULT 'completed'
CHECK (status IN ('pending', 'completed', 'cancelled', 'refunded'))
```

**Added to `journal_entries`:**
```sql
is_reversed BOOLEAN DEFAULT FALSE
```

**Why:** Enables payment lifecycle management (cancel, refund) and journal integrity tracking.

---

### 🔥 7. Audit Fields Everywhere

**Added to ALL major tables:**
```sql
created_at  TIMESTAMP DEFAULT NOW()   -- (already existed)
created_by  TEXT NULL
updated_at  TIMESTAMP NULL
updated_by  TEXT NULL
```

**Why:** Essential for accountability. "Who changed this record and when?" is the most common audit question in financial systems.

---

### 🔥 8. Journal Reversal System

**Before:** `DELETE /expenses/{id}` → hard delete (dangerous, breaks accounting)

**After:**
1. Soft-delete the original record
2. Create a **reversal journal entry** (swaps Dr/Cr)
3. Mark original journal as `is_reversed = TRUE`

**New endpoint:**

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/journal/{id}/reverse` | Creates reversal entry |

**Example:**
```
Original:  Dr Expense 5000 / Cr Cash 5000
Reversal:  Dr Cash 5000 / Cr Expense 5000
```

---

### ⚡ 9. Date-Filtered Reports

**Before:**
```
GET /reports/trial-balance     → returns ALL TIME data
```

**After:**
```
GET /reports/trial-balance?from=2026-01-01&to=2026-12-31
```

**Applied to:** All 6 report endpoints (trial-balance, income-statement, balance-sheet, ledger, students-due, dashboard)

**SQL change:**
```sql
WHERE je.date BETWEEN :from_date AND :to_date
  AND je.is_reversed = FALSE
```

---

### ⚡ 10. Pagination on All List Endpoints

**Before:** All list endpoints return unlimited rows.

**After:** All list endpoints support:
```
GET /payments?page=1&limit=50
GET /students?page=2&limit=25
```

**Common model added:**
```python
class PaginationParams(BaseModel):
    page: int = 1
    limit: int = 50
```

**Applied to:** `/students`, `/employees`, `/payments`, `/fees`, `/expenses`, `/salary/history`, `/income`, `/journal`, `/reports/students-due`

---

### ⚡ 11. Allocation Moved from Utils to Payments

**Before:**
```
POST /utils/auto-allocate/{payment_id}
```

**After:**
```
POST /payments/{id}/allocate
```

**Why:** Allocation is payment-domain logic, not a utility. This makes the API more RESTful and discoverable. The `/utils/` prefix was removed entirely — `finalize` moved to `/payments/{id}/finalize`.

---

### ⚡ 12. Receipt Numbers

**Added to `payments`:**
```sql
receipt_no TEXT UNIQUE
```

**Format:** `PAY-2026-0001` (auto-generated via sequence)

```sql
CREATE SEQUENCE receipt_seq START 1;
```

**Why:** Real-world requirement for printed receipts, reference in conversations, and legal compliance.

---

### ⚡ 13. Cash Account Support (Future-Proofing)

**Before:** Payment method was just an enum (`cash` / `bank`)

**After:** Added `cash_account_id` to payments:
```sql
ALTER TABLE payments ADD COLUMN cash_account_id INT REFERENCES accounts(id);
```

**Why:** Enables multiple cash boxes, bank accounts, and mobile banking in the future without schema changes. The `method` enum still exists for backward compatibility.

---

## Impact on Endpoint Count

| Metric | Before | After |
|--------|--------|-------|
| Total endpoints | ~49 | ~57 |
| Modules | 13 | 14 (+Academic) |
| New tables | 0 | 3 (academic_years, classes, sections) |
| Schema migrations needed | 0 | 5 |

## New Phase Added

**Phase 0 — Schema Hardening** was added before Phase 1. All 5 migrations must run before any API work begins.

## Removed

- `/utils/auto-allocate/{payment_id}` → merged into `/payments/{id}/allocate`
- `/utils/finalize-payment/{payment_id}` → moved to `/payments/{id}/finalize`
- The entire `/utils/` route module is no longer needed
