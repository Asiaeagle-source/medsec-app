-- ============================================================
-- 07_create_hospital_product_codes.sql — 院內碼對照 (COPI10)
-- ============================================================
-- 為什麼:
--   發票品名欄位被業祕塞滿「球型 65035325 / 鑽石型 65035326 ...」這種
--   院內碼對照,塞 operation_rules.invoice_product_name 一個 text 欄不對。
--   應該結構化成一張表 (藍圖第七部分 #8 medsec_hospital_product_codes)。
--
-- 來源:鼎新 COPI10「客戶品號資料建立作業」匯出 8878 列。
--   COPI10 客戶代號集合 = V1 medsec_hospitals 185 家 (完全對齊,無雜質)。
--
-- 一個 (醫院, 我方品號) 可對多個院內碼 (例 CACN 41101 有 1Z00202 + 1Z03902)
-- → UNIQUE 放 (hospital_id, product_code, hospital_item_code) 三欄。
--
-- RLS:院內碼不機密 (業祕查任何醫院出貨都要對院內碼) → SELECT 全 authenticated;
--     write 限 manager / secretary。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_hospital_product_codes (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id         text NOT NULL REFERENCES public.medsec_hospitals(id) ON DELETE CASCADE,

  product_code        text,        -- 我方品號 (COPI10「品號」→ medsec_products.id)
  product_name        text,        -- 我方品名 snapshot
  product_spec        text,        -- 我方規格 snapshot

  hospital_item_code  text NOT NULL, -- ★ 院內碼 (COPI10「客戶品號」)
  hospital_item_name  text,        -- 客戶品名
  hospital_item_spec  text,        -- 客戶規格
  hospital_item_desc  text,        -- 客戶商品描述

  warranty_ratio      text,        -- 保固佔售價比率 (例 '0.00%')
  warranty_months     int,         -- 保固期數(月數)
  effective_date      date,        -- 生效日

  source              text NOT NULL DEFAULT 'COPI10',
  created_at          timestamptz NOT NULL DEFAULT now(),

  UNIQUE (hospital_id, product_code, hospital_item_code)
);

CREATE INDEX IF NOT EXISTS idx_hpc_hospital      ON public.medsec_hospital_product_codes(hospital_id);
CREATE INDEX IF NOT EXISTS idx_hpc_product       ON public.medsec_hospital_product_codes(product_code);
CREATE INDEX IF NOT EXISTS idx_hpc_item_code     ON public.medsec_hospital_product_codes(hospital_item_code);

ALTER TABLE public.medsec_hospital_product_codes ENABLE ROW LEVEL SECURITY;

-- SELECT:所有 authenticated (院內碼是出貨必查,不機密)
DROP POLICY IF EXISTS hpc_select ON public.medsec_hospital_product_codes;
CREATE POLICY hpc_select ON public.medsec_hospital_product_codes
  FOR SELECT TO authenticated USING (true);

-- write:manager / secretary (沿用 auth_medsec_role 既有 helper)
DROP POLICY IF EXISTS hpc_write ON public.medsec_hospital_product_codes;
CREATE POLICY hpc_write ON public.medsec_hospital_product_codes
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'secretary'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'secretary'));

COMMENT ON TABLE public.medsec_hospital_product_codes IS
  '院內碼對照 (COPI10)。一個我方品號可對多個醫院院內碼。SELECT 全開,write 限 manager/secretary。';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT count(*) FROM public.medsec_hospital_product_codes;
-- 預期 ETL 跑完 ≈ 8878 (或略少,self-skip 對不到的 hospital_id)
--
-- 看單一醫院 (CKUS 最多 1992 筆):
-- SELECT product_code, product_name, hospital_item_code, hospital_item_name
-- FROM public.medsec_hospital_product_codes
-- WHERE hospital_id = 'CKUS' ORDER BY product_code LIMIT 20;
