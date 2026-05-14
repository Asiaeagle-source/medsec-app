-- ============================================================
-- Step 0: 補欄位 ALTER TABLE
-- 安全：使用 IF NOT EXISTS，重複跑也不會錯
-- ============================================================

ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS stock_qty numeric;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS unit_cost numeric;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS fee_type_code text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS fee_type text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS dms_category_code text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS dms_subcategory_code text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS warehouse_code text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS warehouse_name text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS supplier_code text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS supplier_name text;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS last_cost_orig numeric;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS last_cost_twd numeric;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS material_cost numeric;
ALTER TABLE medsec_products ADD COLUMN IF NOT EXISTS standard_cost numeric;

-- 驗證：列出 medsec_products 現有所有欄位
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name='medsec_products'
ORDER BY ordinal_position;
