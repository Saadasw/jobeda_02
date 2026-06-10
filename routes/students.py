"""
Students routes — CRUD with soft delete, pagination, and financial sub-endpoints.
"""
import math
from datetime import datetime
from decimal import Decimal
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.student import StudentCreate, StudentUpdate, StudentResponse
from models.payment import StudentFinancialSummary
from models.common import PaginatedResponse

router = APIRouter(prefix="/students", tags=["Students"])


# ─── CRUD ────────────────────────────────────────────────────────────────────

@router.get("")
def list_students(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    class_id: Optional[int] = Query(default=None),
    section_id: Optional[int] = Query(default=None),
    academic_year_id: Optional[int] = Query(default=None),
    status: Optional[str] = Query(default=None, description="Current-enrollment status"),
    has_dues: bool = Query(default=False, description="Only students with outstanding due"),
    search: Optional[str] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """
    List active students with pagination, filters, and financial summary.
    Each row includes the section name + total_fee/total_paid/due/advance/last_payment_date.
    `status` filters by the student's current-year enrollment status; `has_dues`
    keeps only students with an outstanding balance.
    """
    try:
        # Filters that live in other tables -> resolve to a set of student ids.
        # None means "no id restriction".
        allowed_ids = None

        if status:
            enr = (
                supabase.table("student_enrollments").select("student_id")
                .eq("tenant_id", tenant_id).eq("is_current", True).eq("status", status)
                .execute()
            )
            allowed_ids = {r["student_id"] for r in enr.data}

        if has_dues:
            due = (
                supabase.table("student_due_summary").select("id")
                .eq("tenant_id", tenant_id).gt("due", 0).execute()
            )
            due_ids = {r["id"] for r in due.data}
            allowed_ids = due_ids if allowed_ids is None else (allowed_ids & due_ids)

        if allowed_ids is not None and not allowed_ids:
            return {"data": [], "page": page, "limit": limit, "total": 0, "total_pages": 1}

        def _filtered(q):
            q = q.eq("tenant_id", tenant_id).eq("is_deleted", False)
            if class_id:
                q = q.eq("class_id", class_id)
            if section_id:
                q = q.eq("section_id", section_id)
            if academic_year_id:
                q = q.eq("academic_year_id", academic_year_id)
            if search:
                q = q.ilike("name", f"%{search}%")
            if allowed_ids is not None:
                q = q.in_("id", list(allowed_ids))
            return q

        count_resp = _filtered(supabase.table("students").select("id", count="exact")).execute()
        total = count_resp.count if count_resp.count is not None else len(count_resp.data)

        offset = (page - 1) * limit
        students_resp = (
            _filtered(supabase.table("students").select("*"))
            .order("id").range(offset, offset + limit - 1).execute()
        )

        if not students_resp.data:
            return {"data": [], "page": page, "limit": limit, "total": total,
                    "total_pages": math.ceil(total / limit) if total > 0 else 1}

        student_ids = [s["id"] for s in students_resp.data]

        # Financial enrichment (student_due_summary).
        fin_resp = (
            supabase.table("student_due_summary")
            .select("id, total_fee, total_paid, due, advance, last_payment_date")
            .eq("tenant_id", tenant_id).in_("id", student_ids).execute()
        )
        fin_map = {row["id"]: row for row in fin_resp.data}

        # Section-name map (small per tenant).
        sec_resp = supabase.table("sections").select("id, name").eq("tenant_id", tenant_id).execute()
        sec_map = {row["id"]: row["name"] for row in sec_resp.data}

        # Current-enrollment roll map (roll_no lives on the enrollment, not the student row).
        enr_resp = (
            supabase.table("student_enrollments").select("student_id, roll_no")
            .eq("tenant_id", tenant_id).eq("is_current", True)
            .in_("student_id", student_ids).execute()
        )
        roll_map = {r["student_id"]: r["roll_no"] for r in enr_resp.data}

        enriched = []
        for s in students_resp.data:
            fin = fin_map.get(s["id"], {})
            s["total_fee"] = fin.get("total_fee", 0)
            s["total_paid"] = fin.get("total_paid", 0)
            s["due"] = fin.get("due", 0)
            s["advance"] = fin.get("advance", 0)
            s["last_payment_date"] = fin.get("last_payment_date")
            s["section"] = sec_map.get(s.get("section_id"))
            s["roll_no"] = roll_map.get(s["id"])
            enriched.append(s)

        return {"data": enriched, "page": page, "limit": limit, "total": total,
                "total_pages": math.ceil(total / limit) if total > 0 else 1}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=StudentResponse, status_code=201)
