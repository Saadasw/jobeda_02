"""
Income (non-student) routes — donations, zakat, mahfil income, etc.
Uses a dedicated 'income' table with trg_income_journal trigger.
Trigger creates: Dr Cash / Cr Revenue Account.
"""
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, get_financial_tenant_id
from models.income import IncomeCreate, IncomeResponse

router = APIRouter(prefix="/income", tags=["Income"])


@router.post("", response_model=IncomeResponse, status_code=201)
def create_income(payload: IncomeCreate, tenant_id: str = Depends(get_financial_tenant_id)):
    """
    Record non-student income (donation, zakat, mahfil, etc.).
    The account_id should reference a revenue-type account.
    Triggers trg_income_journal → Dr Cash / Cr Revenue Account.
    """
    try:
        data = {
            "account_id": payload.account_id,
            "amount": float(payload.amount),
            "date": payload.date,
            "description": payload.description,
            "tenant_id": tenant_id,
        }
        resp = supabase.table("income").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to record income")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("")
def list_income(
    account_id: Optional[int] = Query(default=None),
    from_date: Optional[str] = Query(default=None, alias="from"),
    to_date: Optional[str] = Query(default=None, alias="to"),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=1000),
    tenant_id: str = Depends(get_tenant_id),
):
    """List non-student income records with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("income").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
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


@router.get("/{income_id}", response_model=IncomeResponse)
def get_income(income_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get income record details."""
    try:
        resp = (
            supabase.table("income")
            .select("*")
            .eq("id", income_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Income record not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{income_id}")
def delete_income(income_id: int, tenant_id: str = Depends(get_financial_tenant_id)):
    """Soft-delete an income record."""
    try:
        resp = (
            supabase.table("income")
            .update({"is_deleted": True, "deleted_at": datetime.utcnow().isoformat()})
            .eq("id", income_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Income record not found")
        return {"message": "Income record archived", "income_id": income_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
