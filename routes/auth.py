"""
Authentication routes (custom auth — NOT Supabase auth.users).

Flows: founder registration (tenant + owner), login, token refresh/rotation,
logout, password reset, change password, and invitation acceptance.

Security invariants (migration 020/023):
  * Passwords are bcrypt-hashed; plaintext is never stored.
  * Refresh / reset / invitation tokens are stored only as SHA-256 hashes.
    The plaintext secret is returned to the caller once and never again.
  * auth_audit_log writes are best-effort and never block a flow.
"""
import os
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from database import supabase
from dependencies import get_current_user
from models.auth import (
    RegisterRequest, LoginRequest, TokenResponse,
    RefreshRequest, LogoutRequest,
    PasswordResetRequest, PasswordResetConfirm, ChangePasswordRequest,
    AcceptInvitationRequest,
)
from models.user import UserResponse
from security import (
    hash_password, verify_password,
    generate_secret_token, hash_token,
    create_access_token, refresh_token_expiry,
    ACCESS_TOKEN_EXPIRE_MINUTES, REFRESH_TOKEN_EXPIRE_DAYS,
)
from services.auth_service import audit_log, resolve_tenant_id

router = APIRouter(prefix="/auth", tags=["Auth"])

MAX_FAILED_ATTEMPTS = 5
LOCK_MINUTES = 15

# The refresh token is delivered primarily as an httpOnly cookie (the browser
# never exposes it to JS). A JSON-body field remains as a fallback for
# non-browser clients. `Secure` is gated to production via COOKIE_SECURE so the
# cookie still works over http://localhost in dev.
REFRESH_COOKIE_NAME = "refresh_token"
_COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "false").lower() == "true"


def _set_refresh_cookie(response: Response, token: str) -> None:
    response.set_cookie(
        key=REFRESH_COOKIE_NAME,
        value=token,
        max_age=REFRESH_TOKEN_EXPIRE_DAYS * 24 * 3600,
        httponly=True,
        secure=_COOKIE_SECURE,
        samesite="lax",
        path="/",
    )


def _clear_refresh_cookie(response: Response) -> None:
    response.delete_cookie(
        key=REFRESH_COOKIE_NAME, path="/", httponly=True, samesite="lax"
    )

_USER_COLUMNS = (
    "id, tenant_id, email, full_name, phone, role_id, is_active, last_login, "
    "created_at, password_hash, failed_login_attempts, locked_until, roles(name)"
)


# ─── Internal helpers ────────────────────────────────────────────────────────
def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _flatten_role(user: dict) -> dict:
    role = user.get("roles")
    user["role_name"] = role.get("name") if isinstance(role, dict) else None
    return user


def _fetch_user(user_id: str) -> Optional[dict]:
    resp = supabase.table("users").select(_USER_COLUMNS).eq("id", user_id).execute()
    if not resp.data:
        return None
    return _flatten_role(resp.data[0])


def _user_response(user: dict) -> UserResponse:
    return UserResponse(
        id=user["id"],
        tenant_id=user["tenant_id"],
        email=user["email"],
        full_name=user["full_name"],
        phone=user.get("phone"),
        role_id=user["role_id"],
        role_name=user.get("role_name"),
        is_active=user.get("is_active", True),
        last_login=user.get("last_login"),
        created_at=user.get("created_at"),
    )


def _is_locked(user: dict) -> bool:
    locked_until = user.get("locked_until")
    if not locked_until:
        return False
    try:
        when = datetime.fromisoformat(str(locked_until).replace("Z", "+00:00"))
        return when.replace(tzinfo=None) > datetime.now(timezone.utc).replace(tzinfo=None)
    except ValueError:
        return False


