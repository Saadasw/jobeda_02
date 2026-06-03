"""
Accounting report routes — thin wrappers over the tenant-aware SQL report
functions from migration 032 (trial balance, income statement, balance sheet,
monthly collection, general ledger, student ledger).

Every underlying function filters by tenant_id and excludes reversed journal
entries, so these endpoints just forward the caller's tenant and the period.
They are mounted under /accounting-reports to sit alongside — not collide with —
the legacy Python-computed /reports/* endpoints.
"""
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id

router = APIRouter(prefix="/accounting-reports", tags=["Accounting Reports"])


@router.get("/trial-balance")
def trial_balance(
    as_of: Optional[str] = Query(default=None, description="ISO date; defaults to today"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Trial balance as of a date: one row per account with debit/credit balances."""
    try:
        params = {"p_tenant_id": tenant_id}
        if as_of:
            params["p_as_of"] = as_of
        resp = supabase.rpc("get_trial_balance", params).execute()
        return {"as_of": as_of, "rows": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/income-statement")
def income_statement(
    from_date: str = Query(..., alias="from"),
    to_date: str = Query(..., alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Profit & loss for a date range; rows tagged section revenue/expense/summary."""
    try:
        resp = supabase.rpc("get_income_statement", {
            "p_tenant_id": tenant_id, "p_from": from_date, "p_to": to_date,
        }).execute()
        return {"from": from_date, "to": to_date, "rows": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/balance-sheet")
def balance_sheet(
    as_of: Optional[str] = Query(default=None, description="ISO date; defaults to today"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Balance sheet as of a date, including Retained Earnings under equity."""
    try:
        params = {"p_tenant_id": tenant_id}
        if as_of:
            params["p_as_of"] = as_of
        resp = supabase.rpc("get_balance_sheet", params).execute()
        return {"as_of": as_of, "rows": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/monthly-collection")
def monthly_collection(
    year: int = Query(..., ge=2000, le=2100),
    tenant_id: str = Depends(get_tenant_id),
):
    """12-row monthly roll-up: payments, discounts, late fees, expenses, net inflow."""
    try:
        resp = supabase.rpc("get_monthly_collection", {
            "p_tenant_id": tenant_id, "p_year": year,
        }).execute()
        return {"year": year, "months": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/general-ledger")
def general_ledger(
    account_id: int = Query(...),
    from_date: str = Query(..., alias="from"),
    to_date: str = Query(..., alias="to"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Line-by-line journal entries for one account between two dates, with running balance."""
    try:
        acct = (
            supabase.table("accounts").select("id, name")
            .eq("id", account_id).eq("tenant_id", tenant_id).execute()
        )
        if not acct.data:
            raise HTTPException(status_code=404, detail="Account not found")
        resp = supabase.rpc("get_general_ledger", {
            "p_tenant_id": tenant_id, "p_account_id": account_id,
            "p_from": from_date, "p_to": to_date,
        }).execute()
        return {
            "account_id": account_id,
            "account_name": acct.data[0]["name"],
            "from": from_date,
            "to": to_date,
            "entries": resp.data,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/student-ledger")
def student_ledger(
    student_id: int = Query(...),
    tenant_id: str = Depends(get_tenant_id),
):
    """Per-student running ledger: every fee, discount, late fee, and payment."""
    try:
        st = (
            supabase.table("students").select("id, name")
            .eq("id", student_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not st.data:
            raise HTTPException(status_code=404, detail="Student not found")
        resp = supabase.rpc("get_student_ledger", {
            "p_tenant_id": tenant_id, "p_student_id": student_id,
        }).execute()
        return {
            "student_id": student_id,
            "student_name": st.data[0]["name"],
            "entries": resp.data,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
