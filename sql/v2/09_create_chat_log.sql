-- ============================================================
-- 09_create_chat_log.sql — 問問題用量 log + rate limit 基礎
-- ============================================================
-- 為什麼:
--   Lynn 2026-05-15 需求 #3 擔心「成本進去會不會被問出來 / 爆掉」。
--   API key 在服務端 (前端拿不到),真正風險是登入員工狂點刷量。
--   這張表給 edge function:
--     1. 每次 call 記一筆 (用量稽核,Lynn 可查每人花多少)
--     2. 算近 N 分鐘 call 數做 rate limit
--
--   edge function 用 service-role 寫 (繞 RLS);前端 / 一般員工不可寫,
--   只有 manager 可 SELECT 看用量。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_chat_log (
  id            bigserial PRIMARY KEY,
  user_id       uuid REFERENCES public.profiles(id),
  hospital_id   text,                     -- 該次對話 context 醫院 (可 NULL)
  prompt_chars  int,                      -- user 問題字數 (粗估成本用)
  model         text,
  ok            bool NOT NULL DEFAULT true,
  error_msg     text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_log_user_time
  ON public.medsec_chat_log(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_log_created
  ON public.medsec_chat_log(created_at DESC);

ALTER TABLE public.medsec_chat_log ENABLE ROW LEVEL SECURITY;

-- 只 manager 可 SELECT (看全公司用量 / 成本)
DROP POLICY IF EXISTS chat_log_manager_select ON public.medsec_chat_log;
CREATE POLICY chat_log_manager_select ON public.medsec_chat_log
  FOR SELECT TO authenticated
  USING (public.auth_medsec_role() = 'manager');

-- 不開任何 INSERT/UPDATE policy → 只有 service-role (edge function) 寫得進去
-- (service-role 繞 RLS,不需要 policy)

COMMENT ON TABLE public.medsec_chat_log IS
  '問問題 (claude-chat edge fn) 用量 log + rate limit 基礎。edge fn 用 service-role 寫,manager 可看。';

-- ============================================================
-- Lynn 查用量範例
-- ============================================================
-- 今天每人問幾次:
-- SELECT p.nickname, p.employee_id, count(*) AS calls,
--        sum(c.prompt_chars) AS total_chars
-- FROM medsec_chat_log c JOIN profiles p ON p.id = c.user_id
-- WHERE c.created_at >= current_date
-- GROUP BY p.nickname, p.employee_id ORDER BY calls DESC;
--
-- 近 7 天每天總量:
-- SELECT created_at::date AS d, count(*) FROM medsec_chat_log
-- WHERE created_at >= current_date - 7 GROUP BY d ORDER BY d;