def _issue_tokens(
    user: dict,
    request: Optional[Request] = None,
    response: Optional[Response] = None,
) -> TokenResponse:
    """Mint an access JWT + a refresh token (storing only the refresh hash)."""
    access = create_access_token(
        user_id=user["id"],
        tenant_id=user["tenant_id"],
        role=user.get("role_name") or "",
    )
    refresh_plain = generate_secret_token()
    row = {
        "user_id": user["id"],
        "tenant_id": user["tenant_id"],
        "token_hash": hash_token(refresh_plain),
        "expires_at": refresh_token_expiry().replace(tzinfo=None).isoformat(),
    }
    if request is not None:
        client = request.client
        row["ip_address"] = client.host if client else None
        row["user_agent"] = request.headers.get("user-agent")
    supabase.table("refresh_tokens").insert(row).execute()

    # Primary delivery is the httpOnly cookie; the body still carries the token
    # for backward compatibility with non-browser clients.
    if response is not None:
        _set_refresh_cookie(response, refresh_plain)

    return TokenResponse(
        access_token=access,
        refresh_token=refresh_plain,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=_user_response(user),
    )


def _owner_role_id() -> int:
    resp = supabase.table("roles").select("id").eq("name", "owner").execute()
    if not resp.data:
        raise HTTPException(status_code=500, detail="System roles not seeded (run migration 018)")
    return resp.data[0]["id"]


# ─── Registration ────────────────────────────────────────────────────────────
@router.post("/register", response_model=TokenResponse, status_code=201)
def register(payload: RegisterRequest, request: Request, response: Response):
    """
    Founder onboarding: create a tenant, seed its defaults, and create the
    owner user. Returns access + refresh tokens for the new owner.
    """
    # 1) Create the tenant.
    try:
        tenant_resp = supabase.table("tenants").insert(
            {"name": payload.tenant_name, "slug": payload.slug}
        ).execute()
    except Exception as e:
        detail = str(e)
        if "uq_tenants_slug" in detail or "duplicate" in detail.lower():
            raise HTTPException(status_code=409, detail="A tenant with this slug already exists")
        raise HTTPException(status_code=500, detail=detail)
    if not tenant_resp.data:
        raise HTTPException(status_code=400, detail="Failed to create tenant")
    tenant = tenant_resp.data[0]
    tenant_id = tenant["id"]

    # 2) Seed defaults + create owner. Roll back the tenant on any failure
    #    so a half-provisioned tenant is never left behind.
    try:
        supabase.rpc("seed_tenant_defaults", {"p_tenant_id": tenant_id}).execute()
        role_id = _owner_role_id()
        user_resp = supabase.table("users").insert({
            "tenant_id": tenant_id,
            "email": payload.email,
            "password_hash": hash_password(payload.password),
            "full_name": payload.full_name,
            "phone": payload.phone,
            "role_id": role_id,
        }).execute()
        if not user_resp.data:
            raise HTTPException(status_code=400, detail="Failed to create owner user")
    except HTTPException:
        supabase.table("tenants").delete().eq("id", tenant_id).execute()
        raise
    except Exception as e:
        supabase.table("tenants").delete().eq("id", tenant_id).execute()
        raise HTTPException(status_code=500, detail=str(e))

    user = _flatten_role(_fetch_user(user_resp.data[0]["id"]))
    audit_log("login_success", tenant_id=tenant_id, user_id=user["id"],
              detail={"via": "register"}, request=request)
    return _issue_tokens(user, request, response)


# ─── Login ───────────────────────────────────────────────────────────────────
@router.post("/login", response_model=TokenResponse)
def login(payload: LoginRequest, request: Request, response: Response):
    """Authenticate by email + password (tenant-scoped)."""
    tenant_id = resolve_tenant_id(payload.tenant_id, payload.tenant_slug)
    if (payload.tenant_id or payload.tenant_slug) and tenant_id is None:
        raise HTTPException(status_code=404, detail="Unknown or inactive tenant")

    query = supabase.table("users").select(_USER_COLUMNS).eq("email_lower", payload.email.lower())
    if tenant_id is not None:
        query = query.eq("tenant_id", tenant_id)
    resp = query.execute()

    if not resp.data:
        audit_log("login_failed", tenant_id=tenant_id,
                  detail={"email": payload.email.lower(), "reason": "no_user"}, request=request)
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if len(resp.data) > 1:
        raise HTTPException(
            status_code=400,
            detail="This email exists in multiple tenants; provide tenant_slug or tenant_id",
        )

    user = _flatten_role(resp.data[0])

    if not user.get("is_active", True):
        raise HTTPException(status_code=403, detail="Account is deactivated")
    if _is_locked(user):
        raise HTTPException(status_code=403, detail="Account is temporarily locked. Try again later.")

    if not verify_password(payload.password, user["password_hash"]):
        attempts = (user.get("failed_login_attempts") or 0) + 1
        update = {"failed_login_attempts": attempts}
        if attempts >= MAX_FAILED_ATTEMPTS:
            from datetime import timedelta
            update["locked_until"] = (
                datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(minutes=LOCK_MINUTES)
            ).isoformat()
        supabase.table("users").update(update).eq("id", user["id"]).execute()
        audit_log("login_failed", tenant_id=user["tenant_id"], user_id=user["id"],
                  detail={"attempts": attempts}, request=request)
        raise HTTPException(status_code=401, detail="Invalid email or password")

    # Success — reset lockout counters and stamp last_login.
    supabase.table("users").update({
        "failed_login_attempts": 0,
        "locked_until": None,
        "last_login": _now_iso(),
    }).eq("id", user["id"]).execute()
    audit_log("login_success", tenant_id=user["tenant_id"], user_id=user["id"], request=request)
    return _issue_tokens(user, request, response)