def create_student(student: StudentCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new student."""
    try:
        data = {"name": student.name, "tenant_id": tenant_id}
        if student.class_field is not None:
            data["class"] = student.class_field
        if student.class_id is not None:
            data["class_id"] = student.class_id
        if student.section_id is not None:
            data["section_id"] = student.section_id
        if student.academic_year_id is not None:
            data["academic_year_id"] = student.academic_year_id
        for _f in ("admission_date", "date_of_birth", "gender", "address", "guardian_id", "fee_group_id"):
            _v = getattr(student, _f)
            if _v is not None:
                data[_f] = _v

        resp = supabase.table("students").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create student")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{student_id}", response_model=StudentResponse)
def get_student(student_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a specific student by ID."""
    try:
        resp = (
            supabase.table("students")
            .select("*")
            .eq("id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Student not found")
        student = resp.data[0]

        # Enrich section name + current-enrollment roll (parallel to list_students).
        if student.get("section_id"):
            sec = (
                supabase.table("sections").select("name")
                .eq("id", student["section_id"]).eq("tenant_id", tenant_id).limit(1).execute()
            )
            student["section"] = sec.data[0]["name"] if sec.data else None
        enr = (
            supabase.table("student_enrollments").select("roll_no")
            .eq("student_id", student_id).eq("tenant_id", tenant_id).eq("is_current", True)
            .limit(1).execute()
        )
        student["roll_no"] = enr.data[0]["roll_no"] if enr.data else None
        return student
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{student_id}", response_model=StudentResponse)
def update_student(student_id: int, student: StudentUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an existing student."""
    try:
        data = {}
        if student.name is not None:
            data["name"] = student.name
        if student.class_field is not None:
            data["class"] = student.class_field
        if student.class_id is not None:
            data["class_id"] = student.class_id
        if student.section_id is not None:
            data["section_id"] = student.section_id
        if student.academic_year_id is not None:
            data["academic_year_id"] = student.academic_year_id
        for _f in ("admission_date", "date_of_birth", "gender", "address", "guardian_id", "fee_group_id"):
            _v = getattr(student, _f)
            if _v is not None:
                data[_f] = _v

        if not data:
            raise HTTPException(status_code=400, detail="No data provided to update")

        data["updated_at"] = datetime.utcnow().isoformat()

        resp = (
            supabase.table("students")
            .update(data)
            .eq("id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Student not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{student_id}")
def delete_student(student_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete a student (archive, not destroy)."""
    try:
        resp = (
            supabase.table("students")
            .update({
                "is_deleted": True,
                "deleted_at": datetime.utcnow().isoformat(),
            })
            .eq("id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Student not found")
        return {"message": "Student archived successfully", "student_id": student_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── FINANCIAL SUB-ENDPOINTS ────────────────────────────────────────────────

@router.get("/{student_id}/summary", response_model=StudentFinancialSummary)
def get_student_summary(student_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Financial summary: total fees assigned, total paid, due, and advance.
    Uses the student_due_summary PostgreSQL view — single query, no N+1.
    """
    try:
        resp = (
            supabase.table("student_due_summary")
            .select("*")
            .eq("id", student_id)
            .eq("tenant_id", tenant_id)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Student not found")

        row = resp.data[0]
        return StudentFinancialSummary(
            student_id=row["id"],
            student_name=row["name"],
            total_fee=Decimal(str(row["total_fee"])),
            total_paid=Decimal(str(row["total_paid"])),
            due=Decimal(str(row["due"])),
            advance=Decimal(str(row["advance"])),
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{student_id}/fees")
def get_student_fees(
    student_id: int,
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List fee assignments for a student (paginated)."""
    try:
        offset = (page - 1) * limit
        resp = (
            supabase.table("fee_assignments")
            .select("*")
            .eq("student_id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .order("month", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{student_id}/payments")
def get_student_payments(
    student_id: int,
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    method: Optional[str] = Query(default=None),
    status: Optional[str] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """Payment history for a student — paginated, filterable by date range / method / status."""
    try:
        offset = (page - 1) * limit
        query = (
            supabase.table("payments").select("*")
            .eq("student_id", student_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
        )
        if from_date:
            query = query.gte("date", from_date)
        if to_date:
            query = query.lte("date", to_date)
        if method:
            query = query.eq("method", method)
        if status:
            query = query.eq("status", status)
        resp = query.order("date", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{student_id}/ledger")
def get_student_ledger(student_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Full accounting view for a student.
    Shows all journal entries related to this student's payments and fees.
    """
    try:
        # Get all journal entries referencing this student
        # Journals are linked via description (contains student_id)
        # A more robust approach would use reference_type/reference_id
        fees_resp = (
            supabase.table("fee_assignments")
            .select("id, month, amount")
            .eq("student_id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .order("month")
            .execute()
        )
        payments_resp = (
            supabase.table("payments")
            .select("id, date, amount, method, receipt_no, status")
            .eq("student_id", student_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .order("date")
            .execute()
        )
        allocations_data = []
        for p in payments_resp.data:
            alloc_resp = (
                supabase.table("payment_allocations")
                .select("*")
                .eq("payment_id", p["id"])
                .eq("tenant_id", tenant_id)
                .execute()
            )
            allocations_data.extend(alloc_resp.data)

        return {
            "student_id": student_id,
            "fees": fees_resp.data,
            "payments": payments_resp.data,
            "allocations": allocations_data,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
