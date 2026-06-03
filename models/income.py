"""
Income (non-student) Pydantic models — donations, zakat, mahfil income, etc.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


class IncomeCreate(BaseModel):
    account_id: int
    amount: Decimal = Field(gt=0)
    date: str                          # ISO date
    description: Optional[str] = None


class IncomeResponse(BaseModel):
    id: int
    account_id: int
    amount: Decimal
    date: str
    description: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
