"""
Notification models — per-tenant message templates and the outbound message log.

A notification starts in 'queued'; a worker pulls pending rows and advances the
status through a finite-state machine enforced by a DB trigger (illegal
transitions raise → mapped to 409). The recipient is polymorphic
(student/guardian/employee/user/external); recipient_id is intentionally not a
foreign key, while recipient_user_id is used when the recipient is a platform user.
"""
from typing import Optional, Literal
from pydantic import BaseModel, Field


NotificationChannel = Literal["sms", "email", "push", "whatsapp", "in_app"]
RecipientType = Literal["student", "guardian", "employee", "user", "external"]
NotificationStatus = Literal[
    "queued", "sending", "sent", "delivered", "failed", "bounced", "opened", "cancelled",
]


# ─── Templates ───────────────────────────────────────────────────────────────

class NotificationTemplateCreate(BaseModel):
    template_key: str                          # e.g. "fee_reminder", "receipt_issued"
    channel: NotificationChannel
    body_template: str                         # supports {{merge_vars}}
    subject_template: Optional[str] = None     # email/push only
    locale: str = "en"                         # 'en', 'bn', 'ar', …
    is_active: bool = True
    description: Optional[str] = None


class NotificationTemplateUpdate(BaseModel):
    body_template: Optional[str] = None
    subject_template: Optional[str] = None
    locale: Optional[str] = None
    is_active: Optional[bool] = None
    description: Optional[str] = None


class NotificationTemplateResponse(BaseModel):
    id: int
    tenant_id: str
    template_key: str
    channel: str
    subject_template: Optional[str] = None
    body_template: str
    locale: str
    is_active: bool
    description: Optional[str] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
    created_by_id: Optional[str] = None


# ─── Notifications ───────────────────────────────────────────────────────────

class NotificationCreate(BaseModel):
    channel: NotificationChannel
    recipient_type: RecipientType
    recipient_address: str                     # phone / email / push token
    body: str
    subject: Optional[str] = None
    template_key: Optional[str] = None
    template_id: Optional[int] = None
    payload: Optional[dict] = None             # merge vars (stored as JSONB)
    recipient_id: Optional[int] = None         # student/employee id; NULL for 'external'
    recipient_user_id: Optional[str] = None    # UUID, when recipient_type='user'
    recipient_name: Optional[str] = None
    scheduled_for: Optional[str] = None        # delayed send; NULL = ASAP
    related_payment_id: Optional[int] = None
    related_fee_id: Optional[int] = None
    related_payslip_id: Optional[int] = None
    related_exam_id: Optional[int] = None


class NotificationStatusUpdate(BaseModel):
    """Used by the delivery worker to advance a notification's lifecycle."""
    status: NotificationStatus
    provider: Optional[str] = None
    provider_message_id: Optional[str] = None
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    next_retry_at: Optional[str] = None
    retry_count: Optional[int] = Field(default=None, ge=0)


class NotificationResponse(BaseModel):
    id: int
    tenant_id: str
    channel: str
    template_key: Optional[str] = None
    template_id: Optional[int] = None
    recipient_type: str
    recipient_id: Optional[int] = None
    recipient_user_id: Optional[str] = None
    recipient_address: str
    recipient_name: Optional[str] = None
    subject: Optional[str] = None
    body: str
    payload: Optional[dict] = None
    status: str
    provider: Optional[str] = None
    provider_message_id: Optional[str] = None
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    scheduled_for: Optional[str] = None
    sent_at: Optional[str] = None
    delivered_at: Optional[str] = None
    opened_at: Optional[str] = None
    retry_count: Optional[int] = 0
    max_retries: Optional[int] = 3
    next_retry_at: Optional[str] = None
    related_payment_id: Optional[int] = None
    related_fee_id: Optional[int] = None
    related_payslip_id: Optional[int] = None
    related_exam_id: Optional[int] = None
    created_at: Optional[str] = None
    created_by_id: Optional[str] = None
