"""
Student Pydantic models.
"""
from typing import Optional
from pydantic import BaseModel, Field


class StudentCreate(BaseModel):
    name: str
    class_field: Optional[str] = Field(default=None, alias="class")
    class_id: Optional[int] = None
    section_id: Optional[int] = None
    academic_year_id: Optional[int] = None

    model_config = {"populate_by_name": True}


class StudentUpdate(BaseModel):
    name: Optional[str] = None
    class_field: Optional[str] = Field(default=None, alias="class")
    class_id: Optional[int] = None
    section_id: Optional[int] = None
    academic_year_id: Optional[int] = None

    model_config = {"populate_by_name": True}


class StudentResponse(BaseModel):
    id: int
    name: str
    class_field: Optional[str] = Field(default=None, alias="class")
    class_id: Optional[int] = None
    section_id: Optional[int] = None
    academic_year_id: Optional[int] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None

    model_config = {"populate_by_name": True}
