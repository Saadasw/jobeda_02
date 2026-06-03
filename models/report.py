"""
Report Pydantic models — trial balance, income statement, dashboard, etc.
"""
from decimal import Decimal
from typing import List, Optional
from pydantic import BaseModel


class DateRangeParams(BaseModel):
    """Common date range filter for reports."""
    from_date: Optional[str] = None    # ISO date
    to_date: Optional[str] = None      # ISO date


class TrialBalanceLine(BaseModel):
    account_id: int
    account_name: str
    account_type: str
    total_debit: Decimal
    total_credit: Decimal
    balance: Decimal


class TrialBalanceReport(BaseModel):
    period: DateRangeParams
    lines: List[TrialBalanceLine]
    total_debit: Decimal
    total_credit: Decimal


class IncomeStatementReport(BaseModel):
    period: DateRangeParams
    revenue: List[TrialBalanceLine]
    expenses: List[TrialBalanceLine]
    total_revenue: Decimal
    total_expenses: Decimal
    net_income: Decimal


class BalanceSheetReport(BaseModel):
    period: DateRangeParams
    assets: List[TrialBalanceLine]
    liabilities: List[TrialBalanceLine]
    equity: List[TrialBalanceLine]
    total_assets: Decimal
    total_liabilities: Decimal
    total_equity: Decimal


class LedgerEntry(BaseModel):
    journal_id: int
    date: str
    description: Optional[str] = None
    debit: Decimal
    credit: Decimal
    running_balance: Decimal


class LedgerReport(BaseModel):
    account_id: int
    account_name: str
    period: DateRangeParams
    entries: List[LedgerEntry]
    opening_balance: Decimal
    closing_balance: Decimal


class StudentDueItem(BaseModel):
    student_id: int
    student_name: str
    class_name: Optional[str] = None
    total_fee: Decimal
    total_paid: Decimal
    due: Decimal


class DashboardSummary(BaseModel):
    period: DateRangeParams
    total_income: Decimal
    total_expense: Decimal
    total_due: Decimal
    total_collected: Decimal


class JournalLineResponse(BaseModel):
    id: int
    account_id: int
    account_name: Optional[str] = None
    debit: Decimal
    credit: Decimal


class JournalEntryResponse(BaseModel):
    id: int
    date: str
    description: Optional[str] = None
    reference_type: Optional[str] = None
    reference_id: Optional[int] = None
    is_reversed: Optional[bool] = False
    lines: List[JournalLineResponse] = []
    created_at: Optional[str] = None
