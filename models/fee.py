"""
Fee-related Pydantic models — fee types, assignments, groups, structures, and
bulk generation.
"""
from decimal import Decimal
from typing import List, Optional, Literal
from pydantic import BaseModel, Field

Frequency = Literal["monthly", "termly", "annual", "one_time", "adhoc"]
StructureFrequency = Literal["monthly", "termly", "annual", "one_time"]


# --- Fee Type ---

class FeeTypeCreate(BaseModel):
    name: str
    is_recurring: bool
    account_id: int
    frequency: Optional[Frequency] = None


class FeeTypeUpdate(BaseModel):
    name: Optional[str] = None
    is_recurring: Optional[bool] = None
    account_id: Optional[int] = None
    frequency: Optional[Frequency] = None


class FeeTypeResponse(BaseModel):
    id: int
    name: Optional[str] = None
    is_recurring: Optional[bool] = None
    account_id: Optional[int] = None
    frequency: Optional[str] = None
    is_deleted: Optional[bool] = False


# --- Fee Assignment ---

class FeeAssignCreate(BaseModel):
    student_id: int
    fee_type_id: int
    month: str                         # ISO date, e.g. "2026-05-01"
    amount: Decimal = Field(gt=0)
    account_id: Optional[int] = None   # defaults to fee_type's account if not provided


class FeeAssignResponse(BaseModel):
    id: int
    student_id: int
    fee_type_id: Optional[int] = None
    month: str
    amount: Decimal
    account_id: int
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# --- Fee Group ---

class FeeGroupCreate(BaseModel):
    name: str
    description: Optional[str] = None


class FeeGroupUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None


class FeeGroupResponse(BaseModel):
    id: int
    tenant_id: str
    name: str
    description: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# --- Fee Structure (price list per academic_year × class × fee_group) ---

class FeeStructureCreate(BaseModel):
    academic_year_id: int
    class_id: int
    fee_group_id: int
    name: Optional[str] = None


class FeeStructureUpdate(BaseModel):
    name: Optional[str] = None


class FeeStructureItemCreate(BaseModel):
    fee_type_id: int
    amount: Decimal = Field(ge=0)
    frequency: Optional[StructureFrequency] = "monthly"
    due_day: Optional[int] = Field(default=None, ge=1, le=28)


class FeeStructureItemUpdate(BaseModel):
    amount: Optional[Decimal] = Field(default=None, ge=0)
    frequency: Optional[StructureFrequency] = None
    due_day: Optional[int] = Field(default=None, ge=1, le=28)


class FeeStructureItemResponse(BaseModel):
    id: int
    fee_structure_id: int
    fee_type_id: int
    fee_type_name: Optional[str] = None
    amount: Decimal
    frequency: Optional[str] = None
    due_day: Optional[int] = None
    is_deleted: Optional[bool] = False


class FeeStructureResponse(BaseModel):
    id: int
    tenant_id: str
    academic_year_id: int
    class_id: int
    class_name: Optional[str] = None
    fee_group_id: int
    fee_group_name: Optional[str] = None
    name: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
    items: List[FeeStructureItemResponse] = []


# --- Bulk generation ---

class FeeGenerateRequest(BaseModel):
    academic_year_id: int
    month: str                                  # any date in the month; normalized to the 1st
    class_id: Optional[int] = None              # None => all classes
    section_id: Optional[int] = None
    fee_type_ids: Optional[List[int]] = None    # None => all 'monthly' structure items
    dry_run: bool = False


class FeeGenerateManualRequest(BaseModel):
    academic_year_id: int
    month: str
    fee_type_id: int
    amount: Decimal = Field(gt=0)
    class_id: Optional[int] = None
    section_id: Optional[int] = None
    due_day: Optional[int] = Field(default=None, ge=1, le=28)
    dry_run: bool = False


class FeeGenerateResult(BaseModel):
    month: str
    created: int
    skipped: int                                # already billed (student, type, month)
    no_structure: int = 0                       # students with no matching price list
    students_in_scope: int
    total_amount: float
