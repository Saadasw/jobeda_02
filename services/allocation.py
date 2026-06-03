"""
Payment allocation service.
Auto-allocates a payment against the student's oldest unpaid fee assignments.
All queries and the resulting allocation rows are tenant-scoped.
"""
from decimal import Decimal
from database import supabase


def auto_allocate(payment_id: int, tenant_id: str) -> dict:
    """
    Auto-allocate a payment against unpaid fees (FIFO — oldest first).

    Returns a dict with:
      - allocated: total amount allocated
      - advance: unallocated remainder
      - allocations: list of allocation records created
    """
    # 1. Get payment details (scoped to tenant)
    pay_resp = (
        supabase.table("payments")
        .select("*")
        .eq("id", payment_id)
        .eq("tenant_id", tenant_id)
        .execute()
    )
    if not pay_resp.data:
        raise ValueError(f"Payment {payment_id} not found")
    payment = pay_resp.data[0]

    student_id = payment["student_id"]
    payment_amount = Decimal(str(payment["amount"]))

    # 2. Get existing allocations for this payment
    existing_resp = (
        supabase.table("payment_allocations")
        .select("amount")
        .eq("payment_id", payment_id)
        .execute()
    )
    already_allocated = sum(Decimal(str(a["amount"])) for a in existing_resp.data)
    remaining = payment_amount - already_allocated

    if remaining <= 0:
        return {
            "allocated": float(already_allocated),
            "advance": 0,
            "allocations": [],
        }

    # 3. Get unpaid fee assignments for this student (oldest month first)
    fees_resp = (
        supabase.table("fee_assignments")
        .select("*")
        .eq("student_id", student_id)
        .eq("tenant_id", tenant_id)
        .eq("is_deleted", False)
        .order("month")
        .execute()
    )

    new_allocations = []
    for fee in fees_resp.data:
        if remaining <= 0:
            break

        fee_id = fee["id"]
        fee_amount = Decimal(str(fee["amount"]))

        # Check how much is already allocated against this fee
        fee_alloc_resp = (
            supabase.table("payment_allocations")
            .select("amount")
            .eq("fee_assignment_id", fee_id)
            .execute()
        )
        fee_paid = sum(Decimal(str(a["amount"])) for a in fee_alloc_resp.data)
        fee_due = fee_amount - fee_paid

        if fee_due <= 0:
            continue

        # Allocate the lesser of remaining payment and fee due
        alloc_amount = min(remaining, fee_due)

        alloc_resp = (
            supabase.table("payment_allocations")
            .insert({
                "payment_id": payment_id,
                "fee_assignment_id": fee_id,
                "amount": float(alloc_amount),
                "tenant_id": tenant_id,
            })
            .execute()
        )
        if alloc_resp.data:
            new_allocations.append(alloc_resp.data[0])

        remaining -= alloc_amount

    total_allocated = payment_amount - remaining
    advance = float(remaining) if remaining > 0 else 0

    return {
        "allocated": float(total_allocated),
        "advance": advance,
        "allocations": new_allocations,
    }
