"""
Auth request/response models: registration, login, token refresh, password
reset, invitations. Opaque tokens (refresh/reset/invite) are returned to the
caller once and stored only as SHA-256 hashes (migration 020).
"""
from typing import Optional
from pydantic import BaseModel, EmailStr, Field

from models.user import UserResponse


# ─── Registration (founder onboarding: tenant + owner in one step) ────────────
class RegisterRequest(BaseModel):
    tenant_name: str = Field(min_length=1)
    slug: str = Field(pattern=r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", min_length=2, max_length=50)
    full_name: str = Field(min_length=1)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    phone: Optional[str] = None


# ─── Login / tokens ──────────────────────────────────────────────────────────
class LoginRequest(BaseModel):
    email: EmailStr
    password: str
    # Email is unique only per tenant; disambiguate when one email exists in many.
    tenant_slug: Optional[str] = None
    tenant_id: Optional[str] = None


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    refresh_token: str
    expires_in: int  # access-token lifetime in seconds
    user: UserResponse


class RefreshRequest(BaseModel):
    refresh_token: str


class LogoutRequest(BaseModel):
    refresh_token: str


# ─── Password reset ──────────────────────────────────────────────────────────
class PasswordResetRequest(BaseModel):
    email: EmailStr
    tenant_slug: Optional[str] = None
    tenant_id: Optional[str] = None


class PasswordResetConfirm(BaseModel):
    token: str
    new_password: str = Field(min_length=8, max_length=128)


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8, max_length=128)


# ─── Invitations ─────────────────────────────────────────────────────────────
class InvitationCreate(BaseModel):
    email: EmailStr
    role_id: int


class InvitationResponse(BaseModel):
    id: str
    tenant_id: str
    email: str
    role_id: int
    status: str
    expires_at: Optional[str] = None
    accepted_at: Optional[str] = None
    created_at: Optional[str] = None
    # Plaintext token: present ONLY in the create response (dev; no email yet).
    token: Optional[str] = None


class AcceptInvitationRequest(BaseModel):
    token: str
    full_name: str = Field(min_length=1)
    password: str = Field(min_length=8, max_length=128)
    phone: Optional[str] = None
