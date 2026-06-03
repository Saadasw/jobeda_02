"""
Notification routes — message templates and the outbound notifications log.

Templates are per-tenant and unique on (template_key, channel, locale).
Notifications are queued here and later advanced by a delivery worker; the
status transitions are validated by a DB trigger (illegal moves → 409). The
/notifications/pending feed mirrors the notifications_pending view the worker
polls. recipient_id is validated for student/employee types for tenant safety.
"""
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from database import supabase
from dependencies import get_tenant_id, get_current_user_optional
from models.notification import (
    NotificationTemplateCreate, NotificationTemplateUpdate, NotificationTemplateResponse,
    NotificationCreate, NotificationStatusUpdate, NotificationResponse,
)

router = APIRouter(tags=["Notifications"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat()


def _uid(user: Optional[dict]) -> Optional[str]:
    return user["id"] if user else None


def _validate_recipient(tenant_id: str, recipient_type: str, recipient_id: Optional[int],
                        recipient_user_id: Optional[str]) -> None:
    """Best-effort tenant isolation for known recipient types (others are free-form)."""
    if recipient_type == "student" and recipient_id is not None:
        r = (
            supabase.table("students").select("id")
            .eq("id", recipient_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not r.data:
            raise HTTPException(status_code=404, detail="Recipient student not found")
    elif recipient_type == "employee" and recipient_id is not None:
        r = (
            supabase.table("employees").select("id")
            .eq("id", recipient_id).eq("tenant_id", tenant_id).eq("is_deleted", False).execute()
        )
        if not r.data:
            raise HTTPException(status_code=404, detail="Recipient employee not found")
    elif recipient_type == "user" and recipient_user_id is not None:
        r = (
            supabase.table("users").select("id")
            .eq("id", recipient_user_id).eq("tenant_id", tenant_id).execute()
        )
        if not r.data:
            raise HTTPException(status_code=404, detail="Recipient user not found")


# ════════════════════════════════════════════════════════════════════════════
#  NOTIFICATION TEMPLATES
# ════════════════════════════════════════════════════════════════════════════

@router.get("/notification-templates", response_model=List[NotificationTemplateResponse])
def list_templates(
    template_key: Optional[str] = Query(default=None),
    channel: Optional[str] = Query(default=None),
    locale: Optional[str] = Query(default=None),
    is_active: Optional[bool] = Query(default=None),
    tenant_id: str = Depends(get_tenant_id),
):
    """List the tenant's message templates, optionally filtered."""
    try:
        query = supabase.table("notification_templates").select("*").eq("tenant_id", tenant_id)
        if template_key is not None:
            query = query.eq("template_key", template_key)
        if channel is not None:
            query = query.eq("channel", channel)
        if locale is not None:
            query = query.eq("locale", locale)
        if is_active is not None:
            query = query.eq("is_active", is_active)
        resp = query.order("template_key").order("channel").execute()
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/notification-templates", response_model=NotificationTemplateResponse, status_code=201)
def create_template(
    payload: NotificationTemplateCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Create a message template. UNIQUE(template_key, channel, locale)."""
    try:
        data = {
            "tenant_id": tenant_id,
            "template_key": payload.template_key,
            "channel": payload.channel,
            "body_template": payload.body_template,
            "locale": payload.locale,
            "is_active": payload.is_active,
        }
        if payload.subject_template is not None:
            data["subject_template"] = payload.subject_template
        if payload.description is not None:
            data["description"] = payload.description
        uid = _uid(user)
        if uid:
            data["created_by_id"] = uid

        resp = supabase.table("notification_templates").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to create template")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        low = detail.lower()
        if any(k in low for k in ("duplicate", "unique", "uq_notif_template", "already exists")):
            raise HTTPException(status_code=409, detail="A template with this key/channel/locale already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.get("/notification-templates/{template_id}", response_model=NotificationTemplateResponse)
def get_template(template_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single template."""
    try:
        resp = (
            supabase.table("notification_templates").select("*")
            .eq("id", template_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Template not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/notification-templates/{template_id}", response_model=NotificationTemplateResponse)
def update_template(
    template_id: int,
    payload: NotificationTemplateUpdate,
    tenant_id: str = Depends(get_tenant_id),
):
    """Update a template's body/subject/locale/active/description."""
    try:
        data = {}
        for field in ("body_template", "subject_template", "locale", "is_active", "description"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        if not data:
            raise HTTPException(status_code=400, detail="No data provided")
        data["updated_at"] = _now_iso()

        resp = (
            supabase.table("notification_templates").update(data)
            .eq("id", template_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Template not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        low = detail.lower()
        if any(k in low for k in ("duplicate", "unique", "uq_notif_template", "already exists")):
            raise HTTPException(status_code=409, detail="A template with this key/channel/locale already exists")
        raise HTTPException(status_code=500, detail=detail)


@router.delete("/notification-templates/{template_id}")
def delete_template(template_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Delete a template (hard delete — use is_active=false to merely disable)."""
    try:
        resp = (
            supabase.table("notification_templates").delete()
            .eq("id", template_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Template not found")
        return {"message": "Template removed", "template_id": template_id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ════════════════════════════════════════════════════════════════════════════
#  NOTIFICATIONS LOG
# ════════════════════════════════════════════════════════════════════════════

@router.post("/notifications", response_model=NotificationResponse, status_code=201)
def queue_notification(
    payload: NotificationCreate,
    tenant_id: str = Depends(get_tenant_id),
    user: Optional[dict] = Depends(get_current_user_optional),
):
    """Queue an outbound message (status starts at 'queued')."""
    try:
        _validate_recipient(tenant_id, payload.recipient_type, payload.recipient_id,
                            payload.recipient_user_id)
        data = {
            "tenant_id": tenant_id,
            "channel": payload.channel,
            "recipient_type": payload.recipient_type,
            "recipient_address": payload.recipient_address,
            "body": payload.body,
        }
        optional_fields = (
            "subject", "template_key", "template_id", "payload", "recipient_id",
            "recipient_user_id", "recipient_name", "scheduled_for",
            "related_payment_id", "related_fee_id", "related_payslip_id", "related_exam_id",
        )
        for field in optional_fields:
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        uid = _uid(user)
        if uid:
            data["created_by_id"] = uid

        resp = supabase.table("notifications").insert(data).execute()
        if not resp.data:
            raise HTTPException(status_code=400, detail="Failed to queue notification")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/notifications/pending", response_model=List[NotificationResponse])
def pending_notifications(
    limit: int = Query(default=100, ge=1, le=500),
    tenant_id: str = Depends(get_tenant_id),
):
    """Worker feed: queued + failed-but-retryable messages whose time has arrived."""
    try:
        resp = (
            supabase.table("notifications_pending").select("*")
            .eq("tenant_id", tenant_id)
            .order("scheduled_for", desc=False).order("created_at", desc=False)
            .limit(limit).execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/notifications", response_model=List[NotificationResponse])
def list_notifications(
    status: Optional[str] = Query(default=None),
    channel: Optional[str] = Query(default=None),
    recipient_type: Optional[str] = Query(default=None),
    recipient_id: Optional[int] = Query(default=None),
    template_key: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    tenant_id: str = Depends(get_tenant_id),
):
    """List notifications with optional filters and pagination."""
    try:
        offset = (page - 1) * limit
        query = supabase.table("notifications").select("*").eq("tenant_id", tenant_id)
        if status is not None:
            query = query.eq("status", status)
        if channel is not None:
            query = query.eq("channel", channel)
        if recipient_type is not None:
            query = query.eq("recipient_type", recipient_type)
        if recipient_id is not None:
            query = query.eq("recipient_id", recipient_id)
        if template_key is not None:
            query = query.eq("template_key", template_key)
        resp = (
            query.order("created_at", desc=True)
            .range(offset, offset + limit - 1).execute()
        )
        return resp.data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/notifications/{notification_id}", response_model=NotificationResponse)
def get_notification(notification_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Get a single notification."""
    try:
        resp = (
            supabase.table("notifications").select("*")
            .eq("id", notification_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Notification not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.patch("/notifications/{notification_id}/status", response_model=NotificationResponse)
def update_notification_status(
    notification_id: int,
    payload: NotificationStatusUpdate,
    tenant_id: str = Depends(get_tenant_id),
):
    """
    Advance a notification's lifecycle (worker/provider callback). The DB FSM
    trigger rejects illegal transitions → 409. sent/delivered/opened timestamps
    are auto-filled by the trigger.
    """
    try:
        existing = (
            supabase.table("notifications").select("id")
            .eq("id", notification_id).eq("tenant_id", tenant_id).execute()
        )
        if not existing.data:
            raise HTTPException(status_code=404, detail="Notification not found")

        data = {"status": payload.status}
        for field in ("provider", "provider_message_id", "error_code", "error_message", "next_retry_at"):
            val = getattr(payload, field)
            if val is not None:
                data[field] = val
        if payload.retry_count is not None:
            data["retry_count"] = payload.retry_count

        resp = (
            supabase.table("notifications").update(data)
            .eq("id", notification_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Notification not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "illegal status transition" in detail.lower():
            raise HTTPException(status_code=409, detail=detail)
        raise HTTPException(status_code=500, detail=detail)


@router.post("/notifications/{notification_id}/cancel", response_model=NotificationResponse)
def cancel_notification(notification_id: int, tenant_id: str = Depends(get_tenant_id)):
    """Cancel a queued notification. Only 'queued' → 'cancelled' is allowed (FSM)."""
    try:
        existing = (
            supabase.table("notifications").select("id, status")
            .eq("id", notification_id).eq("tenant_id", tenant_id).execute()
        )
        if not existing.data:
            raise HTTPException(status_code=404, detail="Notification not found")

        resp = (
            supabase.table("notifications").update({"status": "cancelled"})
            .eq("id", notification_id).eq("tenant_id", tenant_id).execute()
        )
        if not resp.data:
            raise HTTPException(status_code=404, detail="Notification not found")
        return resp.data[0]
    except HTTPException:
        raise
    except Exception as e:
        detail = str(e)
        if "illegal status transition" in detail.lower():
            raise HTTPException(
                status_code=409,
                detail="Only queued notifications can be cancelled",
            )
        raise HTTPException(status_code=500, detail=detail)
