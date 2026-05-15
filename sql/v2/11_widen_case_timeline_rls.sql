-- ============================================================
-- 11_widen_case_timeline_rls.sql — 修「報價儲存失敗」
-- ============================================================
-- 症狀 (2026-05-15 伶華 0020 實測):
--   secretary 在 secretary.html 報價優化 → 儲存草稿
--   → alert「建 case 失敗:new row violates row-level security
--     policy for table "medsec_case_timeline"」
--
-- 原因:
--   saveQuote() INSERT medsec_cases (這步 RLS 已被 sql/v33/06 放寬,過得了)
--   → medsec_cases 上有一支「寫初始事件流」的 trigger (V1/V3 早期 handover
--     建的,不在本 repo sql/ 內),AFTER INSERT 會 INSERT 一列進
--     medsec_case_timeline。
--   → 該 trigger 以呼叫者 (secretary) 身分執行,medsec_case_timeline 有
--     RLS 但沒有放行 secretary 的 INSERT policy → 整個交易 rollback,
--     case + quote 都建不起來。
--
-- 修法:
--   比照 sql/v33/06 (medsec_cases 放寬) + sql/v2/08 (分區放寬) 的作法,
--   只「新增」一條 policy,不動既有 policy (PostgreSQL 多 policy 是 OR
--   語意)。放行跟 medsec_cases / medsec_quotes 一致的三角色:
--   manager / secretary / bidding_team。idempotent,可重跑。
--
-- ⚠️ 純新增檔,沒改任何已 merged 的 sql。Lynn 在 Supabase 跑這一支即可。
-- ============================================================

ALTER TABLE public.medsec_case_timeline ENABLE ROW LEVEL SECURITY;

-- 事件流是 append-only 稽核軌:三角色可讀可寫 (跟 medsec_cases / quotes 同步)
DROP POLICY IF EXISTS case_timeline_rw ON public.medsec_case_timeline;
CREATE POLICY case_timeline_rw ON public.medsec_case_timeline
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'));

COMMENT ON POLICY case_timeline_rw ON public.medsec_case_timeline IS
  'V2 Sprint2: 放行 manager/secretary/bidding_team — 修 secretary 建 case 時'
  ' AFTER INSERT trigger 寫 medsec_case_timeline 撞 RLS 導致報價存不了。'
  ' 不破壞既有 policy (多 policy OR 語意)。';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. policy 在不在:
--    SELECT policyname, cmd FROM pg_policies
--    WHERE schemaname='public' AND tablename='medsec_case_timeline'
--    ORDER BY policyname;   -- 應看到 case_timeline_rw (cmd=ALL) + 既有 policy
--
-- 2. secretary (伶華 0020) session 實測:
--    secretary.html → 報價優化 → 新增報價 → 填醫院/品項 → 儲存草稿
--    → 不再跳「medsec_case_timeline RLS」,case + quote 建得起來。
