-- ============================================================
-- sql/v3/01_quote_history_schema.sql — Sprint 3A 歷史報價/成交
-- ============================================================
-- 4 張新表(平行於 medsec_quotes,不動現有報價系統):
--   1. medsec_quote_history          — 統一報價/成交歷史(3A 主要)
--   2. medsec_hospital_pricing_strategy — 醫院慣用折數(3A 建表+可編輯)
--   3. medsec_nhi_pricing            — 健保價(3A 建空表,3B 才用)
--   4. medsec_product_nhi_mapping    — 品號↔健保碼(3A 建空表,3B 才用)
-- idempotent:CREATE TABLE/INDEX IF NOT EXISTS,可重跑。
-- RLS 在 02_quote_history_rls.sql。
-- 不碰 medsec_quotes / quote_advisories trigger / cindie.html。
-- ============================================================

-- ---------- 1. 統一報價/成交歷史 ----------
CREATE TABLE IF NOT EXISTS public.medsec_quote_history (
  id                  bigserial PRIMARY KEY,

  -- CRM 來源
  crm_quote_type      text,
  crm_quote_no        text,

  -- 客戶(customer_code 結尾可能有空格;hospital_id = TRIM 後)
  customer_code       text NOT NULL,
  customer_short_name text,
  hospital_id         text,
  hospital_name       text,
  parent_code         text,        -- JOIN hospitals 帶入(另一層母代碼)
  system_prefix       text,        -- 體系(JOIN hospitals 帶入)
  region_code         text,
  customer_type       text,

  -- 業務
  quoted_by_name      text,
  quoted_by_id        uuid REFERENCES public.profiles(id),

  -- 品項
  product_code        text NOT NULL,
  product_name        text,
  product_category    text,
  product_sn          text,

  -- 報價
  quoted_date         date,
  quoted_qty          numeric,
  quoted_unit_price   numeric,
  quoted_total        numeric,

  -- 確認(中間狀態)
  confirmation_code   text,
  confirmed_at        date,
  confirmed_by_name   text,

  -- 拋轉 ERP(有 erp_quote_no = 已拋,等同成交流程)
  erp_quote_type      text,
  erp_quote_no        text,
  promoted_at         date,
  promoted_by_name    text,

  -- 銷貨(ERP 銷貨明細匯入;成交資訊)
  sales_date          date,
  sales_unit_price    numeric,
  sales_qty           numeric,
  sales_total         numeric,

  -- 自動算狀態
  status text GENERATED ALWAYS AS (
    CASE
      WHEN sales_date IS NOT NULL THEN 'won'
      WHEN erp_quote_no IS NOT NULL AND btrim(erp_quote_no) <> '' THEN 'promoted'
      WHEN confirmation_code = 'Y' THEN 'confirmed'
      ELSE 'quoted'
    END
  ) STORED,

  source              text,        -- crm_import / erp_sales_import / medsec_app
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_qh_status CHECK (status IN ('quoted','confirmed','promoted','won')),
  CONSTRAINT chk_qh_source CHECK (
    source IS NULL OR source IN ('crm_import','erp_sales_import','medsec_app'))
);

-- 同一張 CRM 單同品號唯一 → upsert 依據。
-- 非 partial:PostgREST upsert 可用此為 onConflict;ERP 匯入列 crm_quote_no
-- 為 NULL,Postgres NULL 視為相異 → 多筆 NULL 不衝突,不影響。
CREATE UNIQUE INDEX IF NOT EXISTS idx_qh_crm_unique
  ON public.medsec_quote_history (crm_quote_no, product_code);
CREATE INDEX IF NOT EXISTS idx_qh_hospital_product
  ON public.medsec_quote_history (hospital_id, product_code, quoted_date DESC);
CREATE INDEX IF NOT EXISTS idx_qh_system_product
  ON public.medsec_quote_history (system_prefix, product_code, quoted_date DESC);
CREATE INDEX IF NOT EXISTS idx_qh_status
  ON public.medsec_quote_history (status, quoted_date DESC);

COMMENT ON TABLE public.medsec_quote_history IS
  'Sprint 3 統一報價/成交歷史(CRM 報價明細 + ERP 銷貨回填);Lynn 策略資訊,業祕不可見';

-- ---------- 2. 醫院慣用折數 ----------
CREATE TABLE IF NOT EXISTS public.medsec_hospital_pricing_strategy (
  hospital_id                text PRIMARY KEY REFERENCES public.medsec_hospitals(id),
  default_pricing_multiplier numeric DEFAULT 1.0,   -- 健保價倍數
  default_discount_rate      numeric,
  min_acceptable_price_pct   numeric,
  pricing_strategy           text DEFAULT 'standard'
    CHECK (pricing_strategy IN ('aggressive','standard','competitive','maintain')),
  notes                      text,
  updated_by                 uuid REFERENCES public.profiles(id),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.medsec_hospital_pricing_strategy IS
  '每家醫院慣用折數策略(健保價倍數);未設用預設 1.0 / standard';

-- ---------- 3. 健保價(3A 建空表,3B 才用)----------
CREATE TABLE IF NOT EXISTS public.medsec_nhi_pricing (
  id             bigserial PRIMARY KEY,
  nhi_code       text NOT NULL UNIQUE,
  product_name   text,
  payment_class  text,
  payment_points numeric,
  payment_price  numeric,
  ceiling_price  numeric,
  effective_date date,
  end_date       date,
  source_url     text,
  imported_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------- 4. 品號↔健保碼(3A 建空表,3B 才用)----------
CREATE TABLE IF NOT EXISTS public.medsec_product_nhi_mapping (
  id               bigserial PRIMARY KEY,
  product_code     text,
  nhi_code         text,
  match_confidence numeric,
  mapped_by        uuid REFERENCES public.profiles(id),
  mapped_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_code, nhi_code)
);

-- ============================================================
-- 驗證
-- ============================================================
-- \d medsec_quote_history
-- INSERT 一筆 sales_date 非空 → status 自動 'won'
-- INSERT erp_quote_no='2202xxx' → status 'promoted'
-- INSERT confirmation_code='Y' → status 'confirmed';否則 'quoted'
-- INSERT pricing_strategy='bad' → 應被 CHECK 擋下
