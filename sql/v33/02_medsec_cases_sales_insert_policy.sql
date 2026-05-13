-- ============================================================
-- 02_medsec_cases_sales_insert_policy.sql — Lynn V3.3
-- ============================================================
-- 新增 sales INSERT policy 配合 medteam-app 串接：
-- 業務在 medteam-app 提案件 → 直接 INSERT 一筆到 medsec_cases
-- （source='medteam-app'、requested_by_user_id=自己）
--
-- Lynn 拍板：不破壞既有 2 個 policy；新增 policy 是「補強」不是「覆寫」。
-- 套用順序：在 01_alter_medsec_cases.sql 之後（不依賴新欄位，但跟它同批）
--
-- 修訂史：
--   2026-05-13 v1 初版用 auth_medteam_role() 撞 profiles.medteam_role 不存在
--   2026-05-13 v2 改 auth_has_medteam_access() boolean gate（本檔）
-- ============================================================

-- ============================================================
-- 1. auth_has_medteam_access() helper
-- ============================================================
-- profiles 實際 schema：只有 has_medteam_access (bool) + medsec_role (text)
-- 沒有 medteam_role 欄。改用 boolean gate 判定「是否業務」。
-- security definer 避開 profiles RLS 遞迴。
CREATE OR REPLACE FUNCTION public.auth_has_medteam_access()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(has_medteam_access, false)
  FROM public.profiles
  WHERE id = auth.uid()
$$;

COMMENT ON FUNCTION public.auth_has_medteam_access()
  IS 'V3.3 sales gate。profiles 無 medteam_role 欄，用 has_medteam_access bool 替代。';

GRANT EXECUTE ON FUNCTION public.auth_has_medteam_access() TO authenticated;

-- 清掉 v1 失敗留下的 stub（如有）
DROP FUNCTION IF EXISTS public.auth_medteam_role();

-- ============================================================
-- 2. medsec_cases · 新增 sales INSERT policy
-- ============================================================
-- 邏輯：has_medteam_access=true 且 requested_by_user_id = auth.uid() 且 source='medteam-app'
-- （不能代別人提；不能假冒非 medteam 來源；無 medteam access 不能 INSERT）
--
-- 不 DROP / 不 ALTER 既有 2 個 policy。
DROP POLICY IF EXISTS medsec_cases_sales_insert ON public.medsec_cases;
CREATE POLICY medsec_cases_sales_insert ON public.medsec_cases
  FOR INSERT TO authenticated
  WITH CHECK (
    requested_by_user_id = auth.uid()
    AND public.auth_has_medteam_access()
    AND source = 'medteam-app'                              -- 強制標記來源
  );

COMMENT ON POLICY medsec_cases_sales_insert ON public.medsec_cases
  IS 'V3.3 medteam-app 業務直接 INSERT 案件。requested_by_user_id 必須=自己、has_medteam_access=true、source=medteam-app。';

-- ============================================================
-- 3. medsec_cases · 新增 sales SELECT policy（業務只看自己提交的）
-- ============================================================
-- Lynn V3.3 Q1 RLS 規則：
--   業務：只能 SELECT requested_by_user_id = auth.uid() 的
--
-- 既有 SELECT policy 應該已涵蓋 manager/secretary/bidding_team 等。
-- 新增這個 policy 給業務一個專屬 SELECT 路徑（PostgreSQL RLS 多 policy 是 OR，所以新增不會收緊）。
DROP POLICY IF EXISTS medsec_cases_sales_select ON public.medsec_cases;
CREATE POLICY medsec_cases_sales_select ON public.medsec_cases
  FOR SELECT TO authenticated
  USING (
    requested_by_user_id = auth.uid()
    AND public.auth_has_medteam_access()
  );

COMMENT ON POLICY medsec_cases_sales_select ON public.medsec_cases
  IS 'V3.3 medteam-app 業務 SELECT 自己提交的案件。';

-- ============================================================
-- 驗證
-- ============================================================
-- (1) policy 數從 2 → 4
-- select policyname, cmd
-- from pg_policies
-- where schemaname='public' and tablename='medsec_cases'
-- order by policyname;
-- → 應該回 4 個

-- (2) helper 可呼叫
-- select public.auth_has_medteam_access();    -- 回 true / false

-- (3) 業務 INSERT 試跑（用業務帳號登入）
-- insert into public.medsec_cases
--   (case_type, title, status, company, action_type, hospital_id,
--    source, requested_by_user_id)
-- values ('inquiry','測試詢價','pending','AE','coding','TNH',
--         'medteam-app', auth.uid())
-- returning case_no;
-- → 應該成功；source 改 'manual' 或 requested_by_user_id 改別人 uuid 會被 RLS 擋
