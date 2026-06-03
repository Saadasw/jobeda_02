"""
Fee-related Pydantic models — fee types and fee assignments.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


# --- Fee Type ---

class FeeTypeCreate(BaseModel):
    name: str
    is_recurring: bool
    account_id: int


class FeeTypeUpdate(BaseModel):
    name: Optional[str] = None
    is_recurring: Optional[bool] = None
    account_id: Optional[int] = None


class FeeTypeResponse(BaseModel):
    id: int
    name: Optional[str] = None
    is_recurring: Optional[bool] = None
    account_id: Optional[int] = None
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
