"""
Academic structure Pydantic models — classes, sections, academic years.
"""
from typing import Optional
from pydantic import BaseModel


# --- Academic Year ---

class AcademicYearCreate(BaseModel):
    name: str                          # e.g. "2026"
    start_date: str                    # ISO date
    end_date: str
    is_current: Optional[bool] = False


class AcademicYearUpdate(BaseModel):
    name: Optional[str] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    is_current: Optional[bool] = None


class AcademicYearResponse(BaseModel):
    id: int
    name: str
    start_date: str
    end_date: str
    is_current: Optional[bool] = False
    created_at: Optional[str] = None


# --- Class ---

class ClassCreate(BaseModel):
    name: str                          # e.g. "Hifz-1", "Nazera-3"


class ClassUpdate(BaseModel):
    name: Optional[str] = None


class ClassResponse(BaseModel):
    id: int
    name: str
    created_at: Optional[str] = None


# --- Section ---

class SectionCreate(BaseModel):
    class_id: int
    name: str                          # e.g. "A", "B"


class SectionUpdate(BaseModel):
    name: Optional[str] = None
    class_id: Optional[int] = None


class SectionResponse(BaseModel):
    id: int
    class_id: int
    name: str
    created_at: Optional[str] = None