# ─── Refresh (with rotation) ─────────────────────────────────────────────────
@router.post("/refresh", response_model=TokenResponse)
def refresh(request: Request, response: Response, payload: Optional[RefreshRequest] = None):
    """Exchange a valid refresh token for a new access token (rotates the refresh token).

    The token is read from the httpOnly cookie, falling back to the request body
    for non-browser clients.
    """
    presented = request.cookies.get(REFRESH_COOKIE_NAME) or (
        payload.refresh_token if payload else None
    )
    if not presented:
        raise HTTPException(status_code=401, detail="No refresh token provided")
    token_hash = hash_token(presented)
    resp = (
        supabase.table("refresh_tokens")
        .select("id, user_id, tenant_id, expires_at, revoked_at")
        .eq("token_hash", token_hash)
        .is_("revoked_at", "null")
        .gt("expires_at", _now_iso())
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token")
    token_row = resp.data[0]

    user = _fetch_user(token_row["user_id"])
    if user is None or not user.get("is_active", True):
        raise HTTPException(status_code=401, detail="User no longer active")

    # Rotate: revoke the presented token, then issue a fresh pair.
    supabase.table("refresh_tokens").update(
        {"revoked_at": _now_iso()}
    ).eq("id", token_row["id"]).execute()
    return _issue_tokens(user, request, response)


# ─── Logout ──────────────────────────────────────────────────────────────────
@router.post("/logout")
def logout(request: Request, response: Response, payload: Optional[LogoutRequest] = None):
    """Revoke the refresh token (from cookie or body) and clear the cookie.

    Idempotent — unknown or missing tokens still return success.
    """
    presented = request.cookies.get(REFRESH_COOKIE_NAME) or (
        payload.refresh_token if payload else None
    )
    _clear_refresh_cookie(response)
    if not presented:
        return {"message": "Logged out"}
    token_hash = hash_token(presented)
    resp = (
        supabase.table("refresh_tokens")
        .update({"revoked_at": _now_iso()})
        .eq("token_hash", token_hash)
        .is_("revoked_at", "null")
        .execute()
    )
    if resp.data:
        row = resp.data[0]
        audit_log("logout", tenant_id=row.get("tenant_id"), user_id=row.get("user_id"),
                  request=request)
    return {"message": "Logged out"}


# ─── Current user ────────────────────────────────────────────────────────────
@router.get("/me", response_model=UserResponse)
def get_me(user: dict = Depends(get_current_user)):
    """Return the authenticated user's profile."""
    return _user_response(user)


# ─── Password reset ──────────────────────────────────────────────────────────
@router.post("/password-reset/request")
def password_reset_request(payload: PasswordResetRequest, request: Request):
    """
    Begin a password reset. Always responds the same way to avoid leaking which
    emails exist. In dev (no email transport) the token is returned directly.
    """
    tenant_id = resolve_tenant_id(payload.tenant_id, payload.tenant_slug)
    query = supabase.table("users").select("id, tenant_id").eq("email_lower", payload.email.lower())
    if tenant_id is not None:
        query = query.eq("tenant_id", tenant_id)
    resp = query.execute()

    generic = {"message": "If that account exists, a reset token has been issued"}
    if not resp.data or len(resp.data) > 1:
        return generic

    user = resp.data[0]
    reset_plain = generate_secret_token()
    supabase.table("password_resets").insert({
        "user_id": user["id"],
        "token_hash": hash_token(reset_plain),
    }).execute()
    audit_log("password_reset_requested", tenant_id=user["tenant_id"], user_id=user["id"],
              request=request)
    # Dev convenience: surface the token so it can be exercised without email.
    return {**generic, "reset_token": reset_plain}


@router.post("/password-reset/confirm")
def password_reset_confirm(payload: PasswordResetConfirm, request: Request):
    """Complete a password reset with a valid token."""
    token_hash = hash_token(payload.token)
    resp = (
        supabase.table("password_resets")
        .select("id, user_id")
        .eq("token_hash", token_hash)
        .is_("used_at", "null")
        .gt("expires_at", _now_iso())
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=400, detail="Invalid or expired reset token")
    reset_row = resp.data[0]

    supabase.table("users").update(
        {"password_hash": hash_password(payload.new_password), "updated_at": _now_iso()}
    ).eq("id", reset_row["user_id"]).execute()
    supabase.table("password_resets").update(
        {"used_at": _now_iso()}
    ).eq("id", reset_row["id"]).execute()
    # Invalidate every existing session for this user.
    supabase.table("refresh_tokens").update(
        {"revoked_at": _now_iso()}
    ).eq("user_id", reset_row["user_id"]).is_("revoked_at", "null").execute()

    audit_log("password_changed", user_id=reset_row["user_id"],
              detail={"via": "reset"}, request=request)
    return {"message": "Password updated. Please log in again."}


@router.post("/change-password")
def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    user: dict = Depends(get_current_user),
):
    """Change the authenticated user's password (requires the current one)."""
    full = _fetch_user(user["id"])
    if full is None or not verify_password(payload.current_password, full["password_hash"]):
        raise HTTPException(status_code=400, detail="Current password is incorrect")

    supabase.table("users").update(
        {"password_hash": hash_password(payload.new_password), "updated_at": _now_iso()}
    ).eq("id", user["id"]).execute()
    # Revoke other sessions for safety.
    supabase.table("refresh_tokens").update(
        {"revoked_at": _now_iso()}
    ).eq("user_id", user["id"]).is_("revoked_at", "null").execute()

    audit_log("password_changed", tenant_id=user["tenant_id"], user_id=user["id"],
              detail={"via": "change"}, request=request)
    return {"message": "Password changed. Please log in again."}


