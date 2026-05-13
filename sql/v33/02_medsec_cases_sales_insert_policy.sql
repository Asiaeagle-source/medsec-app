-- ============================================================
-- 02_medsec_cases_sales_insert_policy.sql — Lynn V3.3
-- ============================================================
-- 新增 sales INSERT policy 配合 medteam-app 串接：
-- 業務在 medteam-app 提案件 → 直接 INSERT 一筆到 medsec_cases
-- （source='medteam-app'、requested_by_user_id=自己）
--
-- Lynn 拍板：不破壞既有 2 個 policy；新增 policy 是「補強」不是「覆寫」。
-- 套用順序：在 01_alter_medsec_cases.sql 之後（不依賴新欄位，但跟它同批）
-- ============================================================

-- ============================================================
-- 1. auth_medteam_role() helper（鏡像既有 auth_medsec_role()）
-- ============================================================
-- 如果 medteam-app 已建這個 function，CREATE OR REPLACE 是 idempotent；
-- 沒建就建。security definer 避開 profiles 表本身 RLS 遞迴。
CREATE OR REPLACE FUNCTION public.auth_medteam_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT medteam_role FROM public.profiles WHERE id = auth.uid()
$$;

COMMENT ON FUNCTION public.auth_medteam_role()
  IS 'V3.3 鏡像 auth_medsec_role()。給 medsec_cases sales INSERT policy 用，避開 profiles RLS 遞迴。';

GRANT EXECUTE ON FUNCTION public.auth_medteam_role() TO authenticated;

-- ============================================================
-- 2. medsec_cases · 新增 sales INSERT policy
-- ============================================================
-- 邏輯：medteam_role='sales' 且 requested_by_user_id = auth.uid()
-- （不能代別人提；不能假冒非業務角色）
--
-- 不 DROP / 不 ALTER 既有 2 個 policy。
DROP POLICY IF EXISTS medsec_cases_sales_insert ON public.medsec_cases;
CREATE POLICY medsec_cases_sales_insert ON public.medsec_cases
  FOR INSERT TO authenticated
  WITH CHECK (
    requested_by_user_id = auth.uid()
    AND public.auth_medteam_role() = 'sales'
    AND source = 'medteam-app'                              -- 強制標記來源
  );

COMMENT ON POLICY medsec_cases_sales_insert ON public.medsec_cases
  IS 'V3.3 medteam-app 業務直接 INSERT 案件。requested_by_user_id 必須=自己、medteam_role=sales、source=medteam-app。';

-- ============================================================
-- 3. medsec_cases · 新增 sales SELECT policy（業務只看自己提交的）
-- ============================================================
-- Lynn V3.3 Q1 RLS 規則：
--   業務（medteam_role='sales'）：只能 SELECT requested_by_user_id = auth.uid() 的
--
-- 既有 SELECT policy 應該已涵蓋 manager/secretary/bidding_team 等。
-- 新增這個 policy 給業務一個專屬 SELECT 路徑（PostgreSQL RLS 多 policy 是 OR，所以新增不會收緊）。
DROP POLICY IF EXISTS medsec_cases_sales_select ON public.medsec_cases;
CREATE POLICY medsec_cases_sales_select ON public.medsec_cases
  FOR SELECT TO authenticated
  USING (
    requested_by_user_id = auth.uid()
    AND public.auth_medteam_role() = 'sales'
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
-- select public.auth_medteam_role();    -- 回你自己的 medteam_role

-- (3) 業務 INSERT 試跑（用業務帳號登入）
-- insert into public.medsec_cases
--   (case_type, title, status, company, action_type, hospital_id,
--    source, requested_by_user_id)
-- values ('inquiry','測試詢價','pending','AE','coding','TNH',
--         'medteam-app', auth.uid())
-- returning case_no;
-- → 應該成功；source 改 'manual' 或 requested_by_user_id 改別人 uuid 會被 RLS 擋
