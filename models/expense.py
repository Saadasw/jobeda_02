"""
Expense Pydantic models.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


class ExpenseCreate(BaseModel):
    account_id: int
    amount: Decimal = Field(gt=0)
    date: str                          # ISO date
    description: Optional[str] = None


class ExpenseUpdate(BaseModel):
    account_id: Optional[int] = None
    amount: Optional[Decimal] = None
    date: Optional[str] = None
    description: Optional[str] = None


class ExpenseResponse(BaseModel):
    id: int
    account_id: int
    amount: Decimal
    date: str
    description: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
