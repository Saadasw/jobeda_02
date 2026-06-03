-- Migration 033: Notifications Log + Templates
-- ================================================================
-- WHY:
--   For fee reminders, receipt confirmations, exam announcements,
--   absence alerts, payslip-ready alerts — the app needs to send SMS
--   / email / push / WhatsApp. Without a notifications log there is
--   no audit trail ("did we actually send the reminder?"), no retry
--   policy, and no per-student delivery history.
--
-- DESIGN:
--   * notification_templates — per-tenant message templates so owners
--     can customize wording per branch and channel.
--   * notifications — log of every message, queued or sent. A small
--     worker (cron / background job) reads pending rows and calls
--     the provider, then UPDATEs the row's status / provider_message_id.
--   * status finite-state-machine enforced by trigger.
--   * Polymorphic recipient: recipient_type + recipient_id + a
--     resolved recipient_address (phone / email).
-- ================================================================

-- ════════════════════════════════════════════════════════════════
-- 1. NOTIFICATION TEMPLATES
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS notification_templates (
    id              SERIAL PRIMARY KEY,
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    template_key    TEXT NOT NULL,                         -- 'fee_reminder', 'receipt_issued', etc.
    channel         TEXT NOT NULL CHECK (channel IN ('sms','email','push','whatsapp','in_app')),

    subject_template  TEXT,                                -- email/push only
    body_template     TEXT NOT NULL,                       -- supports {{merge_vars}}

    locale          TEXT NOT NULL DEFAULT 'en',            -- 'en','bn','ar'
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    description     TEXT,

    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP NULL,
    created_by_id   UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    CONSTRAINT uq_notif_template UNIQUE (tenant_id, template_key, channel, locale)
);

CREATE INDEX IF NOT EXISTS idx_notif_templates_tenant ON notification_templates(tenant_id);
CREATE INDEX IF NOT EXISTS idx_notif_templates_lookup
    ON notification_templates(tenant_id, template_key, channel, locale)
    WHERE is_active = TRUE;

