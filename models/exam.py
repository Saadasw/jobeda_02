"""
Examination models — subjects, grade scales, exams, exam-subjects, marks,
and report cards.

Marks' percent/grade/grade_point/is_passed are computed by a DB trigger, so
they are read-only on responses and never sent on writes. Likewise report_card
aggregates are produced by generate_report_card().
"""
from decimal import Decimal
from typing import Optional, List, Literal
from pydantic import BaseModel, Field


ExamType = Literal[
    "weekly", "monthly", "first_term", "mid_term",
    "second_term", "final", "pre_test", "special",
]
ExamStatus = Literal[
    "planned", "scheduled", "in_progress", "completed", "published", "cancelled",
]
ReportCardStatus = Literal["draft", "finalized", "published"]


# ─── Subjects ────────────────────────────────────────────────────────────────

class SubjectCreate(BaseModel):
    name: str
    code: Optional[str] = None
    description: Optional[str] = None
    is_active: bool = True


class SubjectUpdate(BaseModel):
    name: Optional[str] = None
    code: Optional[str] = None
    description: Optional[str] = None
    is_active: Optional[bool] = None


class SubjectResponse(BaseModel):
    id: int
    tenant_id: str
    name: str
    code: Optional[str] = None
    description: Optional[str] = None
    is_active: Optional[bool] = True
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


class ClassSubjectCreate(BaseModel):
    class_id: int
    subject_id: int
    is_optional: bool = False


class ClassSubjectResponse(BaseModel):
    id: int
    tenant_id: str
    class_id: int
    subject_id: int
    is_optional: Optional[bool] = False
    created_at: Optional[str] = None


# ─── Grade scales ────────────────────────────────────────────────────────────

class GradeScaleBandCreate(BaseModel):
    grade_name: str
    min_percent: Decimal = Field(ge=0, le=100)
    max_percent: Decimal = Field(ge=0, le=100)
    grade_point: Decimal = Field(ge=0)
    is_pass: bool = True


class GradeScaleBandResponse(BaseModel):
    id: int
    grade_scale_id: int
    grade_name: str
    min_percent: Decimal
    max_percent: Decimal
    grade_point: Decimal
    is_pass: bool


class GradeScaleCreate(BaseModel):
    name: str
    is_default: bool = False
    is_active: bool = True
    bands: Optional[List[GradeScaleBandCreate]] = None


class GradeScaleResponse(BaseModel):
    id: int
    tenant_id: str
    name: str
    is_default: Optional[bool] = False
    is_active: Optional[bool] = True
    created_at: Optional[str] = None
    bands: Optional[List[GradeScaleBandResponse]] = None


# ─── Exams ───────────────────────────────────────────────────────────────────

class ExamCreate(BaseModel):
    academic_year_id: int
    name: str
    exam_type: ExamType
    grade_scale_id: Optional[int] = None
    start_date: str
    end_date: str
    notes: Optional[str] = None


class ExamUpdate(BaseModel):
    name: Optional[str] = None
    exam_type: Optional[ExamType] = None
    grade_scale_id: Optional[int] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    status: Optional[ExamStatus] = None
    notes: Optional[str] = None


class ExamResponse(BaseModel):
    id: int
    tenant_id: str
    academic_year_id: int
    name: str
    exam_type: str
    grade_scale_id: Optional[int] = None
    start_date: str
    end_date: str
    status: str
    notes: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# ─── Exam subjects ───────────────────────────────────────────────────────────

class ExamSubjectCreate(BaseModel):
    exam_id: int
    class_id: int
    subject_id: int
    full_marks: Decimal = Field(gt=0)
    pass_marks: Decimal = Field(ge=0)
    weightage: Decimal = Field(default=Decimal("100"), gt=0, le=100)
    exam_date: Optional[str] = None
    exam_time: Optional[str] = None          # "HH:MM" or "HH:MM:SS"
    duration_minutes: Optional[int] = Field(default=None, gt=0)
    room: Optional[str] = None


class ExamSubjectUpdate(BaseModel):
    full_marks: Optional[Decimal] = Field(default=None, gt=0)
    pass_marks: Optional[Decimal] = Field(default=None, ge=0)
    weightage: Optional[Decimal] = Field(default=None, gt=0, le=100)
    exam_date: Optional[str] = None
    exam_time: Optional[str] = None
    duration_minutes: Optional[int] = Field(default=None, gt=0)
    room: Optional[str] = None


class ExamSubjectResponse(BaseModel):
    id: int
    tenant_id: str
    exam_id: int
    class_id: int
    subject_id: int
    full_marks: Decimal
    pass_marks: Decimal
    weightage: Decimal
    exam_date: Optional[str] = None
    exam_time: Optional[str] = None
    duration_minutes: Optional[int] = None
    room: Optional[str] = None
    created_at: Optional[str] = None


# ─── Marks ───────────────────────────────────────────────────────────────────

class MarkCreate(BaseModel):
    exam_subject_id: int
    student_id: int
    marks_obtained: Optional[Decimal] = Field(default=None, ge=0)
    is_absent: bool = False
    remarks: Optional[str] = None


class MarkUpdate(BaseModel):
    marks_obtained: Optional[Decimal] = Field(default=None, ge=0)
    is_absent: Optional[bool] = None
    remarks: Optional[str] = None


class MarkResponse(BaseModel):
    id: int
    tenant_id: str
    exam_subject_id: int
    student_id: int
    marks_obtained: Optional[Decimal] = None
    is_absent: Optional[bool] = False
    percent: Optional[Decimal] = None
    grade: Optional[str] = None
    grade_point: Optional[Decimal] = None
    is_passed: Optional[bool] = None
    remarks: Optional[str] = None
    entered_at: Optional[str] = None


# ─── Report cards ────────────────────────────────────────────────────────────

class ReportCardGenerateRequest(BaseModel):
    student_id: int
    exam_id: int


class ReportCardGenerateForClass(BaseModel):
    exam_id: int
    class_id: int


class ReportCardUpdate(BaseModel):
    teacher_remarks: Optional[str] = None
    principal_remarks: Optional[str] = None
    status: Optional[ReportCardStatus] = None


class ReportCardResponse(BaseModel):
    id: int
    tenant_id: str
    exam_id: int
    student_id: int
    total_full_marks: Decimal
    total_obtained: Decimal
    percent: Decimal
    gpa: Decimal
    overall_grade: Optional[str] = None
    is_passed: Optional[bool] = False
    subjects_failed: Optional[int] = 0
    subjects_absent: Optional[int] = 0
    position_in_class: Optional[int] = None
    position_in_section: Optional[int] = None
    class_size: Optional[int] = None
    section_size: Optional[int] = None
    teacher_remarks: Optional[str] = None
    principal_remarks: Optional[str] = None
    status: Optional[str] = "draft"
    generated_at: Optional[str] = None
