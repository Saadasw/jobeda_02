"""
Journal routes — read-only + reversal.
Journal entries are created by DB triggers. Never expose create/update/delete.
"""
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id

router = APIRouter(prefix="/journal", tags=["Journal"])


@router.get("")
def list_journal_entries(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List all journal entries (paginated)."""
    try:
        offset = (page - 1) * limit
        resp = (
            supabase.table("journal_entries")
            .select("*")
            .eq("tenant_id", tenant_id)
            .order("date", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{journal_id}")
def get_journal_entry(journal_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a journal entry with its debit/credit lines."""
    try:
        je_resp = supabase.table("journal_entries").select("*").eq("id", journal_id).eq("tenant_id", tenant_id).execute()
        if not je_resp.data:
            raise HTTPException(status_code=404, detail="Journal entry not found")
        entry = je_resp.data[0]

        # Get lines with account names (tenant-scoped)
        lines_resp = supabase.table("journal_lines").select("*").eq("journal_id", journal_id).eq("tenant_id", tenant_id).execute()

        # Enrich with account names
        enriched_lines = []
        for line in lines_resp.data:
            acct_resp = supabase.table("accounts").select("name").eq("id", line["account_id"]).eq("tenant_id", tenant_id).execute()
            acct_name = acct_resp.data[0]["name"] if acct_resp.data else "Unknown"
            enriched_lines.append({**line, "account_name": acct_name})

        return {**entry, "lines": enriched_lines}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{journal_id}/reverse")
def reverse_journal_entry(journal_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Create a reversal entry (swap Dr/Cr) and mark the original as reversed.
    This is the correct way to "undo" an accounting entry.
    """
    try:
        # Get original entry (tenant-scoped)
        je_resp = supabase.table("journal_entries").select("*").eq("id", journal_id).eq("tenant_id", tenant_id).execute()
        if not je_resp.data:
            raise HTTPException(status_code=404, detail="Journal entry not found")
        original = je_resp.data[0]

        if original.get("is_reversed"):
            raise HTTPException(status_code=400, detail="Entry is already reversed")

        # Get original lines
        lines_resp = supabase.table("journal_lines").select("*").eq("journal_id", journal_id).eq("tenant_id", tenant_id).execute()
        if not lines_resp.data:
            raise HTTPException(status_code=400, detail="No journal lines found")

        # Create reversal journal entry
        reversal_resp = supabase.table("journal_entries").insert({
            "date": original["date"],
            "description": f"REVERSAL: {original.get('description', '')}",
            "reference_type": "reversal",
            "reference_id": journal_id,
            "tenant_id": tenant_id,
        }).execute()
        if not reversal_resp.data:
            raise HTTPException(status_code=500, detail="Failed to create reversal entry")
        reversal_id = reversal_resp.data[0]["id"]

        # Create reversed lines (swap debit ↔ credit)
        for line in lines_resp.data:
            supabase.table("journal_lines").insert({
                "journal_id": reversal_id,
                "account_id": line["account_id"],
                "debit": line["credit"],    # swap
                "credit": line["debit"],    # swap
                "tenant_id": tenant_id,
            }).execute()

        # Mark original as reversed
        supabase.table("journal_entries").update({"is_reversed": True}).eq("id", journal_id).eq("tenant_id", tenant_id).execute()

        return {
            "message": "Journal entry reversed",
            "original_id": journal_id,
            "reversal_id": reversal_id,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
