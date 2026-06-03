"""
Reports routes — trial balance, income statement, balance sheet, ledger, dashboard, students-due.
All report endpoints support date filtering via ?from= and ?to= parameters.
"""
import math
from decimal import Decimal
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from services.reports import get_trial_balance, get_income_statement, get_balance_sheet

router = APIRouter(prefix="/reports", tags=["Reports"])


@router.get("/trial-balance")
def trial_balance(
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Trial balance across all accounts."""
    try:
        result = get_trial_balance(tenant_id, from_date, to_date)
        return {
            "period": {"from": from_date, "to": to_date},
            **result,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/income-statement")
def income_statement(
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Income statement: revenue vs expenses."""
    try:
        result = get_income_statement(tenant_id, from_date, to_date)
        return {
            "period": {"from": from_date, "to": to_date},
            **result,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/balance-sheet")
def balance_sheet(
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Balance sheet: Assets = Liabilities + Equity."""
    try:
        result = get_balance_sheet(tenant_id, from_date, to_date)
        return {
            "period": {"from": from_date, "to": to_date},
            **result,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/ledger")
def account_ledger(
    account_id: int = Query(...),
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Ledger for a specific account with running balance."""
    try:
        # Get account info
        acct_resp = supabase.table("accounts").select("id, name, type").eq("id", account_id).eq("tenant_id", tenant_id).execute()
        if not acct_resp.data:
            raise HTTPException(status_code=404, detail="Account not found")
        account = acct_resp.data[0]

        # Get journal entries
        je_query = supabase.table("journal_entries").select("id, date, description").eq("tenant_id", tenant_id).eq("is_reversed", False)
        if from_date:
            je_query = je_query.gte("date", from_date)
        if to_date:
            je_query = je_query.lte("date", to_date)
        je_resp = je_query.order("date").execute()

        journal_ids = [je["id"] for je in je_resp.data]
        je_map = {je["id"]: je for je in je_resp.data}

        if not journal_ids:
            return {
                "account_id": account_id,
                "account_name": account["name"],
                "period": {"from": from_date, "to": to_date},
                "entries": [],
                "opening_balance": 0,
                "closing_balance": 0,
            }

        # Get journal lines for this account
        lines_resp = (
            supabase.table("journal_lines")
            .select("journal_id, debit, credit")
            .eq("account_id", account_id)
            .eq("tenant_id", tenant_id)
            .in_("journal_id", journal_ids)
            .execute()
        )

        # Build ledger entries with running balance
        entries = []
        running = Decimal("0")
        for line in lines_resp.data:
            je = je_map.get(line["journal_id"], {})
            debit = Decimal(str(line["debit"]))
            credit = Decimal(str(line["credit"]))
            running += debit - credit
            entries.append({
                "journal_id": line["journal_id"],
                "date": je.get("date", ""),
                "description": je.get("description", ""),
                "debit": float(debit),
                "credit": float(credit),
                "running_balance": float(running),
            })

        return {
            "account_id": account_id,
            "account_name": account["name"],
            "period": {"from": from_date, "to": to_date},
            "entries": entries,
            "opening_balance": 0,
            "closing_balance": float(running),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/students-due")
def students_due(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """
    List all students with outstanding balances.
    Uses the student_due_summary PostgreSQL view — single query, no N+1.
    """
    try:
        # Count total students with due > 0
        count_resp = (
            supabase.table("student_due_summary")
            .select("id", count="exact")
            .eq("tenant_id", tenant_id)
            .gt("due", 0)
            .execute()
        )
        total = count_resp.count if count_resp.count is not None else len(count_resp.data)

        # Paginated data
        offset = (page - 1) * limit
        resp = (
            supabase.table("student_due_summary")
            .select("*")
            .eq("tenant_id", tenant_id)
            .gt("due", 0)
            .order("due", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )

        due_list = [
            {
                "student_id": row["id"],
                "student_name": row["name"],
                "total_fee": row["total_fee"],
                "total_paid": row["total_paid"],
                "due": row["due"],
            }
            for row in resp.data
        ]

        return {
            "data": due_list,
            "page": page,
            "limit": limit,
            "total": total,
            "total_pages": math.ceil(total / limit) if total > 0 else 1,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/fee-details")
def fee_details(
    student_id: Optional[int] = Query(default=None),
    month: Optional[str] = Query(default=None),
    fee_type_id: Optional[int] = Query(default=None),
    unpaid_only: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """
    Per-fee-assignment breakdown: each fee row shows paid/due.
    Uses the fee_detail_summary PostgreSQL view — single query.

    Filters:
      - student_id: show fees for a specific student
      - month: filter by fee month (e.g. "2026-01-01")
      - fee_type_id: filter by fee type
      - unpaid_only: if true, only show fees with due > 0
    """
    try:
        # Count query
        count_query = supabase.table("fee_detail_summary").select("fee_id", count="exact").eq("tenant_id", tenant_id)
        if student_id is not None:
            count_query = count_query.eq("student_id", student_id)
        if month is not None:
            count_query = count_query.eq("month", month)
        if fee_type_id is not None:
            count_query = count_query.eq("fee_type_id", fee_type_id)
        if unpaid_only:
            count_query = count_query.gt("due", 0)
        count_resp = count_query.execute()
        total = count_resp.count if count_resp.count is not None else len(count_resp.data)

        # Data query
        offset = (page - 1) * limit
        query = supabase.table("fee_detail_summary").select("*").eq("tenant_id", tenant_id)
        if student_id is not None:
            query = query.eq("student_id", student_id)
        if month is not None:
            query = query.eq("month", month)
        if fee_type_id is not None:
            query = query.eq("fee_type_id", fee_type_id)
        if unpaid_only:
            query = query.gt("due", 0)
        resp = query.order("month").order("student_name").range(offset, offset + limit - 1).execute()

        return {
            "data": resp.data,
            "page": page,
            "limit": limit,
            "total": total,
            "total_pages": math.ceil(total / limit) if total > 0 else 1,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/dashboard")
def dashboard(tenant_id: str = Depends(get_tenant_id)):
    """
    Owner's home screen summary.
    Uses the get_dashboard_summary(tenant_id) PostgreSQL function — single query.

    Returns:
      - today_collection: payments received today
      - today_expense: expenses recorded today
      - total_students: active student count
      - total_employees: active employee count
      - total_due: total unpaid fees across all students
      - cash_balance: net cash position from journal ledger
      - pending_payments: count of pending payments
    """
    try:
        resp = supabase.rpc("get_dashboard_summary", {"p_tenant_id": tenant_id}).execute()
        if not resp.data:
            return {
                "today_collection": 0,
                "today_expense": 0,
                "total_students": 0,
                "total_employees": 0,
                "total_due": 0,
                "cash_balance": 0,
                "pending_payments": 0,
            }
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

