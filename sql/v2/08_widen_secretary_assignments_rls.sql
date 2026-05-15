-- ============================================================
-- 08_widen_secretary_assignments_rls.sql — 分區換區工具用
-- ============================================================
-- 為什麼:
--   Lynn 2026-05-15 需求 #4「分區要讓主管簡易方法換區 / 匯入或調整」。
--   manager.html 業祕分區頁要從 read-only 改 editable + CSV 匯入,
--   需要 manager 對 medsec_secretary_assignments 有 INSERT/UPDATE/DELETE 權。
--
--   既有 medsec_secretary_assignments RLS (V1 Week 1-2 建) 內容不確定,
--   本支只「新增」一條 manager 全寫 policy (PostgreSQL 多 policy OR 語意,
--   不破壞既有 SELECT policy)。idempotent,可重跑。
-- ============================================================

ALTER TABLE public.medsec_secretary_assignments ENABLE ROW LEVEL SECURITY;

-- manager 全寫 (INSERT / UPDATE / DELETE / SELECT)
DROP POLICY IF EXISTS sa_manager_write ON public.medsec_secretary_assignments;
CREATE POLICY sa_manager_write ON public.medsec_secretary_assignments
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() = 'manager')
  WITH CHECK (public.auth_medsec_role() = 'manager');

COMMENT ON POLICY sa_manager_write ON public.medsec_secretary_assignments IS
  'Week V2: manager 可改分區 (manager.html 逐家下拉 + CSV 匯入)。不破壞既有 SELECT policy。';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT policyname, cmd FROM pg_policies
-- WHERE schemaname='public' AND tablename='medsec_secretary_assignments'
-- ORDER BY policyname;
-- 應該看到 sa_manager_write (cmd=ALL) + 既有 SELECT policy
--
-- manager session 實測:
--   UPDATE medsec_secretary_assignments SET co_secretary_id = NULL
--   WHERE hospital_id = '<某醫院>';   -- 應該回 UPDATE 1
