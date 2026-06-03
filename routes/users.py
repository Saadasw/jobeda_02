"""
User management + invitations (tenant-scoped, owner/admin only).

Users are deactivated rather than hard-deleted because audit FKs
(created_by/updated_by, journal authorship, ...) reference users(id) with
ON DELETE RESTRICT. Invitations carry an owner-role guard at the DB level.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request

from database import supabase
from dependencies import require_roles
from models.auth import InvitationCreate, InvitationResponse
from models.user import UserCreate, UserUpdate, UserResponse
from security import hash_password, generate_secret_token, hash_token
from services.auth_service import audit_log

router = APIRouter(prefix="/users", tags=["Users"])

_USER_COLUMNS = (
    "id, tenant_id, email, full_name, phone, role_id, is_active, last_login, "
    "created_at, roles(name)"
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _flatten_role(user: dict) -> dict:
    role = user.get("roles")
    user["role_name"] = role.get("name") if isinstance(role, dict) else None
    return user


# ─── Users ───────────────────────────────────────────────────────────────────
@router.get("", response_model=List[UserResponse])
def list_users(
    is_active: Optional[bool] = None,
    user: dict = Depends(require_roles("owner", "admin")),
):
    """List users in the caller's tenant."""
    try:
        query = supabase.table("users").select(_USER_COLUMNS).eq("tenant_id", user["tenant_id"])
        if is_active is not None:
            query = query.eq("is_active", is_active)
        resp = query.order("created_at").execute()
        return [_flatten_role(u) for u in resp.data]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{user_id}", response_model=UserResponse)
def get_user(user_id: str, user: dict = Depends(require_roles("owner", "admin"))):
    """Get a single user in the caller's tenant."""
    try:
        resp = (
            supabase.table("users").select(_USER_COLUMNS)
            .eq("id", user_id).eq("tenant_id", user["tenant_id"]).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="User not found")
        return _flatten_role(resp.data[0])
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=UserResponse, status_code=201)
def create_user(
    payload: UserCreate,
    request: Request,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """Create a user directly in the caller's tenant (owner is created via /auth/register only)."""
    try:
        resp = supabase.table("users").insert({
            "tenant_id": actor["tenant_id"],
            "email": payload.email,
            "password_hash": hash_password(payload.password),
            "full_name": payload.full_name,
            "phone": payload.phone,
            "role_id": payload.role_id,
            "created_by": actor["id"],
        }).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create user")
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "uq_users_tenant_email" in detail or "duplicate" in detail.lower():
            raise HTTPException(status_code=409, detail="A user with this email already exists")
        if "only one owner allowed" in detail.lower():
            raise HTTPException(status_code=409, detail="This tenant already has an owner")
        raise HTTPException(status_code=500, detail=detail)

    full = supabase.table("users").select(_USER_COLUMNS).eq("id", resp.data[0]["id"]).execute()
    return _flatten_role(full.data[0])


@router.put("/{user_id}", response_model=UserResponse)
def update_user(
    user_id: str,
    payload: UserUpdate,
    request: Request,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """Update a user's profile, role, or active status (within the caller's tenant)."""
    data = payload.model_dump(exclude_none=True)
    if not data:
        raise HTTPException(status_code=400, detail="No data provided")
    data["updated_at"] = _now_iso()
    data["updated_by"] = actor["id"]
    try:
        resp = (
            supabase.table("users").update(data)
            .eq("id", user_id).eq("tenant_id", actor["tenant_id"]).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="User not found")
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "only one owner allowed" in detail.lower():
            raise HTTPException(status_code=409, detail="This tenant already has an owner")
        raise HTTPException(status_code=500, detail=detail)

    if "role_id" in data:
        audit_log("role_changed", tenant_id=actor["tenant_id"], user_id=user_id,
                  detail={"role_id": data["role_id"], "by": actor["id"]}, request=request)
    full = supabase.table("users").select(_USER_COLUMNS).eq("id", user_id).execute()
    return _flatten_role(full.data[0])


@router.delete("/{user_id}")
def deactivate_user(
    user_id: str,
    request: Request,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """Deactivate a user (soft). Owners cannot deactivate themselves."""
    if user_id == actor["id"]:
        raise HTTPException(status_code=400, detail="You cannot deactivate your own account")
    resp = (
        supabase.table("users").update({"is_active": False, "updated_at": _now_iso(),
                                        "updated_by": actor["id"]})
        .eq("id", user_id).eq("tenant_id", actor["tenant_id"]).execute()
    )
    if not resp.data:
        raise HTTPException(status_code=404, detail="User not found")
    audit_log("user_deactivated", tenant_id=actor["tenant_id"], user_id=user_id,
              detail={"by": actor["id"]}, request=request)
    return {"message": "User deactivated", "user_id": user_id}


# ─── Invitations ─────────────────────────────────────────────────────────────
@router.post("/invitations", response_model=InvitationResponse, status_code=201)
def create_invitation(
    payload: InvitationCreate,
    request: Request,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """Invite a user to the caller's tenant. The plaintext token is returned once."""
    invite_plain = generate_secret_token()
    try:
        resp = supabase.table("invitations").insert({
            "tenant_id": actor["tenant_id"],
            "email": payload.email,
            "role_id": payload.role_id,
            "invited_by": actor["id"],
            "token_hash": hash_token(invite_plain),
        }).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create invitation")
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if 'role "owner"' in detail or "invite a user with role" in detail.lower():
            raise HTTPException(status_code=400, detail="Cannot invite a user as owner")
        raise HTTPException(status_code=500, detail=detail)

    audit_log("invitation_sent", tenant_id=actor["tenant_id"], user_id=actor["id"],
              detail={"email": payload.email, "role_id": payload.role_id}, request=request)
    invite = resp.data[0]
    invite["token"] = invite_plain  # surfaced once (dev; no email transport yet)
    return invite


@router.get("/invitations/list", response_model=List[InvitationResponse])
def list_invitations(
    status_filter: Optional[str] = None,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """List invitations for the caller's tenant. Token hashes are never returned."""
    try:
        query = (
            supabase.table("invitations")
            .select("id, tenant_id, email, role_id, status, expires_at, accepted_at, created_at")
            .eq("tenant_id", actor["tenant_id"])
        )
        if status_filter is not None:
            query = query.eq("status", status_filter)
        resp = query.order("created_at", desc=True).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/invitations/{invitation_id}/revoke")
def revoke_invitation(
    invitation_id: str,
    actor: dict = Depends(require_roles("owner", "admin")),
):
    """Revoke a pending invitation."""
    resp = (
        supabase.table("invitations").update({"status": "revoked"})
        .eq("id", invitation_id).eq("tenant_id", actor["tenant_id"])
        .eq("status", "pending").execute()
    )
    if not resp.data:
        raise HTTPException(status_code=404, detail="Pending invitation not found")
    return {"message": "Invitation revoked", "invitation_id": invitation_id}
