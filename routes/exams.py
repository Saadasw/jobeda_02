"""
Examination routes — subjects, grade scales, exams, exam-subjects, marks,
and report cards.

Tenant isolation note: the generate_report_card / compute_class_positions /
lookup_grade DB functions take only domain ids (not tenant_id), so every route
validates that the referenced rows belong to the caller's tenant BEFORE calling
an RPC or inserting marks.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.exam import (
    SubjectCreate, SubjectUpdate, SubjectResponse,
    ClassSubjectCreate, ClassSubjectResponse,
    GradeScaleCreate, GradeScaleResponse, GradeScaleBandCreate, GradeScaleBandResponse,
    ExamCreate, ExamUpdate, ExamResponse,
    ExamSubjectCreate, ExamSubjectUpdate, ExamSubjectResponse,
    MarkCreate, MarkUpdate, MarkResponse,
    ReportCardGenerateRequest, ReportCardGenerateForClass,
    ReportCardUpdate, ReportCardResponse,
)

router = APIRouter(tags=["Exams"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _assert(table: str, row_id: int, tenant_id: str, label: str) -> None:
    """Ensure a row exists in this tenant (FK / RPC tenant-isolation guard)."""
    resp = supabase.table(table).select("id").eq("id", row_id).eq("tenant_id", tenant_id).execute()
    if not resp.data:
        raise HTTPException(status_code=404, detail=f"{label} not found")


def _dup(detail: str) -> bool:
    low = detail.lower()
    return "duplicate" in low or "unique" in low or "uq_" in low


# ═══ SUBJECTS ════════════════════════════════════════════════════════════════

@router.get("/subjects", response_model=List[SubjectResponse])
def list_subjects(
    is_active: Optional[bool] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List subjects."""
    try:
        query = supabase.table("subjects").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if is_active is not None:
            query = query.eq("is_active", is_active)
        resp = query.order("name").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/subjects", response_model=SubjectResponse, status_code=201)
