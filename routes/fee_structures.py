"""
Fee structures — a price list per (academic_year, class, fee_group), with line
items (fee_type + amount + frequency + due_day). Reads are tenant-scoped; writes
require a finance role.
"""
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, require_roles
from models.fee import (
    FeeStructureCreate, FeeStructureUpdate, FeeStructureResponse,
    FeeStructureItemCreate, FeeStructureItemUpdate, FeeStructureItemResponse,
)

router = APIRouter(prefix="/fee-structures", tags=["Fee Structures"])

_ROLES = ("owner", "admin", "accountant")


def _name_maps(tenant_id):
    classes = {c["id"]: c["name"] for c in
               supabase.table("classes").select("id, name").eq("tenant_id", tenant_id).execute().data}
    groups = {g["id"]: g["name"] for g in
              supabase.table("fee_groups").select("id, name").eq("tenant_id", tenant_id).execute().data}
    types = {t["id"]: t["name"] for t in
             supabase.table("fee_types").select("id, name").eq("tenant_id", tenant_id).execute().data}
    return classes, groups, types


def _items_by_struct(struct_ids, types_map):
    if not struct_ids:
        return {}
    rows = (supabase.table("fee_structure_items").select("*")
            .in_("fee_structure_id", struct_ids).eq("is_deleted", False).execute().data)
    out = {}
    for r in rows:
        r["fee_type_name"] = types_map.get(r["fee_type_id"])
        out.setdefault(r["fee_structure_id"], []).append(r)
    return out


@router.get("", response_model=List[FeeStructureResponse])
def list_structures(
    academic_year_id: Optional[int] = Query(default=None),
    class_id: Optional[int] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List fee structures (with their items), optionally filtered by year/class."""
    try:
        q = (supabase.table("fee_structures").select("*")
             .eq("tenant_id", tenant_id).eq("is_deleted", False))
        if academic_year_id:
            q = q.eq("academic_year_id", academic_year_id)
        if class_id:
            q = q.eq("class_id", class_id)
        structs = q.order("class_id").execute().data
        classes, groups, types = _name_maps(tenant_id)
        items = _items_by_struct([s["id"] for s in structs], types)
        for s in structs:
            s["class_name"] = classes.get(s["class_id"])
            s["fee_group_name"] = groups.get(s["fee_group_id"])
            s["items"] = items.get(s["id"], [])
        return structs
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=FeeStructureResponse, status_code=201)
def create_structure(payload: FeeStructureCreate, user: dict = Depends(require_roles(*_ROLES))):
    """Create a price list for one (year, class, fee_group)."""
    tenant_id = user["tenant_id"]
    try:
        dup = (supabase.table("fee_structures").select("id")
               .eq("tenant_id", tenant_id)
               .eq("academic_year_id", payload.academic_year_id)
               .eq("class_id", payload.class_id)
               .eq("fee_group_id", payload.fee_group_id)
               .eq("is_deleted", False).execute().data)
        if dup:
            raise HTTPException(status_code=409,
                                detail="A fee structure already exists for this class & group this year")
        data = payload.model_dump()
        data["tenant_id"] = tenant_id
        data["created_by_id"] = user.get("id")
        resp = supabase.table("fee_structures").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create fee structure")
        row = resp.data[0]
        row["items"] = []
        return row
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{structure_id}", response_model=FeeStructureResponse)
def get_structure(structure_id: int, tenant_id: str = Depends(get_tenant_id)):
    """One structure with its items."""
    try:
        resp = (supabase.table("fee_structures").select("*")
                .eq("id", structure_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
                .execute().data)
        if not resp:
            raise HTTPException(status_code=404, detail="Fee structure not found")
        s = resp[0]
        classes, groups, types = _name_maps(tenant_id)
        s["class_name"] = classes.get(s["class_id"])
        s["fee_group_name"] = groups.get(s["fee_group_id"])
        s["items"] = _items_by_struct([s["id"]], types).get(s["id"], [])
        return s
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{structure_id}", response_model=FeeStructureResponse)
def update_structure(structure_id: int, payload: FeeStructureUpdate,
                     user: dict = Depends(require_roles(*_ROLES))):
    """Rename a structure."""
    tenant_id = user["tenant_id"]
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (supabase.table("fee_structures").update(data)
                .eq("id", structure_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute())
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee structure not found")
        return get_structure(structure_id, tenant_id)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{structure_id}")
def delete_structure(structure_id: int, user: dict = Depends(require_roles(*_ROLES))):
    """Soft-delete a structure and its items."""
    tenant_id = user["tenant_id"]
    try:
        resp = (supabase.table("fee_structures").update({"is_deleted": True})
                .eq("id", structure_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute())
        if not resp.data:
            raise HTTPException(status_code=404, detail="Fee structure not found")
        supabase.table("fee_structure_items").update({"is_deleted": True}) \
            .eq("fee_structure_id", structure_id).eq("tenant_id", tenant_id).execute()
        return {"message": "Fee structure archived", "structure_id": structure_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── Items ───────────────────────────────────────────────────────────────────

@router.post("/{structure_id}/items", response_model=FeeStructureItemResponse, status_code=201)
def add_item(structure_id: int, payload: FeeStructureItemCreate,
             user: dict = Depends(require_roles(*_ROLES))):
    """Add a line (fee type + amount + frequency + due day) to a structure."""
    tenant_id = user["tenant_id"]
    try:
        struct = (supabase.table("fee_structures").select("id")
                  .eq("id", structure_id).eq("tenant_id", tenant_id).eq("is_deleted", False)
                  .execute().data)
        if not struct:
            raise HTTPException(status_code=404, detail="Fee structure not found")
        dup = (supabase.table("fee_structure_items").select("id")
               .eq("fee_structure_id", structure_id).eq("fee_type_id", payload.fee_type_id)
               .eq("is_deleted", False).execute().data)
        if dup:
            raise HTTPException(status_code=409, detail="This fee type is already in the structure")
        data = payload.model_dump()
        data["amount"] = float(data["amount"])
        data["tenant_id"] = tenant_id
        data["fee_structure_id"] = structure_id
        resp = supabase.table("fee_structure_items").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to add item")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{structure_id}/items/{item_id}", response_model=FeeStructureItemResponse)
def update_item(structure_id: int, item_id: int, payload: FeeStructureItemUpdate,
                user: dict = Depends(require_roles(*_ROLES))):
    """Update an item's amount / frequency / due day."""
    tenant_id = user["tenant_id"]
    try:
        data = {k: v for k, v in payload.model_dump().items() if v is not None}
        if "amount" in data:
            data["amount"] = float(data["amount"])
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        resp = (supabase.table("fee_structure_items").update(data)
                .eq("id", item_id).eq("fee_structure_id", structure_id)
                .eq("tenant_id", tenant_id).eq("is_deleted", False).execute())
        if not resp.data:
            raise HTTPException(status_code=404, detail="Item not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{structure_id}/items/{item_id}")
def delete_item(structure_id: int, item_id: int, user: dict = Depends(require_roles(*_ROLES))):
    """Remove an item from a structure (soft delete)."""
    tenant_id = user["tenant_id"]
    try:
        resp = (supabase.table("fee_structure_items").update({"is_deleted": True})
                .eq("id", item_id).eq("fee_structure_id", structure_id)
                .eq("tenant_id", tenant_id).eq("is_deleted", False).execute())
        if not resp.data:
            raise HTTPException(status_code=404, detail="Item not found")
        return {"message": "Item removed", "item_id": item_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
