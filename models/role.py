"""
Role Pydantic models. System roles (owner/admin/accountant/teacher/viewer) are
seeded in migration 018 and protected by a DB trigger.
"""
from typing import Optional
from pydantic import BaseModel


class RoleCreate(BaseModel):
    name: str
    description: Optional[str] = None


class RoleUpdate(BaseModel):
    description: Optional[str] = None


class RoleResponse(BaseModel):
    id: int
    name: str
    description: Optional[str] = None
    is_system: Optional[bool] = True
    created_at: Optional[str] = None
