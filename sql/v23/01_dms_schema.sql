-- ============================================================
-- V2.3 DMS「寄賣對帳」· 01 schema(只產出,交 Lynn 審後執行)
-- ------------------------------------------------------------
-- 產生 4 張表 + profiles.has_dms_access 欄(pre-flight)+ 權限 helper。
-- 執行順序:01_schema → 02_rls → 03_storage → 04_seed。
-- 對齊既有慣例:PK uuid、FK → profiles(id) uuid、金額 numeric、created_at timestamptz。
-- ============================================================

-- ---- pre-flight:profiles 加 has_dms_access(idempotent,已存在則略過)----
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS has_dms_access boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.profiles.has_dms_access IS 'DMS 寄賣對帳存取權(V2.3)';

-- ---- 權限 helper:has_dms_access = true 或 medsec_role IN (manager,accounting)----
CREATE OR REPLACE FUNCTION public.auth_can_dms()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND ( COALESCE(p.has_dms_access, false) = true
            OR p.medsec_role IN ('manager', 'accounting') )
  );
$$;
COMMENT ON FUNCTION public.auth_can_dms() IS 'DMS gate:has_dms_access 或 manager/accounting';

-- ============================================================
-- 1. consignment_sales · 刀表(寄賣銷貨明細,xlsx 上傳落地)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.consignment_sales (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period       text,                       -- yyyymm(對帳期別)
  sales_rep    text,                       -- 業務
  sale_date    date,                       -- 銷貨日
  order_no     text,                       -- 訂單號
  surgery_date date,                       -- 手術日
  customer     text,                       -- 客戶(醫院)
  doctor       text,
  product_no   text,                       -- 品號
  qty          numeric,
  follower     text,                       -- 跟刀
  patient      text,
  lot_serial   text,                       -- 批號/序號
  amount       numeric(14,2),
  category3    text,                        -- 分類三
  source_file  text,                        -- 來源檔名
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS cs_period_idx       ON public.consignment_sales (period);
CREATE INDEX IF NOT EXISTS cs_product_idx      ON public.consignment_sales (product_no);
CREATE INDEX IF NOT EXISTS cs_sale_date_idx    ON public.consignment_sales (sale_date);
CREATE INDEX IF NOT EXISTS cs_surgery_date_idx ON public.consignment_sales (surgery_date);
COMMENT ON TABLE public.consignment_sales IS 'DMS 刀表:寄賣銷貨明細(V2.3)';

-- ============================================================
-- 2. recon_statements · 對帳單(廠商月結單抬頭)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.recon_statements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_code    text,
  vendor_name    text,
  statement_no   text,
  statement_date date,
  hospital       text,
  order_no       text,
  file_url       text,                       -- dms-files bucket 內相對路徑
  status         text NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'matched', 'confirmed')),
  created_by     uuid REFERENCES public.profiles(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rs_vendor_idx ON public.recon_statements (vendor_code);
CREATE INDEX IF NOT EXISTS rs_status_idx ON public.recon_statements (status);
CREATE INDEX IF NOT EXISTS rs_date_idx   ON public.recon_statements (statement_date);
COMMENT ON TABLE public.recon_statements IS 'DMS 對帳單抬頭(V2.3)';

-- ============================================================
-- 3. recon_statement_items · 對帳單行項
-- ============================================================
CREATE TABLE IF NOT EXISTS public.recon_statement_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement_id uuid NOT NULL REFERENCES public.recon_statements(id) ON DELETE CASCADE,
  material_code text,                        -- 廠商料號
  item_name    text,
  spec         text,
  unit         text,
  qty          numeric,                      -- 對帳單數量
  matched_qty  numeric,                      -- 媒合到的刀表數量
  diff         numeric,                       -- qty - matched_qty
  match_status text NOT NULL DEFAULT 'pending'
               CHECK (match_status IN ('ok', 'diff', 'pending')),
  note         text
);
CREATE INDEX IF NOT EXISTS rsi_statement_idx ON public.recon_statement_items (statement_id);
CREATE INDEX IF NOT EXISTS rsi_material_idx  ON public.recon_statement_items (material_code);
COMMENT ON TABLE public.recon_statement_items IS 'DMS 對帳單行項 + 媒合結果(V2.3)';

-- ============================================================
-- 4. material_code_map · 廠商料號 ↔ 品號對照(媒合規則)
--    product_no_pattern:LIKE 樣式陣列(如 2968% / 757% / 精確 T43102INT)
--    exclude_products:命中 pattern 後要排除的品號
-- ============================================================
CREATE TABLE IF NOT EXISTS public.material_code_map (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_code       text,
  material_code     text,
  product_no_pattern text[]  NOT NULL DEFAULT '{}',
  exclude_products   text[]  NOT NULL DEFAULT '{}',
  category_label    text,
  active            boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS mcm_vendor_material_idx ON public.material_code_map (vendor_code, material_code);
CREATE INDEX IF NOT EXISTS mcm_active_idx          ON public.material_code_map (active);
COMMENT ON TABLE public.material_code_map IS 'DMS 廠商料號↔品號對照 / 媒合規則(V2.3)';
