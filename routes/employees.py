"""
Employees routes — CRUD with soft delete and pagination.
"""
import math
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.employee import EmployeeCreate, EmployeeUpdate, EmployeeResponse
from models.common import PaginatedResponse

router = APIRouter(prefix="/employees", tags=["Employees"])


@router.get("", response_model=PaginatedResponse[EmployeeResponse])
def list_employees(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    role: Optional[str] = Query(default=None),
    search: Optional[str] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List all active employees with pagination and filters."""
    try:
        count_query = supabase.table("employees").select("id", count="exact").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if role:
            count_query = count_query.eq("role", role)
        if search:
            count_query = count_query.ilike("name", f"%{search}%")
        count_resp = count_query.execute()
        total = count_resp.count if count_resp.count is not None else len(count_resp.data)

        offset = (page - 1) * limit
        query = supabase.table("employees").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if role:
            query = query.eq("role", role)
        if search:
            query = query.ilike("name", f"%{search}%")
        resp = query.order("id").range(offset, offset + limit - 1).execute()

        return PaginatedResponse(
            data=resp.data,
            page=page,
            limit=limit,
            total=total,
            total_pages=math.ceil(total / limit) if total > 0 else 1,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=EmployeeResponse, status_code=201)
def create_employee(employee: EmployeeCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new employee."""
    try:
        data = employee.model_dump()
        data["tenant_id"] = tenant_id
        # Convert Decimal to string for JSON serialization
        if data.get("salary") is not None:
            data["salary"] = float(data["salary"])

        resp = supabase.table("employees").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create employee")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{employee_id}", response_model=EmployeeResponse)
def get_employee(employee_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a specific employee by ID."""
    try:
        resp = (
            supabase.table("employees")
            .select("*")
            .eq("id", employee_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Employee not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{employee_id}", response_model=EmployeeResponse)
def update_employee(employee_id: int, employee: EmployeeUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an existing employee."""
    try:
        data = {k: v for k, v in employee.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        if "salary" in data:
            data["salary"] = float(data["salary"])
        data["updated_at"] = datetime.utcnow().isoformat()

        resp = (
            supabase.table("employees")
            .update(data)
            .eq("id", employee_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Employee not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{employee_id}")
def delete_employee(employee_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete an employee."""
    try:
        resp = (
            supabase.table("employees")
            .update({
                "is_deleted": True,
                "deleted_at": datetime.utcnow().isoformat(),
            })
            .eq("id", employee_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Employee not found")
        return {"message": "Employee archived successfully", "employee_id": employee_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
