"""
Salary Pydantic models.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


class SalaryPayCreate(BaseModel):
    employee_id: int
    amount: Decimal = Field(gt=0)
    date: str                          # ISO date


class SalaryPayResponse(BaseModel):
    id: int
    employee_id: int
    amount: Decimal
    date: str
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
