"""
Employee Pydantic models.
Uses Decimal for salary — never float for money.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel


class EmployeeCreate(BaseModel):
    name: str
    role: str                          # teacher / staff / admin
    phone: Optional[str] = None
    salary: Optional[Decimal] = None


class EmployeeUpdate(BaseModel):
    name: Optional[str] = None
    role: Optional[str] = None
    phone: Optional[str] = None
    salary: Optional[Decimal] = None
    is_active: Optional[bool] = None


class EmployeeResponse(BaseModel):
    id: int
    name: str
    role: str
    phone: Optional[str] = None
    salary: Optional[Decimal] = None
    is_active: Optional[bool] = True
    is_deleted: Optional[bool] = False
    created_at: Optional[str] = None
