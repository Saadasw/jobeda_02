"""
Expenses routes — CRUD with soft delete.
"""
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.expense import ExpenseCreate, ExpenseResponse

router = APIRouter(prefix="/expenses", tags=["Expenses"])


@router.post("", response_model=ExpenseResponse, status_code=201)
def create_expense(payload: ExpenseCreate, tenant_id: str = Depends(get_tenant_id)):
    """
    Record an expense.
    Triggers trg_expense_journal → Dr Expense Account / Cr Cash.
    """
    try:
        data = {
            "account_id": payload.account_id,
            "amount": float(payload.amount),
            "date": payload.date,
            "description": payload.description,
            "tenant_id": tenant_id,
        }
        resp = supabase.table("expenses").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create expense")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("")
def list_expenses(
    account_id: Optional[int] = Query(default=None),
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List expenses with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("expenses").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if account_id:
            query = query.eq("account_id", account_id)
        if from_date:
            query = query.gte("date", from_date)
        if to_date:
            query = query.lte("date", to_date)
        resp = query.order("date", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{expense_id}", response_model=ExpenseResponse)
def get_expense(expense_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get expense details."""
    try:
        resp = supabase.table("expenses").select("*").eq("id", expense_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Expense not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{expense_id}")
def delete_expense(expense_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete an expense (archive + reversal should be handled separately)."""
    try:
        resp = (
            supabase.table("expenses")
            .update({"is_deleted": True, "deleted_at": datetime.utcnow().isoformat()})
            .eq("id", expense_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Expense not found")
        return {"message": "Expense archived", "expense_id": expense_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
