-- ============================================================
-- sql/v3/04_hospital_systems_grant.sql — 確保 hospital_systems 可被讀
-- ============================================================
-- 症狀:admin-pricing 體系欄顯示原 code(CA/CB/CC…)而非中文。
-- 根因高機率:RLS policy 已存在 using(true),但 authenticated 對 table
-- 沒有 SELECT GRANT → PostgREST 回 403 → 前端 fetchAll 失敗 → SYSTEMS
-- map 為空 → sysLabel(code) 回退顯示原 code。
-- (在 SQL editor 是 postgres role,看不出此問題)。
--
-- 補 GRANT 即可,idempotent,可重跑。不改欄位、不刪資料、不動 policy。
-- 跑完前端硬重整,admin-pricing 右上「體系對照 N 筆」應變綠色非零。
-- ============================================================

GRANT SELECT ON public.hospital_systems TO authenticated;
GRANT SELECT ON public.hospital_systems TO anon;

-- 確保 RLS policy 已就緒(若 sql/02 還沒跑就一併補上,idempotent)
ALTER TABLE public.hospital_systems ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hosp_sys_select_pub ON public.hospital_systems;
CREATE POLICY hosp_sys_select_pub ON public.hospital_systems
  FOR SELECT TO authenticated USING (true);

-- ============================================================
-- 驗證
-- ============================================================
-- 以 supabase anon/authenticated 走 REST 應可讀到 33 筆:
--   curl -H "apikey: <anon>" -H "Authorization: Bearer <jwt>" \
--     "https://yincuegybnuzgojakkuc.supabase.co/rest/v1/hospital_systems?select=code,name"