-- ════════════════════════════════════════════════════════════════
-- 2. NOTIFICATIONS LOG
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS notifications (
    id                  BIGSERIAL PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    channel             TEXT NOT NULL CHECK (channel IN ('sms','email','push','whatsapp','in_app')),
    template_key        TEXT,                              -- nullable: ad-hoc messages allowed
    template_id         INT  NULL REFERENCES notification_templates(id) ON DELETE SET NULL,

    -- Polymorphic recipient. We don't FK the recipient_id because it
    -- can point at students / employees / users — but we do enforce
    -- the type via CHECK.
    recipient_type      TEXT NOT NULL CHECK (recipient_type IN (
                            'student','guardian','employee','user','external'
                        )),
    recipient_id        INT  NULL,                         -- NULL for 'external'
    recipient_user_id   UUID NULL REFERENCES users(id) ON DELETE SET NULL,  -- when recipient_type='user'
    recipient_address   TEXT NOT NULL,                     -- phone, email, push token, etc.
    recipient_name      TEXT,                              -- display name (snapshot)

    subject             TEXT,
    body                TEXT NOT NULL,
    payload             JSONB,                             -- merge vars used to render the body

    status              TEXT NOT NULL DEFAULT 'queued'
                          CHECK (status IN ('queued','sending','sent','delivered','failed','bounced','opened','cancelled')),
    provider            TEXT,                              -- 'twilio','ssl_wireless','sendgrid','fcm',…
    provider_message_id TEXT,
    error_code          TEXT,
    error_message       TEXT,

    scheduled_for       TIMESTAMP NULL,                    -- delayed send; NULL = ASAP
    sent_at             TIMESTAMP NULL,
    delivered_at        TIMESTAMP NULL,
    opened_at           TIMESTAMP NULL,

    retry_count         SMALLINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    max_retries         SMALLINT NOT NULL DEFAULT 3,
    next_retry_at       TIMESTAMP NULL,

    -- Optional links to business objects (for "this is the receipt
    -- for payment X" / "this is the reminder for fee Y" tracing).
    related_payment_id  INT NULL REFERENCES payments(id)         ON DELETE SET NULL,
    related_fee_id      INT NULL REFERENCES fee_assignments(id)  ON DELETE SET NULL,
    related_payslip_id  INT NULL REFERENCES payslips(id)         ON DELETE SET NULL,
    related_exam_id     INT NULL REFERENCES exams(id)            ON DELETE SET NULL,

    created_at          TIMESTAMP DEFAULT NOW(),
    created_by_id       UUID NULL REFERENCES users(id) ON DELETE SET NULL
);

-- Hot path: worker pulling pending messages
CREATE INDEX IF NOT EXISTS idx_notifications_pending
    ON notifications(tenant_id, status, scheduled_for NULLS FIRST, created_at)
    WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_notifications_retry
    ON notifications(next_retry_at)
    WHERE status = 'failed' AND retry_count < max_retries;

CREATE INDEX IF NOT EXISTS idx_notifications_tenant_created
    ON notifications(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient
    ON notifications(recipient_type, recipient_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_related_payment ON notifications(related_payment_id);
CREATE INDEX IF NOT EXISTS idx_notifications_related_fee     ON notifications(related_fee_id);
CREATE INDEX IF NOT EXISTS idx_notifications_related_payslip ON notifications(related_payslip_id);

-- ────────────────────────────────────────────────────────────────
-- 3. State-transition validation
--    queued     → sending | cancelled
--    sending    → sent | failed
--    sent       → delivered | bounced | opened
--    delivered  → opened
--    failed     → queued (manual retry) | sending (auto retry)
--    bounced / opened / cancelled → terminal
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_notifications_status_fsm()
RETURNS TRIGGER AS $$
DECLARE
    allowed BOOLEAN;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        allowed := FALSE;

        IF OLD.status = 'queued'    AND NEW.status IN ('sending','cancelled') THEN allowed := TRUE; END IF;
        IF OLD.status = 'sending'   AND NEW.status IN ('sent','failed')       THEN allowed := TRUE; END IF;
        IF OLD.status = 'sent'      AND NEW.status IN ('delivered','bounced','opened') THEN allowed := TRUE; END IF;
        IF OLD.status = 'delivered' AND NEW.status IN ('opened')              THEN allowed := TRUE; END IF;
        IF OLD.status = 'failed'    AND NEW.status IN ('queued','sending')    THEN allowed := TRUE; END IF;

        IF NOT allowed THEN
            RAISE EXCEPTION 'notifications: illegal status transition % → %', OLD.status, NEW.status;
        END IF;
    END IF;

    -- Auto-fill timestamps
    IF NEW.status = 'sent'      AND NEW.sent_at      IS NULL THEN NEW.sent_at      := NOW(); END IF;
    IF NEW.status = 'delivered' AND NEW.delivered_at IS NULL THEN NEW.delivered_at := NOW(); END IF;
    IF NEW.status = 'opened'    AND NEW.opened_at    IS NULL THEN NEW.opened_at    := NOW(); END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS notifications_status_fsm ON notifications;
CREATE TRIGGER notifications_status_fsm
BEFORE UPDATE ON notifications
FOR EACH ROW
EXECUTE FUNCTION trg_notifications_status_fsm();

-- ────────────────────────────────────────────────────────────────
-- 4. queue_notification — convenience for app code.
--    Returns the notification id.
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION queue_notification(
    p_tenant_id         UUID,
    p_channel           TEXT,
    p_recipient_type    TEXT,
    p_recipient_address TEXT,
    p_body              TEXT,
    p_subject           TEXT DEFAULT NULL,
    p_template_key      TEXT DEFAULT NULL,
    p_payload           JSONB DEFAULT NULL,
    p_recipient_id      INT DEFAULT NULL,
    p_recipient_name    TEXT DEFAULT NULL,
    p_scheduled_for     TIMESTAMP DEFAULT NULL,
    p_related_payment_id INT DEFAULT NULL,
    p_related_fee_id     INT DEFAULT NULL,
    p_related_payslip_id INT DEFAULT NULL,
    p_related_exam_id    INT DEFAULT NULL,
    p_created_by_id      UUID DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO notifications (
        tenant_id, channel, template_key,
        recipient_type, recipient_id, recipient_address, recipient_name,
        subject, body, payload, scheduled_for,
        related_payment_id, related_fee_id, related_payslip_id, related_exam_id,
        created_by_id
    ) VALUES (
        p_tenant_id, p_channel, p_template_key,
        p_recipient_type, p_recipient_id, p_recipient_address, p_recipient_name,
        p_subject, p_body, p_payload, p_scheduled_for,
        p_related_payment_id, p_related_fee_id, p_related_payslip_id, p_related_exam_id,
        p_created_by_id
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- 5. Pending-notifications view: what the worker should pull NEXT
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW notifications_pending AS
SELECT *
FROM notifications
WHERE status = 'queued'
  AND (scheduled_for IS NULL OR scheduled_for <= NOW())
UNION ALL
SELECT *
FROM notifications
WHERE status = 'failed'
  AND retry_count < max_retries
  AND (next_retry_at IS NULL OR next_retry_at <= NOW());

-- ────────────────────────────────────────────────────────────────
-- 6. Seed: a few common templates per tenant (English defaults).
--    Owners can edit / translate / disable.
-- ────────────────────────────────────────────────────────────────
INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'fee_reminder',
    'sms',
    NULL,
    'Dear {{guardian_name}}, fee of {{currency}} {{amount}} for {{student_name}} ({{month}}) is due. Please pay by {{due_date}}. - {{school_name}}',
    'en',
    'Sent before due date'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'receipt_issued',
    'sms',
    NULL,
    'Payment received: {{currency}} {{amount}} for {{student_name}}. Receipt {{receipt_no}}. Thank you. - {{school_name}}',
    'en',
    'Sent after successful payment'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'overdue_alert',
    'sms',
    NULL,
    'Dear {{guardian_name}}, fee of {{currency}} {{amount}} for {{student_name}} is now {{days_overdue}} days overdue. Late fee may apply. - {{school_name}}',
    'en',
    'Sent X days after due date if unpaid'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'absence_alert',
    'sms',
    NULL,
    'Dear {{guardian_name}}, {{student_name}} was absent today ({{date}}). Please contact the {{school_name}} office. - {{school_name}}',
    'en',
    'Sent on the day a student is absent'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'exam_announcement',
    'sms',
    NULL,
    'Exam schedule: {{exam_name}} starts {{start_date}}. Please ensure {{student_name}} attends. - {{school_name}}',
    'en',
    'Sent when an exam is published'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

INSERT INTO notification_templates (tenant_id, template_key, channel, subject_template, body_template, locale, description)
SELECT
    t.id,
    'payslip_ready',
    'sms',
    NULL,
    'Dear {{employee_name}}, your payslip for {{month}} {{year}} is ready. Net payable: {{currency}} {{net_payable}}. - {{school_name}}',
    'en',
    'Sent when a payslip is finalized'
FROM tenants t
ON CONFLICT (tenant_id, template_key, channel, locale) DO NOTHING;

COMMENT ON TABLE notifications IS
'Append-friendly log of all outbound messages. Worker pulls from notifications_pending view and updates status.';
COMMENT ON TABLE notification_templates IS
'Per-tenant message templates. The app renders {{merge_vars}} before queueing into notifications.';
COMMENT ON VIEW  notifications_pending IS
'Queued + failed-but-retryable messages whose scheduled time has arrived.';
