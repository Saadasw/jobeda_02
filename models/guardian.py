"""
Guardian models. One guardian can have many students (siblings share a guardian).
"""
from typing import Optional, Literal
from pydantic import BaseModel

GuardianRelation = Literal[
    "father", "mother", "grandfather", "grandmother",
    "uncle", "aunt", "brother", "sister", "guardian", "other",
]


class GuardianCreate(BaseModel):
    name: str
    phone: Optional[str] = None
    relation: Optional[GuardianRelation] = None
    email: Optional[str] = None
    occupation: Optional[str] = None
    address: Optional[str] = None


class GuardianUpdate(BaseModel):
    name: Optional[str] = None
    phone: Optional[str] = None
    relation: Optional[GuardianRelation] = None
    email: Optional[str] = None
    occupation: Optional[str] = None
    address: Optional[str] = None


class GuardianResponse(BaseModel):
    id: int
    tenant_id: str
    name: str
    phone: Optional[str] = None
    relation: Optional[str] = None
    email: Optional[str] = None
    occupation: Optional[str] = None
    address: Optional[str] = None
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
