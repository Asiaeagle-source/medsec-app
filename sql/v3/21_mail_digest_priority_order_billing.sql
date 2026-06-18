-- ============================================================
-- 21_mail_digest_priority_order_billing.sql
-- 配合 mail-triage rules v3:priority 新增 'order'(訂單區) 與
-- 'billing'(帳務區)。放寬 mail_digest_priority_check 允許這兩值。
-- idempotent,可重跑。
-- ============================================================

alter table public.mail_digest
  drop constraint if exists mail_digest_priority_check;

alter table public.mail_digest
  add constraint mail_digest_priority_check
  check (priority in ('red','amber','order','billing','gray'));

comment on constraint mail_digest_priority_check on public.mail_digest is
  'v3:新增 order(訂單區)、billing(帳務區);原 red/amber/gray 保留。';

-- 驗證
-- INSERT INTO mail_digest (graph_message_id, received_at, priority) VALUES ('t-order',now(),'order');
-- INSERT INTO mail_digest (graph_message_id, received_at, priority) VALUES ('t-bill', now(),'billing');
-- DELETE FROM mail_digest WHERE graph_message_id IN ('t-order','t-bill');
