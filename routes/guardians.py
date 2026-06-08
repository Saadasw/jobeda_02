"""
Guardians CRUD. Reads are tenant-scoped; writes require an admin/finance role.
A guardian groups siblings (students.guardian_id), and carries the phone used
for fee-reminder SMS.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, require_roles
from models.guardian import GuardianCreate, GuardianUpdate, GuardianResponse

router = APIRouter(prefix="/guardians", tags=["Guardians"])

_MANAGE_ROLES = ("owner", "admin", "accountant")


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


@router.get("", response_model=List[GuardianResponse])
def list_guardians(
    search: Optional[str] = Query(default=None, description="Match name or phone"),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List guardians (active), optionally searched by name or phone."""
    try:
        offset = (page - 1) * limit
        query = (
            supabase.table("guardians").select("*")
            .eq("tenant_id", tenant_id).eq("is_deleted", False)
        )
        if search:
            query = query.ilike("name", f"%{search}%")
        resp = query.order("name").range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=GuardianResponse, status_code=201)
def create_guardian(payload: GuardianCreate, user: dict = Depends(require_roles(*_MANAGE_ROLES))):
    """Create a guardian."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        data["tenant_id"] = user["tenant_id"]
        data["created_by_id"] = user["id"]
        resp = supabase.table("guardians").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create guardian")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{guardian_id}", response_model=GuardianResponse)
def get_guardian(guardian_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single guardian."""
    try:
        resp = (
            supabase.table("guardians").select("*")
            .eq("id", guardian_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Guardian not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{guardian_id}/students")
def list_guardian_students(guardian_id: int, tenant_id: str = Depends(get_tenant_id)):
    """List the students (siblings) attached to a guardian."""
    try:
        resp = (
            supabase.table("students")
            .select("id, name, registration_no, class, class_id, section_id")
            .eq("guardian_id", guardian_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
            .order("name").execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{guardian_id}", response_model=GuardianResponse)
def update_guardian(
    guardian_id: int,
    payload: GuardianUpdate,
    user: dict = Depends(require_roles(*_MANAGE_ROLES)),
):
    """Update a guardian."""
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (
            supabase.table("guardians").update(data)
            .eq("id", guardian_id).eq("tenant_id", user["tenant_id"]).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Guardian not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{guardian_id}")
def delete_guardian(guardian_id: int, user: dict = Depends(require_roles(*_MANAGE_ROLES))):
    """Soft-delete a guardian (students keep their guardian_id; FK is SET NULL only on hard delete)."""
    try:
        resp = (
            supabase.table("guardians")
            .update({"is_deleted": True, "deleted_at": _now_iso()})
            .eq("id", guardian_id).eq("tenant_id", user["tenant_id"]).eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Guardian not found")
        return {"message": "Guardian archived", "guardian_id": guardian_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
