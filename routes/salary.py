"""
Salary routes — pay salary and view history.
"""
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.salary import SalaryPayCreate, SalaryPayResponse

router = APIRouter(tags=["Salary"])


@router.post("/salary/pay", response_model=SalaryPayResponse, status_code=201)
def pay_salary(payload: SalaryPayCreate, tenant_id: str = Depends(get_tenant_id)):
    """
    Record a salary payment.
    Triggers trg_salary_journal → Dr Salary Expense / Cr Cash.
    """
    try:
        data = {
            "employee_id": payload.employee_id,
            "amount": float(payload.amount),
            "date": payload.date,
            "tenant_id": tenant_id,
        }
        resp = supabase.table("salary_payments").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to record salary payment")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/salary/history")
def salary_history(
    employee_id: Optional[int] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List salary payment history with optional employee filter."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("salary_payments").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if employee_id:
            query = query.eq("employee_id", employee_id)
        resp = query.order("date", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
