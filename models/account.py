"""
Account (Chart of Accounts) Pydantic models.
"""
from typing import Optional
from pydantic import BaseModel


class AccountCreate(BaseModel):
    name: str
    type: str                          # asset / liability / equity / revenue / expense
    parent_id: Optional[int] = None


class AccountUpdate(BaseModel):
    name: Optional[str] = None
    type: Optional[str] = None
    parent_id: Optional[int] = None
    is_active: Optional[bool] = None


class AccountResponse(BaseModel):
    id: int
    name: str
    type: str
    parent_id: Optional[int] = None
    is_active: Optional[bool] = True
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
