"""
Payment finalization service.
Handles advance payments by calling the PostgreSQL finalize_payment() function.
"""
from database import supabase


def finalize_payment(payment_id: int) -> dict:
    """
    Finalize a payment: any unallocated amount becomes Unearned Revenue.
    Calls the DB function finalize_payment(p_payment_id) via RPC.
    """
    try:
        supabase.rpc("finalize_payment", {"p_payment_id": payment_id}).execute()
        return {"message": "Payment finalized", "payment_id": payment_id}
    except Exception as e:
        raise ValueError(f"Failed to finalize payment {payment_id}: {e}")
