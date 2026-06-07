"""
Payment allocation service.

Auto-allocates a payment against the student's oldest unpaid fees (FIFO).
Uses the fee_detail_summary view so the remaining due is NET of discounts
(and prior allocations) — matching the allocation guard, which caps allocations
at the net fee amount. Allocating against gross amounts would be rejected by
that guard for any discounted fee. All rows are tenant-scoped.
"""
from decimal import Decimal
from database import supabase


def auto_allocate(payment_id: int, tenant_id: str) -> dict:
    """
    Auto-allocate a payment against unpaid fees (oldest month first).

    Returns:
      - allocated:   total amount applied to dues
      - advance:     unallocated remainder (held as an advance)
      - allocations: the allocation rows created
    """
    # 1. Payment (tenant-scoped)
    pay_resp = (
        supabase.table("payments")
        .select("id, student_id, amount")
        .eq("id", payment_id)
        .eq("tenant_id", tenant_id)
        .execute()
    )
    if not pay_resp.data:
        raise ValueError(f"Payment {payment_id} not found")
    payment = pay_resp.data[0]
    student_id = payment["student_id"]
    payment_amount = Decimal(str(payment["amount"]))

    # 2. Amount already allocated on this payment
    existing_resp = (
        supabase.table("payment_allocations")
        .select("amount")
        .eq("payment_id", payment_id)
        .eq("tenant_id", tenant_id)
        .execute()
    )
    already_allocated = sum(Decimal(str(a["amount"])) for a in existing_resp.data)
    remaining = payment_amount - already_allocated

    if remaining <= 0:
        return {"allocated": float(already_allocated), "advance": 0.0, "allocations": []}

    # 3. Unpaid fees with NET due (oldest first). The view's `due` already nets
    #    out discounts and prior allocations.
    fees_resp = (
        supabase.table("fee_detail_summary")
        .select("fee_id, due, month")
        .eq("student_id", student_id)
        .eq("tenant_id", tenant_id)
        .gt("due", 0)
        .order("month")
        .execute()
    )

    new_allocations = []
    for fee in fees_resp.data:
        if remaining <= 0:
            break
        fee_due = Decimal(str(fee["due"]))
        if fee_due <= 0:
            continue

        alloc_amount = min(remaining, fee_due)
        alloc_resp = (
            supabase.table("payment_allocations")
            .insert({
                "payment_id": payment_id,
                "fee_assignment_id": fee["fee_id"],
                "amount": float(alloc_amount),
                "tenant_id": tenant_id,
            })
            .execute()
        )
        if alloc_resp.data:
            new_allocations.append(alloc_resp.data[0])
        remaining -= alloc_amount

    total_allocated = payment_amount - remaining
    advance = float(remaining) if remaining > 0 else 0.0

    return {
        "allocated": float(total_allocated),
        "advance": advance,
        "allocations": new_allocations,
    }
