"""
Attendance models — daily student and staff attendance.

One row per (student/employee, date). status is a constrained set; staff rows
may additionally carry a leave_type. marked_by_id / updated_by_id capture who
recorded the row (nullable). check_in_time / check_out_time are "HH:MM" or
"HH:MM:SS" strings. There is no soft-delete column — rows are hard-deleted.
"""
from typing import Optional, List, Literal
from pydantic import BaseModel


StudentAttendanceStatus = Literal[
    "present", "absent", "late", "leave", "holiday", "half_day",
]
StaffAttendanceStatus = Literal[
    "present", "absent", "late", "leave", "holiday", "half_day", "on_duty",
]
LeaveType = Literal[
    "casual", "sick", "annual", "unpaid", "maternity", "hajj", "other",
]


# ─── Student attendance ──────────────────────────────────────────────────────

class StudentAttendanceCreate(BaseModel):
    student_id: int
    date: str                                  # ISO date, e.g. "2026-06-03"
    status: StudentAttendanceStatus
    check_in_time: Optional[str] = None        # "HH:MM" or "HH:MM:SS"
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StudentAttendanceBulkItem(BaseModel):
    student_id: int
    status: StudentAttendanceStatus
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StudentAttendanceBulkCreate(BaseModel):
    date: str
    records: List[StudentAttendanceBulkItem]


class StudentAttendanceUpdate(BaseModel):
    status: Optional[StudentAttendanceStatus] = None
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StudentAttendanceResponse(BaseModel):
    id: int
    tenant_id: str
    student_id: int
    date: str
    status: str
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None
    marked_by_id: Optional[str] = None
    marked_at: Optional[str] = None
    updated_at: Optional[str] = None
    updated_by_id: Optional[str] = None


# ─── Staff attendance ────────────────────────────────────────────────────────

class StaffAttendanceCreate(BaseModel):
    employee_id: int
    date: str
    status: StaffAttendanceStatus
    leave_type: Optional[LeaveType] = None
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StaffAttendanceBulkItem(BaseModel):
    employee_id: int
    status: StaffAttendanceStatus
    leave_type: Optional[LeaveType] = None
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StaffAttendanceBulkCreate(BaseModel):
    date: str
    records: List[StaffAttendanceBulkItem]


class StaffAttendanceUpdate(BaseModel):
    status: Optional[StaffAttendanceStatus] = None
    leave_type: Optional[LeaveType] = None
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None


class StaffAttendanceResponse(BaseModel):
    id: int
    tenant_id: str
    employee_id: int
    date: str
    status: str
    leave_type: Optional[str] = None
    check_in_time: Optional[str] = None
    check_out_time: Optional[str] = None
    remarks: Optional[str] = None
    marked_by_id: Optional[str] = None
    marked_at: Optional[str] = None
    updated_at: Optional[str] = None
    updated_by_id: Optional[str] = None
