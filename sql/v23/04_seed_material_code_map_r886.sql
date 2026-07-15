-- ============================================================
-- V2.3 DMS · 04 種子:向生 R886 料號對照 4 筆(只產出,交 Lynn 審後執行)
-- ------------------------------------------------------------
-- product_no_pattern 是 SQL LIKE 樣式陣列(% 為萬用字元);前端媒合時逐一比對品號。
-- category_label 供媒合結果頁分組顯示,Lynn 可調整。
-- ============================================================
INSERT INTO public.material_code_map
  (vendor_code, material_code, product_no_pattern, exclude_products, category_label, active)
VALUES
  -- 1825226 → 精確對應 T43102INT
  ('R886', '1825226',  ARRAY['T43102INT'], ARRAY[]::text[],        'T43102INT',        true),
  -- 1826395 → 2968%(Olif/Clydesdale)
  ('R886', '1826395',  ARRAY['2968%'],     ARRAY[]::text[],        'Olif/Clydesdale',  true),
  -- 18263951 → 777%(Elevate)
  ('R886', '18263951', ARRAY['777%'],      ARRAY[]::text[],        'Elevate',          true),
  -- 1826433 → 757%,但排除 7570955
  ('R886', '1826433',  ARRAY['757%'],      ARRAY['7570955'],       '757 系列',          true)
ON CONFLICT DO NOTHING;

-- 驗證:SELECT material_code, product_no_pattern, exclude_products, category_label
--       FROM public.material_code_map WHERE vendor_code = 'R886' ORDER BY material_code;
