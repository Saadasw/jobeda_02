"""
Fee discounts / waivers + due dates + late fees.

Discounts require an authenticated approver (fee_discounts.approved_by_id is
NOT NULL). Creating one auto-posts an accounting entry via a DB trigger, and the
allocation guard nets discounts + late fees out of the fee. Late-fee application
and the aging report are thin wrappers over the apply_late_fees / get_overdue_aging
PostgreSQL functions.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, require_roles
from models.discount import FeeDiscountCreate, FeeDiscountResponse, FeeDueDateUpdate

router = APIRouter(tags=["Discounts & Late Fees"])

# Roles allowed to approve waivers / adjust fee terms.
_FINANCE_ROLES = ("owner", "admin", "accountant")


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


# ─── FEE DISCOUNTS ───────────────────────────────────────────────────────────

@router.post("/fee-discounts", response_model=FeeDiscountResponse, status_code=201)
def create_discount(
    payload: FeeDiscountCreate,
    user: dict = Depends(require_roles(*_FINANCE_ROLES)),
):
    """
    Record a waiver on a fee assignment.
    DB trigger validates (no cross-tenant, total discount ≤ fee, net ≥ already-paid)
    and posts Dr Fee Discount / Cr Accounts Receivable.
    """
    try:
        data = {
            "tenant_id": user["tenant_id"],
            "fee_assignment_id": payload.fee_assignment_id,
            "amount": float(payload.amount),
            "reason": payload.reason,
            "approved_by_id": user["id"],
            "created_by_id": user["id"],
        }
        if payload.percent is not None:
            data["percent"] = float(payload.percent)
        if payload.notes is not None:
            data["notes"] = payload.notes

        resp = supabase.table("fee_discounts").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create discount")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        low = detail.lower()
        # Validation failures from trg_fee_discount_validate → 400, not 500.
        if any(k in low for k in ("exceed", "not found", "forbidden", "less than")):
            raise HTTPException(status_code=400, detail=detail)
        raise HTTPException(status_code=500, detail=detail)


@router.get("/fee-discounts", response_model=List[FeeDiscountResponse])
def list_discounts(
    fee_assignment_id: Optional[int] = Query(default=None),
    reason: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List active discounts, optionally filtered by fee assignment or reason."""
    try:
        offset = (page - 1) * limit
        query = (
            supabase.table("fee_discounts")
            .select("*")
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
        )
        if fee_assignment_id is not None:
            query = query.eq("fee_assignment_id", fee_assignment_id)
        if reason is not None:
            query = query.eq("reason", reason)
        resp = query.order("approved_at", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/fee-discounts/{discount_id}")
def delete_discount(
    discount_id: int,
    user: dict = Depends(require_roles(*_FINANCE_ROLES)),
):
    """Soft-delete a discount (restores the fee's net amount)."""
    try:
        resp = (
            supabase.table("fee_discounts")
            .update({"is_deleted": True, "deleted_at": _now_iso()})
            .eq("id", discount_id)
            .eq("tenant_id", user["tenant_id"])
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Discount not found")
        return {"message": "Discount removed", "discount_id": discount_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── DUE DATES ───────────────────────────────────────────────────────────────

@router.put("/fees/{fee_id}/due-date")
def set_fee_due_date(
    fee_id: int,
    payload: FeeDueDateUpdate,
    tenant_id: str = Depends(get_tenant_id),
):
    """Set or change the due date on a fee assignment."""
    try:
        resp = (
            supabase.table("fee_assignments")
            .update({"due_date": payload.due_date})
            .eq("id", fee_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee assignment not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── LATE FEES ───────────────────────────────────────────────────────────────

@router.post("/late-fees/apply")
def apply_late_fees_endpoint(
    as_of: Optional[str] = Query(default=None, description="ISO date; defaults to today"),
    tenant_id: str = Depends(get_tenant_id),
):
    """
    Apply the tenant's late-fee policy to overdue fees. Idempotent — safe to
    re-run. Returns how many fee rows had their late fee changed.
    """
    try:
        params = {"p_tenant_id": tenant_id}
        if as_of:
            params["p_as_of"] = as_of
        resp = supabase.rpc("apply_late_fees", params).execute()
        return {"changed": resp.data, "as_of": as_of}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/late-fees/aging")
def overdue_aging(
    as_of: Optional[str] = Query(default=None, description="ISO date; defaults to today"),
    tenant_id: str = Depends(get_tenant_id),
):
    """Overdue aging report: 1-30 / 31-60 / 61-90 / 90+ day buckets."""
    try:
        params = {"p_tenant_id": tenant_id}
        if as_of:
            params["p_as_of"] = as_of
        resp = supabase.rpc("get_overdue_aging", params).execute()
        return {"as_of": as_of, "buckets": resp.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
