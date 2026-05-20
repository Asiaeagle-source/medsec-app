-- ============================================================
-- sql/v3/05_resync_qh_system_prefix.sql — 同步 quote_history 體系/區域
-- ============================================================
-- 症狀:admin-pricing Tab3 體系欄顯示 raw code(NT/CH/MH/CL/SC/S-…),
--   而 manager.html 醫院主檔頁顯示中文正常。
-- 根因:medsec_hospitals.system_prefix 已遷移為 BS 碼(CA/CB/CG…),
--   但 medsec_quote_history.system_prefix 是 CRM 匯入當下的快照,
--   未隨主檔遷移更新 → SYSTEMS map(hospital_systems 新 BS 碼)找不到
--   舊碼 → 前端 sysLabel fallback 顯示 raw。
-- 解:依 hospital_id JOIN medsec_hospitals,把舊的 system_prefix /
--   region_code / customer_type / parent_code 回填為主檔現值。
-- idempotent:WHERE 用 IS DISTINCT FROM 過濾,重跑只動真正不一致的列。
-- 不刪資料、不改欄位、不動 RLS、不動 hospital_systems。
-- ============================================================

UPDATE public.medsec_quote_history qh
SET system_prefix = h.system_prefix,
    region_code   = h.region_code,
    customer_type = h.customer_type,
    parent_code   = h.parent_code
FROM public.medsec_hospitals h
WHERE h.id = qh.hospital_id
  AND ( qh.system_prefix IS DISTINCT FROM h.system_prefix
     OR qh.region_code   IS DISTINCT FROM h.region_code
     OR qh.customer_type IS DISTINCT FROM h.customer_type
     OR qh.parent_code   IS DISTINCT FROM h.parent_code );

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 看不再有 quote_history 體系不在 hospital_systems(理應全部對得到):
--   SELECT count(*) AS unmatched
--   FROM medsec_quote_history qh
--   LEFT JOIN hospital_systems s ON s.code = qh.system_prefix
--   WHERE qh.system_prefix IS NOT NULL AND s.code IS NULL;
--
-- 2. 抽看幾家:
--   SELECT DISTINCT qh.system_prefix, s.name
--   FROM medsec_quote_history qh
--   LEFT JOIN hospital_systems s ON s.code = qh.system_prefix
--   LIMIT 20;
--
-- 跑完前端硬重整 Tab3,體系欄應全部變中文,「⚠ 體系未對應」提示消失。
