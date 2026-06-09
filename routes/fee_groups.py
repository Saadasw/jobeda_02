"""
Fee groups — a student's fee profile (Residential / Day / Free). Fee structures
(price lists) key on (year, class, fee_group). Reads are tenant-scoped; writes
require a finance role.
"""
from typing import List
from fastapi import APIRouter, Depends, HTTPException

from database import supabase
from dependencies import get_tenant_id, require_roles
from models.fee import FeeGroupCreate, FeeGroupUpdate, FeeGroupResponse

router = APIRouter(prefix="/fee-groups", tags=["Fee Groups"])

_ROLES = ("owner", "admin", "accountant")


@router.get("", response_model=List[FeeGroupResponse])
def list_fee_groups(tenant_id: str = Depends(get_tenant_id)):
    """List active fee groups."""
    try:
        resp = (
            supabase.table("fee_groups").select("*")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
            .order("name").execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=FeeGroupResponse, status_code=201)
def create_fee_group(payload: FeeGroupCreate, user: dict = Depends(require_roles(*_ROLES))):
    """Create a fee group."""
    tenant_id = user["tenant_id"]
    try:
        dup = (
            supabase.table("fee_groups").select("id")
            .eq("tenant_id", tenant_id).eq("name", payload.name).eq("is_deleted", False)
            .execute().data
        )
        if dup:
            raise HTTPException(status_code=409, detail="A fee group with this name already exists")
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("fee_groups").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create fee group")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{group_id}", response_model=FeeGroupResponse)
def update_fee_group(group_id: int, payload: FeeGroupUpdate, user: dict = Depends(require_roles(*_ROLES))):
    """Update a fee group."""
    tenant_id = user["tenant_id"]
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("fee_groups").update(data)
            .eq("id", group_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee group not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{group_id}")
def delete_fee_group(group_id: int, user: dict = Depends(require_roles(*_ROLES))):
    """Soft-delete a fee group (students keep their fee_group_id)."""
    tenant_id = user["tenant_id"]
    try:
        resp = (
            supabase.table("fee_groups").update({"is_deleted": True})
            .eq("id", group_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee group not found")
        return {"message": "Fee group archived", "group_id": group_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
