"""
Payroll models — salary structures, advances, and payslips.

Money figures use Decimal in/out; routes cast to float on insert. Generated
columns (gross, total_deductions, net_payable) are read-only — present on
responses but never sent on writes.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


# ─── Salary Structure ────────────────────────────────────────────────────────

class SalaryStructureCreate(BaseModel):
    employee_id: int
    basic: Decimal = Field(ge=0)
    house_rent: Decimal = Field(default=Decimal("0"), ge=0)
    transport: Decimal = Field(default=Decimal("0"), ge=0)
    medical: Decimal = Field(default=Decimal("0"), ge=0)
    other_allowance: Decimal = Field(default=Decimal("0"), ge=0)
    effective_from: str                       # ISO date, e.g. "2026-06-01"
    notes: Optional[str] = None


class SalaryStructureResponse(BaseModel):
    id: int
    tenant_id: str
    employee_id: int
    basic: Decimal
    house_rent: Decimal
    transport: Decimal
    medical: Decimal
    other_allowance: Decimal
    gross: Decimal
    effective_from: str
    effective_to: Optional[str] = None
    notes: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# ─── Salary Advance ──────────────────────────────────────────────────────────

class SalaryAdvanceCreate(BaseModel):
    employee_id: int
    amount: Decimal = Field(gt=0)
    advance_date: str                         # ISO date
    reason: Optional[str] = None
    cash_account_id: Optional[int] = None     # defaults to the tenant's 'Cash' account


class SalaryAdvanceResponse(BaseModel):
    id: int
    tenant_id: str
    employee_id: int
    amount: Decimal
    balance_remaining: Decimal
    advance_date: str
    reason: Optional[str] = None
    cash_account_id: int
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None


# ─── Payslip ─────────────────────────────────────────────────────────────────

class PayslipGenerateRequest(BaseModel):
    employee_id: int
    year: int = Field(ge=2000, le=2100)
    month: int = Field(ge=1, le=12)


class PayslipUpdate(BaseModel):
    """Edit a draft payslip's deduction inputs before finalizing."""
    days_absent: Optional[Decimal] = Field(default=None, ge=0)
    absence_deduction: Optional[Decimal] = Field(default=None, ge=0)
    advance_recovery: Optional[Decimal] = Field(default=None, ge=0)
    other_deduction: Optional[Decimal] = Field(default=None, ge=0)
    notes: Optional[str] = None


class PayslipResponse(BaseModel):
    id: int
    tenant_id: str
    employee_id: int
    year: int
    month: int
    basic: Decimal
    house_rent: Decimal
    transport: Decimal
    medical: Decimal
    other_allowance: Decimal
    gross: Decimal
    days_absent: Decimal
    absence_deduction: Decimal
    advance_recovery: Decimal
    other_deduction: Decimal
    total_deductions: Decimal
    net_payable: Decimal
    status: str
    notes: Optional[str] = None
    created_at: Optional[str] = None
    finalized_at: Optional[str] = None


class PayslipPayRequest(BaseModel):
    date: str                                 # ISO date of the salary payment
    cash_account_id: Optional[int] = None     # defaults to the tenant's 'Cash' account