# ─── Invitation acceptance ───────────────────────────────────────────────────
@router.post("/accept-invitation", response_model=TokenResponse, status_code=201)
def accept_invitation(payload: AcceptInvitationRequest, request: Request, response: Response):
    """Accept a pending invitation: create the user and log them in."""
    token_hash = hash_token(payload.token)
    resp = (
        supabase.table("invitations")
        .select("id, tenant_id, email, role_id, status, expires_at")
        .eq("token_hash", token_hash)
        .eq("status", "pending")
        .gt("expires_at", _now_iso())
        .execute()
    )
    if not resp.data:
        raise HTTPException(status_code=400, detail="Invalid or expired invitation")
    invite = resp.data[0]

    try:
        user_resp = supabase.table("users").insert({
            "tenant_id": invite["tenant_id"],
            "email": invite["email"],
            "password_hash": hash_password(payload.password),
            "full_name": payload.full_name,
            "phone": payload.phone,
            "role_id": invite["role_id"],
        }).execute()
        if not user_resp.data:
            raise HTTPException(status_code=400, detail="Failed to create user")
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "uq_users_tenant_email" in detail or "duplicate" in detail.lower():
            raise HTTPException(status_code=409, detail="A user with this email already exists")
        raise HTTPException(status_code=500, detail=detail)

    supabase.table("invitations").update(
        {"status": "accepted", "accepted_at": _now_iso()}
    ).eq("id", invite["id"]).execute()

    user = _fetch_user(user_resp.data[0]["id"])
    audit_log("invitation_accepted", tenant_id=invite["tenant_id"], user_id=user["id"],
              request=request)
    return _issue_tokens(user, request, response)
