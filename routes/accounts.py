"""
Accounts (Chart of Accounts) routes — CRUD with soft delete.
"""
from datetime import datetime
from typing import List
from fastapi import APIRouter, Depends, HTTPException

from database import supabase
from dependencies import get_tenant_id
from models.account import AccountCreate, AccountUpdate, AccountResponse

router = APIRouter(prefix="/accounts", tags=["Accounts"])


@router.get("", response_model=List[AccountResponse])
def list_accounts(tenant_id: str = Depends(get_tenant_id)):
    """List all active accounts."""
    try:
        resp = supabase.table("accounts").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False).order("id").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=AccountResponse, status_code=201)
def create_account(account: AccountCreate, tenant_id: str = Depends(get_tenant_id)):
    """Create a new account."""
    try:
        data = account.model_dump()
        data["tenant_id"] = tenant_id
        resp = supabase.table("accounts").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create account")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{account_id}", response_model=AccountResponse)
def update_account(account_id: int, account: AccountUpdate, tenant_id: str = Depends(get_tenant_id)):
    """Update an account."""
    try:
        data = {k: v for k, v in account.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = supabase.table("accounts").update(data).eq("id", account_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Account not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{account_id}")
def delete_account(account_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Soft-delete an account."""
    try:
        resp = (
            supabase.table("accounts")
            .update({"is_deleted": True, "deleted_at": datetime.utcnow().isoformat()})
            .eq("id", account_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Account not found")
        return {"message": "Account archived", "account_id": account_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
