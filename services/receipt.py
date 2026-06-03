"""
Receipt number generation service.
Generates receipt numbers per tenant via the generate_receipt_no(p_tenant_id)
DB function (format {PREFIX}-{YEAR}-{SEQ}, prefix from tenant_settings).
"""
from database import supabase


def generate_receipt_no(tenant_id: str) -> str:
    """
    Generate the next receipt number for a tenant via the PostgreSQL function.
    Falls back to a Python-based, tenant-scoped count if the RPC fails.
    """
    try:
        resp = supabase.rpc("generate_receipt_no", {"p_tenant_id": tenant_id}).execute()
        if resp.data:
            return resp.data
    except Exception:
        pass

    # Fallback: count existing payments for this tenant and increment.
    from datetime import datetime
    year = datetime.utcnow().year
    count_resp = (
        supabase.table("payments")
        .select("id", count="exact")
        .eq("tenant_id", tenant_id)
        .execute()
    )
    seq = (count_resp.count or 0) + 1
    return f"PAY-{year}-{seq:04d}"
