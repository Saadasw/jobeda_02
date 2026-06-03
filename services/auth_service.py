"""
Auth service helpers: best-effort security audit logging and tenant resolution.

The audit log (migration 023) is append-only and decoupled from the request
path on purpose — a logging failure must never block a login or break a flow.
"""
from typing import Optional

from fastapi import Request

from database import supabase


def audit_log(
    event: str,
    *,
    tenant_id: Optional[str] = None,
    user_id: Optional[str] = None,
    detail: Optional[dict] = None,
    request: Optional[Request] = None,
) -> None:
    """Append a row to auth_audit_log. Never raises — logging is best-effort."""
    row = {"event": event}
    if tenant_id is not None:
        row["tenant_id"] = tenant_id
    if user_id is not None:
        row["user_id"] = user_id
    if detail is not None:
        row["detail"] = detail
    if request is not None:
        client = request.client
        row["ip_address"] = client.host if client else None
        row["user_agent"] = request.headers.get("user-agent")
    try:
        supabase.table("auth_audit_log").insert(row).execute()
    except Exception:
        pass


def resolve_tenant_id(
    tenant_id: Optional[str] = None,
    tenant_slug: Optional[str] = None,
) -> Optional[str]:
    """
    Resolve an active tenant id from an explicit id or a slug.
    Returns the id, or None if not found / not provided.
    """
    if tenant_id:
        resp = (
            supabase.table("tenants")
            .select("id")
            .eq("id", tenant_id)
            .eq("is_active", True)
            .execute()
        )
        return resp.data[0]["id"] if resp.data else None

    if tenant_slug:
        resp = (
            supabase.table("tenants")
            .select("id")
            .eq("slug", tenant_slug)
            .eq("is_active", True)
            .execute()
        )
        return resp.data[0]["id"] if resp.data else None

    return None