def create_subject(payload: SubjectCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a subject."""
    try:
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("subjects").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create subject")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="Subject with this name already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.put("/subjects/{subject_id}", response_model=SubjectResponse)
def update_subject(subject_id: int, payload: SubjectUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update a subject."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("subjects").update(data)
            .eq("id", subject_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Subject not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/subjects/{subject_id}")
def delete_subject(subject_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete a subject."""
    try:
        resp = (
            supabase.table("subjects")
            .update({"is_deleted": True})
            .eq("id", subject_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Subject not found")
        return {"message": "Subject archived", "subject_id": subject_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ CLASS-SUBJECT LINKS ═════════════════════════════════════════════════════

@router.get("/class-subjects", response_model=List[ClassSubjectResponse])
def list_class_subjects(
    class_id: Optional[int] = Query(default=None),
    subject_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List class↔subject assignments."""
    try:
        query = supabase.table("class_subjects").select("*").eq("tenant_id", tenant_id)
        if class_id is not None:
            query = query.eq("class_id", class_id)
        if subject_id is not None:
            query = query.eq("subject_id", subject_id)
        resp = query.order("class_id").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/class-subjects", response_model=ClassSubjectResponse, status_code=201)
def create_class_subject(payload: ClassSubjectCreate, tenant_id: str = Depends(get_tenant_id)):
    """Assign a subject to a class."""
    try:
        _assert("classes", payload.class_id, tenant_id, "Class")
        _assert("subjects", payload.subject_id, tenant_id, "Subject")
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("class_subjects").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to assign subject to class")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="Subject already assigned to this class")
        raise HTTPException(status_code=500, detail=detail)


@router.delete("/class-subjects/{link_id}")
def delete_class_subject(link_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Remove a class↔subject assignment."""
    try:
        resp = (
            supabase.table("class_subjects").delete()
            .eq("id", link_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Class-subject link not found")
        return {"message": "Class-subject link removed", "link_id": link_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ GRADE SCALES ════════════════════════════════════════════════════════════

@router.get("/grade-scales", response_model=List[GradeScaleResponse])
def list_grade_scales(tenant_id: str = Depends(get_tenant_id)):
    """List grade scales with their bands."""
    try:
        scales_resp = (
            supabase.table("grade_scales").select("*")
            .eq("tenant_id", tenant_id).order("name").execute()
        )
        scales = scales_resp.data
        if not scales:
            return []
        scale_ids = [s["id"] for s in scales]
        bands_resp = (
            supabase.table("grade_scale_bands").select("*")
            .in_("grade_scale_id", scale_ids).order("min_percent", desc=True).execute()
        )
        bands_by_scale: dict = {}
        for b in bands_resp.data:
            bands_by_scale.setdefault(b["grade_scale_id"], []).append(b)
        for s in scales:
            s["bands"] = bands_by_scale.get(s["id"], [])
        return scales
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/grade-scales", response_model=GradeScaleResponse, status_code=201)
def create_grade_scale(payload: GradeScaleCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a grade scale (optionally with bands). Only one default per tenant."""
    try:
        # Keep a single default per tenant.
        if payload.is_default:
            supabase.table("grade_scales").update({"is_default": False}).eq(
                "tenant_id", tenant_id
            ).eq("is_default", True).execute()

        scale_data = {
            "tenant_id": tenant_id,
            "name": payload.name,
            "is_default": payload.is_default,
            "is_active": payload.is_active,
        }
        scale_resp = supabase.table("grade_scales").insert(scale_data).execute()
        if not scale_resp.data:
            raise HTTPException(status_code=400, detail="Failed to create grade scale")
        scale = scale_resp.data[0]

        if payload.bands:
            band_rows = [{
                "grade_scale_id": scale["id"],
                "grade_name": b.grade_name,
                "min_percent": float(b.min_percent),
                "max_percent": float(b.max_percent),
                "grade_point": float(b.grade_point),
                "is_pass": b.is_pass,
            } for b in payload.bands]
            bands_resp = supabase.table("grade_scale_bands").insert(band_rows).execute()
            scale["bands"] = bands_resp.data
        else:
            scale["bands"] = []
        return scale
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="Grade scale with this name already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.post("/grade-scales/{scale_id}/bands", response_model=GradeScaleBandResponse, status_code=201)
def add_grade_band(scale_id: int, payload: GradeScaleBandCreate, tenant_id: str = Depends(get_tenant_id)):
    """Add a band to a grade scale."""
    try:
        _assert("grade_scales", scale_id, tenant_id, "Grade scale")
        data = {
            "grade_scale_id": scale_id,
            "grade_name": payload.grade_name,
            "min_percent": float(payload.min_percent),
            "max_percent": float(payload.max_percent),
            "grade_point": float(payload.grade_point),
            "is_pass": payload.is_pass,
        }
        resp = supabase.table("grade_scale_bands").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to add band")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="Band with this grade name already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.delete("/grade-scale-bands/{band_id}")
def delete_grade_band(band_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete a grade band (verifies the parent scale belongs to the tenant)."""
    try:
        band_resp = supabase.table("grade_scale_bands").select("grade_scale_id").eq("id", band_id).execute()
        if not band_resp.data:
            raise HTTPException(status_code=404, detail="Band not found")
        _assert("grade_scales", band_resp.data[0]["grade_scale_id"], tenant_id, "Grade scale")
        supabase.table("grade_scale_bands").delete().eq("id", band_id).execute()
        return {"message": "Band removed", "band_id": band_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ EXAMS ═══════════════════════════════════════════════════════════════════

@router.get("/exams", response_model=List[ExamResponse])
def list_exams(
    academic_year_id: Optional[int] = Query(default=None),
    status: Optional[str] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List exams."""
    try:
        query = supabase.table("exams").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if academic_year_id is not None:
            query = query.eq("academic_year_id", academic_year_id)
        if status is not None:
            query = query.eq("status", status)
        resp = query.order("start_date", desc=True).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/exams", response_model=ExamResponse, status_code=201)
def create_exam(payload: ExamCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create an exam header."""
    try:
        _assert("academic_years", payload.academic_year_id, tenant_id, "Academic year")
        if payload.grade_scale_id is not None:
            _assert("grade_scales", payload.grade_scale_id, tenant_id, "Grade scale")
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("exams").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create exam")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="An exam with this name already exists for the year")
        if "chk_exams_date_range" in detail:
            raise HTTPException(status_code=400, detail="end_date must be on or after start_date")
        raise HTTPException(status_code=500, detail=detail)


@router.get("/exams/{exam_id}", response_model=ExamResponse)
def get_exam(exam_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get an exam."""
    try:
        resp = supabase.table("exams").select("*").eq("id", exam_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Exam not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/exams/{exam_id}", response_model=ExamResponse)
def update_exam(exam_id: int, payload: ExamUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an exam (including status transitions)."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        if "grade_scale_id" in data:
            _assert("grade_scales", data["grade_scale_id"], tenant_id, "Grade scale")
        resp = (
            supabase.table("exams").update(data)
            .eq("id", exam_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Exam not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/exams/{exam_id}")
def delete_exam(exam_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete an exam."""
    try:
        resp = (
            supabase.table("exams")
            .update({"is_deleted": True})
            .eq("id", exam_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Exam not found")
        return {"message": "Exam archived", "exam_id": exam_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ EXAM SUBJECTS ═══════════════════════════════════════════════════════════

@router.get("/exam-subjects", response_model=List[ExamSubjectResponse])
def list_exam_subjects(
    exam_id: Optional[int] = Query(default=None),
    class_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List exam-subject setups (the marks sheet headers)."""
    try:
        query = supabase.table("exam_subjects").select("*").eq("tenant_id", tenant_id)
        if exam_id is not None:
            query = query.eq("exam_id", exam_id)
        if class_id is not None:
            query = query.eq("class_id", class_id)
        resp = query.order("exam_date").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/exam-subjects", response_model=ExamSubjectResponse, status_code=201)
def create_exam_subject(payload: ExamSubjectCreate, tenant_id: str = Depends(get_tenant_id)):
    """Configure a subject paper for an exam/class (full_marks, pass_marks, schedule)."""
    try:
        _assert("exams", payload.exam_id, tenant_id, "Exam")
        _assert("classes", payload.class_id, tenant_id, "Class")
        _assert("subjects", payload.subject_id, tenant_id, "Subject")
        data = {
            "tenant_id": tenant_id,
            "exam_id": payload.exam_id,
            "class_id": payload.class_id,
            "subject_id": payload.subject_id,
            "full_marks": float(payload.full_marks),
            "pass_marks": float(payload.pass_marks),
            "weightage": float(payload.weightage),
        }
        if payload.exam_date is not None:
            data["exam_date"] = payload.exam_date
        if payload.exam_time is not None:
            data["exam_time"] = payload.exam_time
        if payload.duration_minutes is not None:
            data["duration_minutes"] = payload.duration_minutes
        if payload.room is not None:
            data["room"] = payload.room

        resp = supabase.table("exam_subjects").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create exam subject")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if _dup(detail):
            raise HTTPException(status_code=409, detail="This subject is already set up for the exam/class")
        if "chk_pass_le_full" in detail:
            raise HTTPException(status_code=400, detail="pass_marks must not exceed full_marks")
        raise HTTPException(status_code=500, detail=detail)


@router.put("/exam-subjects/{exam_subject_id}", response_model=ExamSubjectResponse)
def update_exam_subject(exam_subject_id: int, payload: ExamSubjectUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an exam-subject setup."""
    try:
        data = {}
        for field in ("full_marks", "pass_marks", "weightage"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = float(val)
        for field in ("exam_date", "exam_time", "duration_minutes", "room"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("exam_subjects").update(data)
            .eq("id", exam_subject_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Exam subject not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "chk_pass_le_full" in detail:
            raise HTTPException(status_code=400, detail="pass_marks must not exceed full_marks")
        raise HTTPException(status_code=500, detail=detail)


@router.delete("/exam-subjects/{exam_subject_id}")
def delete_exam_subject(exam_subject_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete an exam-subject setup (cascades to its marks)."""
    try:
        resp = (
            supabase.table("exam_subjects").delete()
            .eq("id", exam_subject_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Exam subject not found")
        return {"message": "Exam subject removed", "exam_subject_id": exam_subject_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ MARKS ═══════════════════════════════════════════════════════════════════

def _mark_insert_row(payload: MarkCreate, tenant_id: str) -> dict:
    row = {
        "tenant_id": tenant_id,
        "exam_subject_id": payload.exam_subject_id,
        "student_id": payload.student_id,
        "is_absent": payload.is_absent,
    }
    if payload.marks_obtained is not None:
        row["marks_obtained"] = float(payload.marks_obtained)
    if payload.remarks is not None:
        row["remarks"] = payload.remarks
    return row


def _map_marks_error(detail: str):
    if _dup(detail):
        raise HTTPException(status_code=409, detail="Marks already entered for this student/subject")
    low = detail.lower()
    if "exceeds full_marks" in low or "chk_marks_absent_or_score" in low or "forbidden" in low:
        raise HTTPException(status_code=400, detail=detail)
    raise HTTPException(status_code=500, detail=detail)


@router.get("/marks", response_model=List[MarkResponse])
def list_marks(
    exam_subject_id: Optional[int] = Query(default=None),
    student_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List marks, filtered by exam-subject and/or student."""
    try:
        query = supabase.table("marks").select("*").eq("tenant_id", tenant_id)
        if exam_subject_id is not None:
            query = query.eq("exam_subject_id", exam_subject_id)
        if student_id is not None:
            query = query.eq("student_id", student_id)
        resp = query.order("student_id").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/marks", response_model=MarkResponse, status_code=201)
def create_mark(payload: MarkCreate, tenant_id: str = Depends(get_tenant_id)):
    """Enter a mark. Grade/percent/pass are computed by a DB trigger."""
    try:
        _assert("exam_subjects", payload.exam_subject_id, tenant_id, "Exam subject")
        _assert("students", payload.student_id, tenant_id, "Student")
        resp = supabase.table("marks").insert(_mark_insert_row(payload, tenant_id)).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to enter mark")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        _map_marks_error(str(e))


@router.post("/marks/bulk")
def create_marks_bulk(payload: List[MarkCreate], tenant_id: str = Depends(get_tenant_id)):
    """
    Bulk enter/update marks (upsert on student + exam_subject). Validates that
    all referenced exam-subjects and students belong to the tenant in two queries.
    """
    try:
        if not payload:
            raise HTTPException(status_code=400, detail="No marks provided")

        es_ids = {p.exam_subject_id for p in payload}
        st_ids = {p.student_id for p in payload}

        es_resp = supabase.table("exam_subjects").select("id").eq("tenant_id", tenant_id).in_("id", list(es_ids)).execute()
        if len({r["id"] for r in es_resp.data}) != len(es_ids):
            raise HTTPException(status_code=404, detail="One or more exam subjects not found in tenant")
        st_resp = supabase.table("students").select("id").eq("tenant_id", tenant_id).in_("id", list(st_ids)).execute()
        if len({r["id"] for r in st_resp.data}) != len(st_ids):
            raise HTTPException(status_code=404, detail="One or more students not found in tenant")

        rows = [_mark_insert_row(p, tenant_id) for p in payload]
        resp = supabase.table("marks").upsert(rows, on_conflict="student_id,exam_subject_id").execute()
        return {"upserted": len(resp.data), "marks": resp.data}
    except HTTPException:
        raise
    except Exception as e:
        _map_marks_error(str(e))


@router.put("/marks/{mark_id}", response_model=MarkResponse)
def update_mark(mark_id: int, payload: MarkUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update a mark (grade recomputed by trigger)."""
    try:
        data = {}
        if payload.marks_obtained is not None:
            data["marks_obtained"] = float(payload.marks_obtained)
        if payload.is_absent is not None:
            data["is_absent"] = payload.is_absent
        if payload.remarks is not None:
            data["remarks"] = payload.remarks
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("marks").update(data)
            .eq("id", mark_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Mark not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        _map_marks_error(str(e))


@router.delete("/marks/{mark_id}")
def delete_mark(mark_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete a mark."""
    try:
        resp = supabase.table("marks").delete().eq("id", mark_id).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Mark not found")
        return {"message": "Mark removed", "mark_id": mark_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══ REPORT CARDS ════════════════════════════════════════════════════════════

@router.post("/report-cards/generate", response_model=ReportCardResponse, status_code=201)
def generate_report_card(payload: ReportCardGenerateRequest, tenant_id: str = Depends(get_tenant_id)):
    """Generate (or refresh, if draft) one student's report card for an exam."""
    try:
        _assert("students", payload.student_id, tenant_id, "Student")
        _assert("exams", payload.exam_id, tenant_id, "Exam")
        rpc_resp = supabase.rpc("generate_report_card", {
            "p_student_id": payload.student_id,
            "p_exam_id": payload.exam_id,
        }).execute()
        report_id = rpc_resp.data
        if not report_id:
            raise HTTPException(status_code=409, detail="A non-draft report card already exists")
        resp = supabase.table("report_cards").select("*").eq("id", report_id).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Report card not found after generation")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/report-cards/generate-class")
def generate_class_report_cards(payload: ReportCardGenerateForClass, tenant_id: str = Depends(get_tenant_id)):
    """
    Generate report cards for every active student in a class for an exam, then
    compute class/section positions.
    """
    try:
        _assert("exams", payload.exam_id, tenant_id, "Exam")
        _assert("classes", payload.class_id, tenant_id, "Class")

        students_resp = (
            supabase.table("students").select("id")
            .eq("tenant_id", tenant_id).eq("class_id", payload.class_id).eq("is_deleted", False)
            .execute()
        )
        student_ids = [s["id"] for s in students_resp.data]
        generated = 0
        for sid in student_ids:
            supabase.rpc("generate_report_card", {
                "p_student_id": sid,
                "p_exam_id": payload.exam_id,
            }).execute()
            generated += 1

        # Assign ranks once all cards exist.
        supabase.rpc("compute_class_positions", {
            "p_exam_id": payload.exam_id,
            "p_class_id": payload.class_id,
        }).execute()

        return {
            "message": "Report cards generated",
            "exam_id": payload.exam_id,
            "class_id": payload.class_id,
            "generated": generated,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/report-cards", response_model=List[ReportCardResponse])
def list_report_cards(
    exam_id: Optional[int] = Query(default=None),
    student_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List report cards."""
    try:
        query = supabase.table("report_cards").select("*").eq("tenant_id", tenant_id)
        if exam_id is not None:
            query = query.eq("exam_id", exam_id)
        if student_id is not None:
            query = query.eq("student_id", student_id)
        resp = query.order("position_in_class").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/report-cards/{report_id}", response_model=ReportCardResponse)
def get_report_card(report_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a report card."""
    try:
        resp = supabase.table("report_cards").select("*").eq("id", report_id).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Report card not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/report-cards/{report_id}", response_model=ReportCardResponse)
def update_report_card(report_id: int, payload: ReportCardUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Add remarks and/or move a report card through draft → finalized → published."""
    try:
        data = {}
        if payload.teacher_remarks is not None:
            data["teacher_remarks"] = payload.teacher_remarks
        if payload.principal_remarks is not None:
            data["principal_remarks"] = payload.principal_remarks
        if payload.status is not None:
            data["status"] = payload.status
            if payload.status == "finalized":
                data["finalized_at"] = _now_iso()
            elif payload.status == "published":
                data["published_at"] = _now_iso()
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("report_cards").update(data)
            .eq("id", report_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Report card not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
