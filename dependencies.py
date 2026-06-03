"""
FastAPI dependencies for multi-tenant scoping and authentication.

Two ways a request's tenant is resolved:
  1. If a valid `Authorization: Bearer <jwt>` is present, the tenant comes from
     the authenticated user (authoritative).
  2. Otherwise an `X-Tenant-ID` header is accepted and validated against the
     tenants table. This keeps data endpoints usable before a frontend login
     flow exists, without weakening the authenticated path.

Role checks: use `require_roles("owner", "admin")` as a route dependency.
"""
from typing import Optional

from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import jwt

from database import supabase
from security import decode_access_token

# auto_error=False so we can fall back to the X-Tenant-ID header path.
_bearer = HTTPBearer(auto_error=False)


def get_current_user_optional(
    creds: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
) -> Optional[dict]:
    """Return the authenticated user dict, or None if no/invalid token."""
    if creds is None:
        return None
    try:
        payload = decode_access_token(creds.credentials)
    except jwt.PyJWTError:
        return None

    user_id = payload.get("sub")
    if not user_id:
        return None

    resp = (
        supabase.table("users")
        .select("id, tenant_id, email, full_name, role_id, is_active, roles(name)")
        .eq("id", user_id)
        .execute()
    )
    if not resp.data:
        return None
    user = resp.data[0]
    if not user.get("is_active", True):
        return None

    # Flatten the joined role name for convenience.
    role = user.get("roles")
    user["role_name"] = role.get("name") if isinstance(role, dict) else payload.get("role")
    return user


def get_current_user(
    user: Optional[dict] = Depends(get_current_user_optional),
) -> dict:
    """Require a valid bearer token. Raises 401 otherwise."""
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


def get_tenant_id(
    user: Optional[dict] = Depends(get_current_user_optional),
    x_tenant_id: Optional[str] = Header(default=None, alias="X-Tenant-ID"),
) -> str:
    """
    Resolve the active tenant id. Prefers the authenticated user's tenant;
    falls back to a validated X-Tenant-ID header.
    """
    if user is not None:
        return user["tenant_id"]

    if not x_tenant_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Provide an Authorization bearer token or an X-Tenant-ID header",
        )

    resp = (
        supabase.table("tenants")
        .select("id")
        .eq("id", x_tenant_id)
        .eq("is_active", True)
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown or inactive tenant")
    return x_tenant_id


def require_roles(*allowed: str):
    """Dependency factory enforcing that the current user has one of `allowed` roles."""
    def _checker(user: dict = Depends(get_current_user)) -> dict:
        if user.get("role_name") not in allowed:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Requires one of roles: {', '.join(allowed)}",
            )
        return user
    return _checker
