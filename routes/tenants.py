"""
Tenant administration + per-tenant settings.

Creating a tenant here also seeds its default chart of accounts, fee types,
academic year, and settings row via the seed_tenant_defaults() DB function.
For founder onboarding (tenant + owner user in one step) use /auth/register.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_current_user_optional
from models.tenant import (
    TenantCreate, TenantUpdate, TenantResponse,
    TenantSettingsUpdate, TenantSettingsResponse,
)

router = APIRouter(prefix="/tenants", tags=["Tenants"])


@router.post("", response_model=TenantResponse, status_code=201)
def create_tenant(payload: TenantCreate):
    """Create a tenant and seed its default accounts, fee types, year, and settings."""
    try:
        resp = supabase.table("tenants").insert(payload.model_dump(exclude_none=True)).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create tenant")
        tenant = resp.data[0]
        # Seed defaults (idempotent on the DB side).
        supabase.rpc("seed_tenant_defaults", {"p_tenant_id": tenant["id"]}).execute()
        return tenant
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "uq_tenants_slug" in detail or "duplicate" in detail.lower():
            raise HTTPException(status_code=409, detail="A tenant with this slug already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.get("", response_model=List[TenantResponse])
def list_tenants(
    is_active: Optional[bool] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
):
    """List tenants (administrative)."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("tenants").select("*")
        if is_active is not None:
            query = query.eq("is_active", is_active)
        resp = query.order("created_at", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{tenant_id}", response_model=TenantResponse)
def get_tenant(tenant_id: str):
    """Get a single tenant by id."""
    try:
        resp = supabase.table("tenants").select("*").eq("id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Tenant not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{tenant_id}", response_model=TenantResponse)
def update_tenant(tenant_id: str, payload: TenantUpdate):
    """Update tenant profile fields."""
    try:
        data = payload.model_dump(exclude_none=True)
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        data["updated_at"] = datetime.now(timezone.utc).isoformat()
        resp = supabase.table("tenants").update(data).eq("id", tenant_id).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Tenant not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── Settings ────────────────────────────────────────────────────────────────
@router.get("/{tenant_id}/settings", response_model=TenantSettingsResponse)
def get_tenant_settings(tenant_id: str):
    """Get a tenant's settings row (created lazily if missing)."""
    try:
        resp = supabase.table("tenant_settings").select("*").eq("tenant_id", tenant_id).execute()
        if not resp.data:
            # Lazily seed a default row so callers always get settings.
            created = supabase.table("tenant_settings").insert({"tenant_id": tenant_id}).execute()
            if not created.data:
                raise HTTPException(status_code=404, detail="Tenant settings not found")
            return created.data[0]
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{tenant_id}/settings", response_model=TenantSettingsResponse)
def update_tenant_settings(
    tenant_id: str,
    payload: TenantSettingsUpdate,
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Update a tenant's settings (currency, locale, receipt prefix, late-fee policy, ...)."""
    try:
        data = payload.model_dump(exclude_none=True)
        # Money fields → float for JSON serialization.
        for money in ("late_fee_value", "low_cash_threshold"):
            if money in data and data[money] is not None:
                data[money] = float(data[money])
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        data["updated_at"] = datetime.now(timezone.utc).isoformat()
        if user is not None:
            data["updated_by_id"] = user["id"]

        resp = supabase.table("tenant_settings").update(data).eq("tenant_id", tenant_id).execute()
        if not resp.data:
            # Settings row may not exist yet — insert it.
            data["tenant_id"] = tenant_id
            resp = supabase.table("tenant_settings").insert(data).execute()
            if not resp.data:
                raise HTTPException(status_code=404, detail="Tenant settings not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
