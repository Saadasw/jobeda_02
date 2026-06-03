"""
Academic structure routes — classes, sections, academic years.
"""
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.academic import (
    AcademicYearCreate, AcademicYearUpdate, AcademicYearResponse,
    ClassCreate, ClassUpdate, ClassResponse,
    SectionCreate, SectionUpdate, SectionResponse,
)

router = APIRouter(tags=["Academic"])


# ─── CLASSES ─────────────────────────────────────────────────────────────────

@router.get("/classes", response_model=List[ClassResponse])
def list_classes(tenant_id: str = Depends(get_tenant_id)):
    """List all classes."""
    try:
        resp = supabase.table("classes").select("*").eq("tenant_id", tenant_id).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/classes", response_model=ClassResponse, status_code=201)
def create_class(payload: ClassCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new class."""
    try:
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("classes").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create class")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/classes/{class_id}", response_model=ClassResponse)
def update_class(class_id: int, payload: ClassUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an existing class."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = supabase.table("classes").update(data).eq("id", class_id).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Class not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── SECTIONS ────────────────────────────────────────────────────────────────

@router.get("/sections", response_model=List[SectionResponse])
def list_sections(class_id: Optional[int] = Query(default=None), tenant_id: str = Depends(get_tenant_id)):
    """List sections, optionally filtered by class_id."""
    try:
        query = supabase.table("sections").select("*").eq("tenant_id", tenant_id)
        if class_id is not None:
            query = query.eq("class_id", class_id)
        resp = query.execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/sections", response_model=SectionResponse, status_code=201)
def create_section(payload: SectionCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new section."""
    try:
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("sections").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create section")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── ACADEMIC YEARS ──────────────────────────────────────────────────────────

@router.get("/academic-years", response_model=List[AcademicYearResponse])
def list_academic_years(tenant_id: str = Depends(get_tenant_id)):
    """List all academic years."""
    try:
        resp = supabase.table("academic_years").select("*").eq("tenant_id", tenant_id).order("start_date", desc=True).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/academic-years", response_model=AcademicYearResponse, status_code=201)
def create_academic_year(payload: AcademicYearCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new academic year."""
    try:
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("academic_years").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create academic year")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/academic-years/{year_id}", response_model=AcademicYearResponse)
def update_academic_year(year_id: int, payload: AcademicYearUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an academic year (e.g., set as current)."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")

        # If setting as current, unset all others first (within this tenant only)
        if data.get("is_current"):
            supabase.table("academic_years").update({"is_current": False}).eq("tenant_id", tenant_id).eq("is_current", True).execute()

        resp = supabase.table("academic_years").update(data).eq("id", year_id).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Academic year not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
