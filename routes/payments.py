"""
Payments routes — create, list, allocate, finalize.
"""
import math
from decimal import Decimal
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id
from models.payment import (
    PaymentCreate, PaymentResponse,
    PaymentAllocationCreate, PaymentAllocationResponse,
    AllocationResult,
)
from services.receipt import generate_receipt_no
from services.allocation import auto_allocate
from services.finalization import finalize_payment

router = APIRouter(prefix="/payments", tags=["Payments"])


@router.post("", response_model=PaymentResponse, status_code=201)
def create_payment(payload: PaymentCreate, tenant_id: str = Depends(get_tenant_id)):
    """
    Record a student payment with auto-generated receipt number.
    """
    try:
        receipt_no = generate_receipt_no(tenant_id)
        data = {
            "student_id": payload.student_id,
            "amount": float(payload.amount),
            "date": payload.date,
            "method": payload.method,
            "status": "completed",
            "receipt_no": receipt_no,
            "tenant_id": tenant_id,
        }
        if payload.cash_account_id is not None:
            data["cash_account_id"] = payload.cash_account_id

        resp = supabase.table("payments").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create payment")
        return resp.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("")
def list_payments(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    student_id: Optional[int] = Query(default=None),
    status: Optional[str] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List all payments with pagination and filters."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("payments").select("*").eq("tenant_id", tenant_id).eq("is_deleted", False)
        if student_id:
            query = query.eq("student_id", student_id)
        if status:
            query = query.eq("status", status)
        resp = query.order("date", desc=True).range(offset, offset + limit - 1).execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{payment_id}", response_model=PaymentResponse)
def get_payment(payment_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get payment details."""
    try:
        resp = supabase.table("payments").select("*").eq("id", payment_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        if not resp.data:
            raise HTTPException(status_code=404, detail="Payment not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{payment_id}/allocate")
def allocate_payment(payment_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Auto-allocate a payment against the student's oldest unpaid fees.
    Triggers journal entries via payment_allocations insert trigger.
    """
    try:
        result = auto_allocate(payment_id, tenant_id)
        return {
            "message": "Payment allocated",
            "payment_id": payment_id,
            **result,
        }
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{payment_id}/finalize")
def finalize_payment_endpoint(payment_id: int, tenant_id: str = Depends(get_tenant_id)):
    """
    Finalize a payment: unallocated remainder becomes Unearned Revenue.
    The DB function derives the tenant from the payment row itself.
    """
    try:
        result = finalize_payment(payment_id)
        return result
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─── MANUAL ALLOCATION ──────────────────────────────────────────────────────

@router.post("/payment-allocations", response_model=PaymentAllocationResponse, status_code=201,
             tags=["Payment Allocations"])
def create_manual_allocation(
    payload: PaymentAllocationCreate,
    tenant_id: str = Depends(get_tenant_id),
):
    """
    Manually allocate a payment amount to a specific fee assignment.
    Validates:
      - Payment exists and is completed
      - Fee assignment exists and is not deleted
      - Allocation does not exceed the fee's remaining due
      - Allocation does not exceed the payment's unallocated balance
    """
    try:
        alloc_amount = Decimal(str(payload.amount))

        # 1. Validate payment exists and is completed
        pay_resp = (
            supabase.table("payments")
            .select("id, amount, status")
            .eq("id", payload.payment_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not pay_resp.data:
            raise HTTPException(status_code=404, detail="Payment not found")
        payment = pay_resp.data[0]
        if payment["status"] != "completed":
            raise HTTPException(status_code=400, detail=f"Payment is '{payment['status']}', not completed")

        # 2. Validate fee assignment exists and is active
        fee_resp = (
            supabase.table("fee_assignments")
            .select("id, amount")
            .eq("id", payload.fee_assignment_id)
            .eq("tenant_id", tenant_id)
            .eq("is_deleted", False)
            .execute()
        )
        if not fee_resp.data:
            raise HTTPException(status_code=404, detail="Fee assignment not found")
        fee = fee_resp.data[0]

        # 3. Check: allocation won't exceed fee's remaining due
        fee_alloc_resp = (
            supabase.table("payment_allocations")
            .select("amount")
            .eq("fee_assignment_id", payload.fee_assignment_id)
            .execute()
        )
        already_paid = sum(Decimal(str(a["amount"])) for a in fee_alloc_resp.data)
        fee_remaining = Decimal(str(fee["amount"])) - already_paid

        if alloc_amount > fee_remaining:
            raise HTTPException(
                status_code=400,
                detail=f"Allocation ({alloc_amount}) exceeds fee remaining due ({fee_remaining}). "
                       f"Excess should go through finalize_payment() as advance."
            )

        # 4. Check: allocation won't exceed payment's unallocated balance
        pay_alloc_resp = (
            supabase.table("payment_allocations")
            .select("amount")
            .eq("payment_id", payload.payment_id)
            .execute()
        )
        already_allocated = sum(Decimal(str(a["amount"])) for a in pay_alloc_resp.data)
        pay_remaining = Decimal(str(payment["amount"])) - already_allocated

        if alloc_amount > pay_remaining:
            raise HTTPException(
                status_code=400,
                detail=f"Allocation ({alloc_amount}) exceeds payment's unallocated balance ({pay_remaining})"
            )

        # 5. All checks passed — insert
        data = {
            "payment_id": payload.payment_id,
            "fee_assignment_id": payload.fee_assignment_id,
            "amount": float(alloc_amount),
            "tenant_id": tenant_id,
        }
        resp = supabase.table("payment_allocations").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create allocation")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
