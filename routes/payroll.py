"""
Payroll routes — salary structures, advances, and payslips.

Flow:
  1. Set a salary_structure per employee (versioned; one active at a time).
  2. Optionally issue salary_advances (Dr Salary Advances / Cr Cash via trigger).
  3. generate_payslip(employee, year, month) → draft from the active structure.
  4. Edit the draft's deductions, then finalize it.
  5. Pay the finalized payslip → salary_payment links to it; the DB trigger posts
     Dr Salary Expense / Cr Salary Advances / Cr Cash and recovers advances FIFO.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.payroll import (
    SalaryStructureCreate, SalaryStructureResponse,
    SalaryAdvanceCreate, SalaryAdvanceResponse,
    PayslipGenerateRequest, PayslipUpdate, PayslipResponse, PayslipPayRequest,
)

router = APIRouter(tags=["Payroll"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _assert_employee(tenant_id: str, employee_id: int) -> None:
    """Ensure the employee exists in this tenant (prevents cross-tenant access)."""
    resp = (
        supabase.table("employees").select("id")
        .eq("id", employee_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=404, detail="Employee not found")


def _resolve_cash_account(tenant_id: str) -> int:
    resp = (
        supabase.table("accounts").select("id")
        .eq("tenant_id", tenant_id).eq("name", "Cash").eq("is_deleted", False)
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=400, detail="No 'Cash' account configured for this tenant")
    return resp.data[0]["id"]


# ─── SALARY STRUCTURES ───────────────────────────────────────────────────────

@router.get("/salary-structures", response_model=List[SalaryStructureResponse])
def list_salary_structures(
    employee_id: Optional[int] = Query(default=None),
    active_only: bool = Query(default=False),
    tenant_id: str = Depends(get_tenant_id),
):
    """List salary structures (history), optionally filtered to active versions."""
    try:
        query = (
            supabase.table("salary_structures").select("*")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
        )
        if employee_id is not None:
            query = query.eq("employee_id", employee_id)
        if active_only:
            query = query.is_("effective_to", "null")
        resp = query.order("employee_id").order("effective_from", desc=True).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/salary-structures", response_model=SalaryStructureResponse, status_code=201)
def create_salary_structure(payload: SalaryStructureCreate, tenant_id: str = Depends(get_tenant_id)):
    """
    Set a new pay structure for an employee. Any currently-active structure is
    closed out (effective_to = new effective_from) so only one stays active.
    """
    try:
        _assert_employee(tenant_id, payload.employee_id)

        # Close out the existing active structure, if any.
        supabase.table("salary_structures").update(
            {"effective_to": payload.effective_from}
        ).eq("tenant_id", tenant_id).eq("employee_id", payload.employee_id).is_(
            "effective_to", "null"
        ).eq("is_deleted", False).execute()

        data = {
            "tenant_id": tenant_id,
            "employee_id": payload.employee_id,
            "basic": float(payload.basic),
            "house_rent": float(payload.house_rent),
            "transport": float(payload.transport),
            "medical": float(payload.medical),
            "other_allowance": float(payload.other_allowance),
            "effective_from": payload.effective_from,
        }
        if payload.notes is not None:
            data["notes"] = payload.notes

        resp = supabase.table("salary_structures").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create salary structure")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/salary-structures/{structure_id}")
def delete_salary_structure(structure_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete a salary structure version."""
    try:
        resp = (
            supabase.table("salary_structures")
            .update({"is_deleted": True})
            .eq("id", structure_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Salary structure not found")
        return {"message": "Salary structure removed", "structure_id": structure_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── SALARY ADVANCES ─────────────────────────────────────────────────────────

@router.get("/salary-advances", response_model=List[SalaryAdvanceResponse])
def list_salary_advances(
    employee_id: Optional[int] = Query(default=None),
    outstanding_only: bool = Query(default=False),
    tenant_id: str = Depends(get_tenant_id),
):
    """List salary advances, optionally only those with a remaining balance."""
    try:
        query = (
            supabase.table("salary_advances").select("*")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
        )
        if employee_id is not None:
            query = query.eq("employee_id", employee_id)
        if outstanding_only:
            query = query.gt("balance_remaining", 0)
        resp = query.order("advance_date", desc=True).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/salary-advances", response_model=SalaryAdvanceResponse, status_code=201)
def create_salary_advance(payload: SalaryAdvanceCreate, tenant_id: str = Depends(get_tenant_id)):
    """
    Issue a salary advance. Trigger posts Dr Salary Advances / Cr Cash and
    balance_remaining initializes to the full amount.
    """
    try:
        _assert_employee(tenant_id, payload.employee_id)
        cash_account_id = payload.cash_account_id or _resolve_cash_account(tenant_id)

        data = {
            "tenant_id": tenant_id,
            "employee_id": payload.employee_id,
            "amount": float(payload.amount),
            "advance_date": payload.advance_date,
            "cash_account_id": cash_account_id,
        }
        if payload.reason is not None:
            data["reason"] = payload.reason

        resp = supabase.table("salary_advances").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create salary advance")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/salary-advances/{advance_id}")
def delete_salary_advance(advance_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete a salary advance."""
    try:
        resp = (
            supabase.table("salary_advances")
            .update({"is_deleted": True})
            .eq("id", advance_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Salary advance not found")
        return {"message": "Salary advance removed", "advance_id": advance_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── PAYSLIPS ────────────────────────────────────────────────────────────────

@router.post("/payslips/generate", response_model=PayslipResponse, status_code=201)
def generate_payslip(payload: PayslipGenerateRequest, tenant_id: str = Depends(get_tenant_id)):
    """
    Generate (or refresh, if still draft) a draft payslip for an employee/period
    from their active salary structure. Returns the payslip.
    """
    try:
        _assert_employee(tenant_id, payload.employee_id)
        rpc_resp = supabase.rpc("generate_payslip", {
            "p_employee_id": payload.employee_id,
            "p_year": payload.year,
            "p_month": payload.month,
        }).execute()

        payslip_id = rpc_resp.data
        if not payslip_id:
            # ON CONFLICT update is skipped when the existing payslip is not a draft.
            raise HTTPException(
                status_code=409,
                detail="A non-draft payslip already exists for this employee/period",
            )

        resp = (
            supabase.table("payslips").select("*")
            .eq("id", payslip_id).eq("tenant_id", tenant_id)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Payslip not found after generation")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "No active salary_structure" in detail:
            raise HTTPException(status_code=400, detail=detail)
        raise HTTPException(status_code=500, detail=detail)


@router.get("/payslips", response_model=List[PayslipResponse])
def list_payslips(
    employee_id: Optional[int] = Query(default=None),
    year: Optional[int] = Query(default=None),
    month: Optional[int] = Query(default=None),
    status: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List payslips with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("payslips").select("*").eq("tenant_id", tenant_id)
        if employee_id is not None:
            query = query.eq("employee_id", employee_id)
        if year is not None:
            query = query.eq("year", year)
        if month is not None:
            query = query.eq("month", month)
        if status is not None:
            query = query.eq("status", status)
        resp = (
            query.order("year", desc=True).order("month", desc=True)
            .range(offset, offset + limit - 1).execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/payslips/{payslip_id}", response_model=PayslipResponse)
def get_payslip(payslip_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single payslip."""
    try:
        resp = (
            supabase.table("payslips").select("*")
            .eq("id", payslip_id).eq("tenant_id", tenant_id)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/payslips/{payslip_id}", response_model=PayslipResponse)
def update_payslip(payslip_id: int, payload: PayslipUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Edit a draft payslip's deduction inputs (only while status = 'draft')."""
    try:
        existing = (
            supabase.table("payslips").select("status")
            .eq("id", payslip_id).eq("tenant_id", tenant_id)
            .execute()
        )
        if not existing.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        if existing.data[0]["status"] != "draft":
            raise HTTPException(status_code=400, detail="Only draft payslips can be edited")

        data = {}
        for field in ("days_absent", "absence_deduction", "advance_recovery", "other_deduction"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = float(val)
        if payload.notes is not None:
            data["notes"] = payload.notes
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")

        resp = (
            supabase.table("payslips").update(data)
            .eq("id", payslip_id).eq("tenant_id", tenant_id).eq("status", "draft")
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/payslips/{payslip_id}/finalize", response_model=PayslipResponse)
def finalize_payslip(payslip_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Move a payslip from draft to finalized (locks the figures for payment)."""
    try:
        existing = (
            supabase.table("payslips").select("status")
            .eq("id", payslip_id).eq("tenant_id", tenant_id)
            .execute()
        )
        if not existing.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        if existing.data[0]["status"] != "draft":
            raise HTTPException(status_code=400, detail="Only draft payslips can be finalized")

        resp = (
            supabase.table("payslips")
            .update({"status": "finalized", "finalized_at": _now_iso()})
            .eq("id", payslip_id).eq("tenant_id", tenant_id).eq("status", "draft")
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/payslips/{payslip_id}/pay", status_code=201)
def pay_payslip(payslip_id: int, payload: PayslipPayRequest, tenant_id: str = Depends(get_tenant_id)):
    """
    Record the salary payment for a finalized payslip. Inserts a salary_payment
    linked to the payslip; the DB trigger posts the 3-line journal, marks the
    payslip 'paid', and recovers outstanding advances FIFO.
    """
    try:
        ps = (
            supabase.table("payslips").select("employee_id, net_payable, status")
            .eq("id", payslip_id).eq("tenant_id", tenant_id)
            .execute()
        )
        if not ps.data:
            raise HTTPException(status_code=404, detail="Payslip not found")
        payslip = ps.data[0]
        if payslip["status"] != "finalized":
            raise HTTPException(
                status_code=400,
                detail=f"Payslip must be finalized to pay (current status: {payslip['status']})",
            )

        cash_account_id = payload.cash_account_id or _resolve_cash_account(tenant_id)
        data = {
            "tenant_id": tenant_id,
            "employee_id": payslip["employee_id"],
            "amount": float(payslip["net_payable"]),
            "date": payload.date,
            "payslip_id": payslip_id,
            "cash_account_id": cash_account_id,
        }
        resp = supabase.table("salary_payments").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to record salary payment")
        return {
            "message": "Salary paid",
            "payslip_id": payslip_id,
            "salary_payment": resp.data[0],
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
