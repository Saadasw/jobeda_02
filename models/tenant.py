"""
Tenant + per-tenant settings Pydantic models.
"""
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field


# ─── Tenant ──────────────────────────────────────────────────────────────────
class TenantCreate(BaseModel):
    name: str
    slug: str = Field(pattern=r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", min_length=2, max_length=50)
    address: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    logo_url: Optional[str] = None


class TenantUpdate(BaseModel):
    name: Optional[str] = None
    address: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    logo_url: Optional[str] = None
    is_active: Optional[bool] = None


class TenantResponse(BaseModel):
    id: str
    name: str
    slug: str
    address: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    logo_url: Optional[str] = None
    is_active: Optional[bool] = True
    created_at: Optional[str] = None
    updated_at: Optional[str] = None


# ─── Tenant settings ─────────────────────────────────────────────────────────
class TenantSettingsUpdate(BaseModel):
    currency_code: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    currency_symbol: Optional[str] = None
    locale: Optional[str] = None
    timezone: Optional[str] = None
    date_format: Optional[str] = None
    number_format: Optional[str] = None
    fiscal_year_start_month: Optional[int] = Field(default=None, ge=1, le=12)
    academic_year_start_month: Optional[int] = Field(default=None, ge=1, le=12)
    receipt_prefix: Optional[str] = Field(default=None, pattern=r"^[A-Z0-9]{1,10}$")
    receipt_footer: Optional[str] = None
    invoice_prefix: Optional[str] = Field(default=None, pattern=r"^[A-Z0-9]{1,10}$")
    school_motto: Optional[str] = None
    late_fee_enabled: Optional[bool] = None
    late_fee_grace_days: Optional[int] = Field(default=None, ge=0)
    late_fee_type: Optional[str] = Field(default=None, pattern=r"^(flat|percent)$")
    late_fee_value: Optional[Decimal] = Field(default=None, ge=0)
    low_cash_threshold: Optional[Decimal] = Field(default=None, ge=0)
    overdue_alert_days: Optional[int] = Field(default=None, ge=0)
    display_name: Optional[str] = None
    display_address: Optional[str] = None
    display_phone: Optional[str] = None
    display_email: Optional[str] = None


class TenantSettingsResponse(BaseModel):
    tenant_id: str
    currency_code: Optional[str] = "BDT"
    currency_symbol: Optional[str] = None
    locale: Optional[str] = "en"
    timezone: Optional[str] = None
    date_format: Optional[str] = None
    number_format: Optional[str] = None
    fiscal_year_start_month: Optional[int] = 1
    academic_year_start_month: Optional[int] = 1
    receipt_prefix: Optional[str] = "PAY"
    receipt_footer: Optional[str] = None
    invoice_prefix: Optional[str] = "INV"
    school_motto: Optional[str] = None
    late_fee_enabled: Optional[bool] = False
    late_fee_grace_days: Optional[int] = 7
    late_fee_type: Optional[str] = "flat"
    late_fee_value: Optional[Decimal] = Decimal(0)
    low_cash_threshold: Optional[Decimal] = Decimal(0)
    overdue_alert_days: Optional[int] = 30
    display_name: Optional[str] = None
    display_address: Optional[str] = None
    display_phone: Optional[str] = None
    display_email: Optional[str] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
