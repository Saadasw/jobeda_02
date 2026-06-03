"""
User Pydantic models. Users belong to a tenant and reference a role (migration 019).
Passwords are never returned; only password_hash is stored (bcrypt).
"""
from typing import Optional
from pydantic import BaseModel, EmailStr, Field


class UserCreate(BaseModel):
    """Admin/owner creates a user directly (tenant comes from the request context)."""
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=1)
    phone: Optional[str] = None
    role_id: int


class UserUpdate(BaseModel):
    full_name: Optional[str] = None
    phone: Optional[str] = None
    role_id: Optional[int] = None
    is_active: Optional[bool] = None


class UserResponse(BaseModel):
    id: str
    tenant_id: str
    email: str
    full_name: str
    phone: Optional[str] = None
    role_id: int
    role_name: Optional[str] = None
    is_active: Optional[bool] = True
    last_login: Optional[str] = None
    created_at: Optional[str] = None
