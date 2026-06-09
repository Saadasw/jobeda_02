"""
Fee routes — fee types CRUD and fee assignment.
"""
import math
from datetime import datetime
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, get_financial_tenant_id, require_roles
from models.fee import (
    FeeTypeCreate, FeeTypeUpdate, FeeTypeResponse,
    FeeAssignCreate, FeeAssignResponse,
    FeeGenerateRequest, FeeGenerateManualRequest, FeeGenerateResult,
)
from services.fee_generation import generate_from_structures, generate_manual

router = APIRouter(tags=["Fees"])

_FIN_ROLES = ("owner", "admin", "accountant")


# ─── FEE TYPES ───────────────────────────────────────────────────────────────

@router.get("/fee-types", response_model=List[FeeTypeResponse])
def list_fee_types(tenant_id: str = Depends(get_tenant_id)):
    """List all active fee types."""
    try:
        resp = supabase.table("fee_types").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/fee-types", response_model=FeeTypeResponse, status_code=201)
def create_fee_type(payload: FeeTypeCreate, tenant_id: str = Depends(get_financial_tenant_id)):
    """Create a new fee type."""
    try:
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("fee_types").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create fee type")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/fee-types/{fee_type_id}", response_model=FeeTypeResponse)
def update_fee_type(fee_type_id: int, payload: FeeTypeUpdate, tenant_id: str = Depends(get_financial_tenant_id)):
    """Update a fee type."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = supabase.table("fee_types").update(data).eq("id", fee_type_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee type not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/fee-types/{fee_type_id}")
def delete_fee_type(fee_type_id: int, tenant_id: str = Depends(get_financial_tenant_id)):
    """Soft-delete a fee type."""
    try:
        resp = (
            supabase.table("fee_types")
            .update({"is_deleted": True, "deleted_at": datetime.utcnow().isoformat()})
            .eq("id", fee_type_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee type not found")
        return {"message": "Fee type archived", "fee_type_id": fee_type_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── FEE ASSIGNMENT ─────────────────────────────────────────────────────────

@router.post("/fees/assign", response_model=FeeAssignResponse, status_code=201)
def assign_fee(payload: FeeAssignCreate, tenant_id: str = Depends(get_financial_tenant_id)):
    """
    Assign a fee to a student for a specific month.
    Triggers trg_fee_assignment_journal → Dr Accounts Receivable / Cr Tuition Fees.
    UNIQUE(student_id, fee_type_id, month) prevents duplicates.
    """
    try:
        # Resolve account_id from fee_type if not provided (tenant-scoped)
        account_id = payload.account_id
        if account_id is None:
            ft_resp = (
                supabase.table("fee_types").select("account_id")
                .eq("id", payload.fee_type_id).eq("tenant_id", tenant_id).execute()
            )
            if not ft_resp.data:
                raise HTTPException(status_code=404, detail="Fee type not found")
            account_id = ft_resp.data[0]["account_id"]

        data = {
            "student_id": payload.student_id,
            "fee_type_id": payload.fee_type_id,
            "month": payload.month,
            "amount": float(payload.amount),
            "account_id": account_id,
            "tenant_id": tenant_id,
        }
        resp = supabase.table("fee_assignments").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to assign fee")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "uq_fee_per_student_per_month" in detail or "duplicate" in detail.lower():
            raise HTTPException(status_code=409, detail="Fee already assigned for this student/type/month")
        raise HTTPException(status_code=500, detail=detail)


@router.get("/fees", response_model=List[FeeAssignResponse])
def list_fees(
    student_id: Optional[int] = Query(default=None),
    month: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List fee assignments with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("fee_assignments").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if student_id:
            query = query.eq("student_id", student_id)
        if month:
            query = query.eq("month", month)
        resp = query.order("month", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/fees/{fee_id}")
def delete_fee(fee_id: int, tenant_id: str = Depends(get_financial_tenant_id)):
    """Soft-delete a fee assignment."""
    try:
        resp = (
            supabase.table("fee_assignments")
            .update({"is_deleted": True, "deleted_at": datetime.utcnow().isoformat()})
            .eq("id", fee_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee assignment not found")
        return {"message": "Fee assignment archived", "fee_id": fee_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── BULK GENERATION ─────────────────────────────────────────────────────────

@router.post("/fees/generate", response_model=FeeGenerateResult, tags=["Fee Generation"])
def generate_fees(payload: FeeGenerateRequest, user: dict = Depends(require_roles(*_FIN_ROLES))):
    """
    Generate fees for every active student in scope from their (class, fee_group)
    structure. Idempotent — skips any (student, fee_type, month) already billed.
    Pass dry_run=true for a preview (counts only, no inserts).
    """
    try:
        return generate_from_structures(
            user["tenant_id"], payload.academic_year_id, payload.month,
            class_id=payload.class_id, section_id=payload.section_id,
            fee_type_ids=payload.fee_type_ids, created_by_id=user.get("id"),
            dry_run=payload.dry_run,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/fees/generate-manual", response_model=FeeGenerateResult, tags=["Fee Generation"])
def generate_fees_manual(payload: FeeGenerateManualRequest, user: dict = Depends(require_roles(*_FIN_ROLES))):
    """
    Flat one-off charge of a single fee type to every active student in scope
    (ignores structures). Idempotent like /fees/generate.
    """
    try:
        return generate_manual(
            user["tenant_id"], payload.academic_year_id, payload.month,
            fee_type_id=payload.fee_type_id, amount=payload.amount,
            class_id=payload.class_id, section_id=payload.section_id,
            due_day=payload.due_day, created_by_id=user.get("id"),
            dry_run=payload.dry_run,
        )
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
