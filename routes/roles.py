"""
Roles. The 5 system roles are seeded and protected by a DB trigger
(cannot be renamed, demoted, or deleted). Custom roles are created with
is_system = FALSE so they remain editable/removable.
"""
from typing import List
from fastapi import APIRouter, HTTPException

from database import supabase
from models.role import RoleCreate, RoleUpdate, RoleResponse

router = APIRouter(prefix="/roles", tags=["Roles"])


@router.get("", response_model=List[RoleResponse])
def list_roles():
    """List all roles."""
    try:
        resp = supabase.table("roles").select("*").order("id").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=RoleResponse, status_code=201)
def create_role(payload: RoleCreate):
    """Create a custom (non-system) role."""
    try:
        data = payload.model_dump(exclude_none=True)
        data["is_system"] = False
        resp = supabase.table("roles").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create role")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "duplicate" in detail.lower() or "roles_name_key" in detail:
            raise HTTPException(status_code=409, detail="A role with this name already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.put("/{role_id}", response_model=RoleResponse)
def update_role(role_id: int, payload: RoleUpdate):
    """Update a role's description. System roles cannot be renamed (DB-enforced)."""
    try:
        data = payload.model_dump(exclude_none=True)
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = supabase.table("roles").update(data).eq("id", role_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Role not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{role_id}")
def delete_role(role_id: int):
    """Delete a custom role. System roles are protected (DB trigger raises)."""
    try:
        resp = supabase.table("roles").delete().eq("id", role_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Role not found")
        return {"message": "Role deleted", "role_id": role_id}
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "system role" in detail.lower():
            raise HTTPException(status_code=403, detail="Cannot delete a system role")
        raise HTTPException(status_code=500, detail=detail)
