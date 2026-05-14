-- ============================================================
-- 06_widen_medsec_cases_policies.sql — Week 3-2 step 0
-- ============================================================
-- 為什麼有這支：
--
-- 既有 medsec_cases_read / medsec_cases_write 是 V3.3 之前
-- 多 owner 設計時的限縮版：secretary 只能看 / 寫 current_owner_id /
-- post_bid_secretary_id / bidding_owner_id = auth.uid() 的 case。
--
-- 撞牆點：
--   1. medteam-app 業務新提交的 pending case，三個 owner 欄位都 NULL，
--      → secretary 完全看不到 → secretary.html「我的案件」打不開
--   2. 認領動作要 UPDATE 把 current_owner_id 設成自己，但這條 UPDATE
--      的 WITH CHECK 要求 current_owner_id 已經是自己 → 0 rows affected
--
-- V1 拍板（Week 3-2 §Q1/§Q2）：
--   - DB-level 不做分區限縮，4 業祕 + bidding_team + manager 全看全寫
--   - 分區自律放 UI 層的「我的分區 / 全部」tab
--   - 既有 3 個 owner 欄位（current_owner_id / post_bid_secretary_id /
--     bidding_owner_id）保留欄位，但不再用於 RLS gate
--   - sales_insert / sales_select 兩條 V3.3 加的不動（OR 語意自然共存）
--
-- V2 若真要分流再加 owner-based 分支回來。
--
-- 套用順序：在 V3.3 批次（01-05）全跑完之後。idempotent，可重跑。
-- ============================================================

-- ============================================================
-- Step 0. 先眼睛掃一下 — 確認 medsec_role 5 個值都在
-- ============================================================
-- 預期：'manager' / 'bidding_team' / 'purchasing' / 'accounting' / 'secretary'
-- 如果這 3 個（manager/bidding_team/secretary）有任一個拼錯，下面 IN 清單要改。
SELECT DISTINCT medsec_role
FROM public.profiles
WHERE has_medsec_access = true
ORDER BY medsec_role;

-- ============================================================
-- 1. medsec_cases_read → 放寬
-- ============================================================
-- 改動：把 secretary 加入「全看」清單；移除 owner-based 分支（V1 沒在用）。
-- 不影響：bidding_team / manager 一直就全看。
DROP POLICY IF EXISTS medsec_cases_read ON public.medsec_cases;
CREATE POLICY medsec_cases_read ON public.medsec_cases
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.has_medsec_access = true
        AND p.medsec_role IN ('manager', 'bidding_team', 'secretary')
    )
  );

COMMENT ON POLICY medsec_cases_read ON public.medsec_cases IS
  'Week 3-2 §Q1 放寬：manager / bidding_team / secretary 三角色全看。'
  '分區限縮交給 UI 層 tab，不在 DB 卡。V1 信任 4 業祕團隊。';

-- ============================================================
-- 2. medsec_cases_write → 放寬
-- ============================================================
-- 改動：secretary 加入「全寫」清單；bidding_team 補上去（既有 write 沒給）。
-- USING + WITH CHECK 一致放寬（FOR ALL 涵蓋 INSERT / UPDATE / DELETE）。
--
-- 注意：sales_insert (V3.3) 仍然存在 — 業務從 medteam-app 提案件走那條，
-- 不需要 medsec_role 也能 INSERT（只要 has_medteam_access + source='medteam-app'）。
-- 兩條 INSERT policy 是 OR 語意，sales 路徑不受影響。
DROP POLICY IF EXISTS medsec_cases_write ON public.medsec_cases;
CREATE POLICY medsec_cases_write ON public.medsec_cases
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.has_medsec_access = true
        AND p.medsec_role IN ('manager', 'bidding_team', 'secretary')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.has_medsec_access = true
        AND p.medsec_role IN ('manager', 'bidding_team', 'secretary')
    )
  );

COMMENT ON POLICY medsec_cases_write ON public.medsec_cases IS
  'Week 3-2 §Q2 放寬：manager / bidding_team / secretary 三角色全寫。'
  '認領 UPDATE 才過得了。owner 欄位保留但不再 gate RLS。V1 信任團隊。';

-- ============================================================
-- 驗證
-- ============================================================

-- (A) 看 medsec_cases 應該有 4 條 policy（read / write / sales_insert / sales_select）
SELECT policyname, cmd, permissive
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'medsec_cases'
ORDER BY policyname;

-- (B) 看新 USING 條件（人工讀 IN 清單對不對）
SELECT polname, pg_get_expr(polqual, polrelid) AS using_clause
FROM pg_policy
WHERE polrelid = 'public.medsec_cases'::regclass
  AND polname IN ('medsec_cases_read', 'medsec_cases_write')
ORDER BY polname;

-- (C) 用業祕帳號實測（Lynn 要切換到 secretary session 跑）：
--   set role authenticated;
--   set request.jwt.claim.sub = '<某業祕的 profiles.id>';
--
--   -- 應該回多筆（pending case 看得到）
--   SELECT id, case_no, status, hospital_id, current_owner_id
--   FROM public.medsec_cases
--   WHERE status = 'pending'
--   LIMIT 10;
--
--   -- 應該回 1 row affected（current_owner_id 從 NULL 改成業祕自己）
--   UPDATE public.medsec_cases
--   SET status = 'claimed',
--       current_owner_id = auth.uid(),
--       current_owner_role = 'secretary'
--   WHERE id = '<某個 pending case id>'
--     AND status = 'pending';
--
--   reset role;
