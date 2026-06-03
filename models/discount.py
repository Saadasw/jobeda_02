"""
Fee discount / waiver models + late-fee & due-date request models.

A discount records a waiver on a single fee_assignment (net = gross − discounts).
The DB trigger validates totals and auto-posts Dr Fee Discount / Cr Accounts Receivable.
"""
from decimal import Decimal
from typing import Optional, Literal
from pydantic import BaseModel, Field


DiscountReason = Literal[
    "sibling",
    "scholarship",
    "hardship",
    "zakat",
    "staff_child",
    "founder_waiver",
    "early_payment",
    "other",
]


class FeeDiscountCreate(BaseModel):
    fee_assignment_id: int
    amount: Decimal = Field(gt=0)                       # money figure waived
    reason: DiscountReason
    percent: Optional[Decimal] = Field(default=None, gt=0, le=100)  # optional, for reporting
    notes: Optional[str] = None


class FeeDiscountResponse(BaseModel):
    id: int
    tenant_id: str
    fee_assignment_id: int
    amount: Decimal
    percent: Optional[Decimal] = None
    reason: str
    notes: Optional[str] = None
    approved_by_id: str
    approved_at: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


class FeeDueDateUpdate(BaseModel):
    due_date: str = Field(description="ISO date, e.g. '2026-05-31'")
