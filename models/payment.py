"""
Payment Pydantic models.
Includes payment creation, allocation, and student financial summary.
"""
from decimal import Decimal
from typing import List, Optional
from pydantic import BaseModel, Field


class PaymentCreate(BaseModel):
    student_id: int
    amount: Decimal = Field(gt=0)
    date: str                          # ISO date
    method: str                        # cash / bank
    cash_account_id: Optional[int] = None


class PaymentResponse(BaseModel):
    id: int
    student_id: Optional[int] = None
    amount: Decimal
    date: str
    method: str
    status: Optional[str] = "completed"
    receipt_no: Optional[str] = None
    cash_account_id: Optional[int] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# --- Payment Allocation ---

class PaymentAllocationCreate(BaseModel):
    payment_id: int
    fee_assignment_id: int
    amount: Decimal = Field(gt=0)


class PaymentAllocationResponse(BaseModel):
    id: int
    payment_id: int
    fee_assignment_id: int
    amount: Decimal


# --- Student Financial Summary ---

class StudentFinancialSummary(BaseModel):
    student_id: int
    student_name: str
    total_fee: Decimal
    total_paid: Decimal
    due: Decimal
    advance: Decimal


# --- Allocation Result ---

class AllocationResult(BaseModel):
    payment_id: int
    receipt_no: Optional[str] = None
    total_amount: Decimal
    allocated: Decimal
    advance: Decimal
    allocations: List[PaymentAllocationResponse] = []
