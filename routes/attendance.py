"""
Attendance routes — daily student & staff attendance, monthly summaries, and
the bridge that pushes a month's staff attendance into a draft payslip.

Tenant safety: the DB triggers reject cross-tenant rows, but we pre-validate
student/employee ownership for clean 404s. The summary + payslip RPCs are
tenant-unaware, so the caller's tenant is passed (summaries) or the referenced
payslip is checked to belong to the tenant (apply-attendance) before invoking.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, get_current_user_optional
from models.attendance import (
    StudentAttendanceCreate, StudentAttendanceUpdate, StudentAttendanceResponse,
    StudentAttendanceBulkCreate,
    StaffAttendanceCreate, StaffAttendanceUpdate, StaffAttendanceResponse,
    StaffAttendanceBulkCreate,
)

router = APIRouter(tags=["Attendance"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _uid(user: Optional[dict]) -> Optional[str]:
    """The acting user's id, or None when resolved via the X-Tenant-ID header."""
    return user["id"] if user else None


def _assert_student(tenant_id: str, student_id: int) -> None:
    resp = (
        supabase.table("students").select("id")
        .eq("id", student_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=404, detail="Student not found")


def _assert_employee(tenant_id: str, employee_id: int) -> None:
    resp = (
        supabase.table("employees").select("id")
        .eq("id", employee_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=404, detail="Employee not found")


def _map_error(detail: str) -> HTTPException:
    """Translate DB errors: unique → 409, tenant/CHECK → 400, else 500."""
    low = detail.lower()
    if any(k in low for k in ("duplicate", "unique", "uq_", "already exists")):
        return HTTPException(status_code=409, detail="Attendance already marked for this date")
    if any(k in low for k in ("forbidden", "not found", "check constraint", "violates")):
        return HTTPException(status_code=400, detail=detail)
    return HTTPException(status_code=500, detail=detail)


# ════════════════════════════════════════════════════════════════════════════
#  STUDENT ATTENDANCE
# ════════════════════════════════════════════════════════════════════════════

@router.post("/student-attendance", response_model=StudentAttendanceResponse, status_code=201)
def mark_student_attendance(
    payload: StudentAttendanceCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Mark a single student's attendance for a date. UNIQUE(student, date)."""
    try:
        _assert_student(tenant_id, payload.student_id)
        data = {
            "tenant_id": tenant_id,
            "student_id": payload.student_id,
            "date": payload.date,
            "status": payload.status,
        }
        for field in ("check_in_time", "check_out_time", "remarks"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        uid = _uid(user)
        if uid:
            data["marked_by_id"] = uid

        resp = supabase.table("student_attendance").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to mark attendance")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.post("/student-attendance/bulk", status_code=201)
def bulk_mark_student_attendance(
    payload: StudentAttendanceBulkCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """
    Mark/Update many students for one date in a single call. Re-marking a
    (student, date) overwrites the prior row (upsert on the unique key).
    """
    try:
        if not payload.records:
            raise HTTPException(status_code=400, detail="No records provided")

        ids = list({r.student_id for r in payload.records})
        got = (
            supabase.table("students").select("id")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
            .in_("id", ids).execute()
        )
        found = {row["id"] for row in got.data}
        missing = [i for i in ids if i not in found]
        if missing:
            raise HTTPException(status_code=400, detail=f"Students not in tenant: {missing}")

        uid = _uid(user)
        rows = []
        for r in payload.records:
            row = {
                "tenant_id": tenant_id,
                "student_id": r.student_id,
                "date": payload.date,
                "status": r.status,
            }
            for field in ("check_in_time", "check_out_time", "remarks"):
                val = getattr(r, field)
                if val is not None:
                    row[field] = val
            if uid:
                row["marked_by_id"] = uid
            rows.append(row)

        resp = (
            supabase.table("student_attendance")
            .upsert(rows, on_conflict="student_id,date")
            .execute()
        )
        return {"marked": len(resp.data), "records": resp.data}
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.get("/student-attendance/summary")
def student_attendance_summary(
    year: int = Query(..., ge=2000, le=2100),
    month: int = Query(..., ge=1, le=12),
    class_id: Optional[int] = Query(default=None),
    section_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """Per-student monthly attendance counts and attendance %."""
    try:
        params = {"p_tenant_id": tenant_id, "p_year": year, "p_month": month}
        if class_id is not None:
            params["p_class_id"] = class_id
        if section_id is not None:
            params["p_section_id"] = section_id
        resp = supabase.rpc("get_student_attendance_summary", params).execute()
        return {"year": year, "month": month, "rows": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/student-attendance", response_model=List[StudentAttendanceResponse])
def list_student_attendance(
    student_id: Optional[int] = Query(default=None),
    date: Optional[str] = Query(default=None, description="Exact ISO date"),
    date_from: Optional[str] = Query(default=None),
    date_to: Optional[str] = Query(default=None),
    status: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List student attendance rows with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("student_attendance").select("*").eq("tenant_id", tenant_id)
        if student_id is not None:
            query = query.eq("student_id", student_id)
        if date is not None:
            query = query.eq("date", date)
        if date_from is not None:
            query = query.gte("date", date_from)
        if date_to is not None:
            query = query.lte("date", date_to)
        if status is not None:
            query = query.eq("status", status)
        resp = (
            query.order("date", desc=True).order("student_id")
            .range(offset, offset + limit - 1).execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/student-attendance/{record_id}", response_model=StudentAttendanceResponse)
def get_student_attendance(record_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single student attendance row."""
    try:
        resp = (
            supabase.table("student_attendance").select("*")
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/student-attendance/{record_id}", response_model=StudentAttendanceResponse)
def update_student_attendance(
    record_id: int,
    payload: StudentAttendanceUpdate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Update a student attendance row (status / times / remarks)."""
    try:
        data = {}
        for field in ("status", "check_in_time", "check_out_time", "remarks"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        data["updated_at"] = _now_iso()
        uid = _uid(user)
        if uid:
            data["updated_by_id"] = uid

        resp = (
            supabase.table("student_attendance").update(data)
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.delete("/student-attendance/{record_id}")
def delete_student_attendance(record_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete a student attendance row (hard delete — no soft-delete column)."""
    try:
        resp = (
            supabase.table("student_attendance").delete()
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return {"message": "Attendance record removed", "record_id": record_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ════════════════════════════════════════════════════════════════════════════
#  STAFF ATTENDANCE
# ════════════════════════════════════════════════════════════════════════════

@router.post("/staff-attendance", response_model=StaffAttendanceResponse, status_code=201)
def mark_staff_attendance(
    payload: StaffAttendanceCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Mark a single employee's attendance for a date. UNIQUE(employee, date)."""
    try:
        _assert_employee(tenant_id, payload.employee_id)
        data = {
            "tenant_id": tenant_id,
            "employee_id": payload.employee_id,
            "date": payload.date,
            "status": payload.status,
        }
        for field in ("leave_type", "check_in_time", "check_out_time", "remarks"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        uid = _uid(user)
        if uid:
            data["marked_by_id"] = uid

        resp = supabase.table("staff_attendance").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to mark attendance")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.post("/staff-attendance/bulk", status_code=201)
def bulk_mark_staff_attendance(
    payload: StaffAttendanceBulkCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Mark/Update many employees for one date (upsert on the unique key)."""
    try:
        if not payload.records:
            raise HTTPException(status_code=400, detail="No records provided")

        ids = list({r.employee_id for r in payload.records})
        got = (
            supabase.table("employees").select("id")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
            .in_("id", ids).execute()
        )
        found = {row["id"] for row in got.data}
        missing = [i for i in ids if i not in found]
        if missing:
            raise HTTPException(status_code=400, detail=f"Employees not in tenant: {missing}")

        uid = _uid(user)
        rows = []
        for r in payload.records:
            row = {
                "tenant_id": tenant_id,
                "employee_id": r.employee_id,
                "date": payload.date,
                "status": r.status,
            }
            for field in ("leave_type", "check_in_time", "check_out_time", "remarks"):
                val = getattr(r, field)
                if val is not None:
                    row[field] = val
            if uid:
                row["marked_by_id"] = uid
            rows.append(row)

        resp = (
            supabase.table("staff_attendance")
            .upsert(rows, on_conflict="employee_id,date")
            .execute()
        )
        return {"marked": len(resp.data), "records": resp.data}
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.get("/staff-attendance/summary")
def staff_attendance_summary(
    year: int = Query(..., ge=2000, le=2100),
    month: int = Query(..., ge=1, le=12),
    tenant_id: str = Depends(get_tenant_id),
):
    """Per-employee monthly attendance counts and payable_days (feeds payroll)."""
    try:
        resp = supabase.rpc("get_staff_attendance_summary", {
            "p_tenant_id": tenant_id, "p_year": year, "p_month": month,
        }).execute()
        return {"year": year, "month": month, "rows": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/staff-attendance", response_model=List[StaffAttendanceResponse])
def list_staff_attendance(
    employee_id: Optional[int] = Query(default=None),
    date: Optional[str] = Query(default=None, description="Exact ISO date"),
    date_from: Optional[str] = Query(default=None),
    date_to: Optional[str] = Query(default=None),
    status: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List staff attendance rows with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("staff_attendance").select("*").eq("tenant_id", tenant_id)
        if employee_id is not None:
            query = query.eq("employee_id", employee_id)
        if date is not None:
            query = query.eq("date", date)
        if date_from is not None:
            query = query.gte("date", date_from)
        if date_to is not None:
            query = query.lte("date", date_to)
        if status is not None:
            query = query.eq("status", status)
        resp = (
            query.order("date", desc=True).order("employee_id")
            .range(offset, offset + limit - 1).execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/staff-attendance/{record_id}", response_model=StaffAttendanceResponse)
def get_staff_attendance(record_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single staff attendance row."""
    try:
        resp = (
            supabase.table("staff_attendance").select("*")
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/staff-attendance/{record_id}", response_model=StaffAttendanceResponse)
def update_staff_attendance(
    record_id: int,
    payload: StaffAttendanceUpdate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Update a staff attendance row (status / leave_type / times / remarks)."""
    try:
        data = {}
        for field in ("status", "leave_type", "check_in_time", "check_out_time", "remarks"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        data["updated_at"] = _now_iso()
        uid = _uid(user)
        if uid:
            data["updated_by_id"] = uid

        resp = (
            supabase.table("staff_attendance").update(data)
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise _map_error(str(e))


@router.delete("/staff-attendance/{record_id}")
def delete_staff_attendance(record_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete a staff attendance row (hard delete — no soft-delete column)."""
    try:
        resp = (
            supabase.table("staff_attendance").delete()
            .eq("id", record_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Attendance record not found")
        return {"message": "Attendance record removed", "record_id": record_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ════════════════════════════════════════════════════════════════════════════
#  ATTENDANCE → PAYSLIP BRIDGE
# ════════════════════════════════════════════════════════════════════════════

@router.post("/payslips/{payslip_id}/apply-attendance")
def apply_attendance_to_payslip(payslip_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Fill a draft payslip's days_absent + absence_deduction from the month's
    staff attendance (per-day rate derived from the payslip's gross). Only
    operates on draft payslips. Returns the updated payslip.
    """
    try:
        ps = (
            supabase.table("payslips").select("id, status")
            .eq("id", payslip_id).eq("tenant_id", tenant_id).execute()
        )
        if not ps.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        if ps.data[0]["status"] != "draft":
            raise HTTPException(status_code=400, detail="Only draft payslips can be recomputed")

        supabase.rpc("apply_staff_attendance_to_payslip", {"p_payslip_id": payslip_id}).execute()

        resp = (
            supabase.table("payslips").select("*")
            .eq("id", payslip_id).eq("tenant_id", tenant_id).execute()
        )
        return resp.data[0] if resp.data else {"message": "applied", "payslip_id": payslip_id}
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "not in draft" in detail.lower() or "not found" in detail.lower():
            raise HTTPException(status_code=400, detail=detail)
        raise HTTPException(status_code=500, detail=detail)
