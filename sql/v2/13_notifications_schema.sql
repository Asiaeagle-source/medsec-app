-- ============================================================
-- 13_notifications_schema.sql — Sprint 2.5 第一批
-- ============================================================
-- 通知收件匣。送 Andrew Email(Resend)/ in-app badge 用。
-- 寫入由 edge function send-notification(service role)做;
-- 前端只「讀自己的」+ 標記已讀。idempotent。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_notifications (
  id                bigserial PRIMARY KEY,
  recipient_id      uuid REFERENCES public.profiles(id),
  notification_type text,             -- quote_pending_andrew / quote_approved_for_secretary / quote_submitted_for_lynn / andrew_wants_call
  reference_table   text,             -- 'medsec_quotes'
  reference_id      uuid,
  title             text,
  body              text,
  action_url        text,
  channel           text[],           -- ['email','in_app','line']
  sent_at           timestamptz,
  read_at           timestamptz,
  acted_at          timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notif_recipient
  ON public.medsec_notifications(recipient_id, read_at);

ALTER TABLE public.medsec_notifications ENABLE ROW LEVEL SECURITY;

-- 各人只看 / 更新自己 recipient 的
DROP POLICY IF EXISTS notif_own_read ON public.medsec_notifications;
CREATE POLICY notif_own_read ON public.medsec_notifications
  FOR SELECT TO authenticated
  USING (recipient_id = auth.uid());

DROP POLICY IF EXISTS notif_own_update ON public.medsec_notifications;
CREATE POLICY notif_own_update ON public.medsec_notifications
  FOR UPDATE TO authenticated
  USING (recipient_id = auth.uid())
  WITH CHECK (recipient_id = auth.uid());

-- INSERT 走 edge function service-role,不開前端 INSERT policy。

COMMENT ON TABLE public.medsec_notifications IS
  'Sprint2.5 通知收件匣。INSERT 只走 edge send-notification(service role)。';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT policyname, cmd FROM pg_policies
-- WHERE tablename='medsec_notifications' ORDER BY policyname;
--   -- notif_own_read(SELECT) + notif_own_update(UPDATE)
