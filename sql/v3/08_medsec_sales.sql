-- ============================================================
-- sql/v3/08_medsec_sales.sql — Sprint 3A Tab2 改寫:獨立成交流水表
-- ============================================================
-- 來源:成交價查詢 ERP 匯出(~206K 列,5 年累積)。
-- 設計:從 medsec_quote_history 的 sales_* 欄位移出,獨立 medsec_sales,
--   分離報價與成交,3B 用 lateral join 做稽核「最近一次報價 vs 實際成交」。
-- 唯一鍵 5 欄(spec): (invoice_no, product_code, product_sn, unit_price, qty)
--   邊界重複 ~35/206K = 0.017% 可接受。匯入用 ON CONFLICT DO NOTHING。
-- onConflict 欄序必須與 DB index 完全一致(學自 CRM 3 欄那次的教訓)。
--
-- 重要:本檔自癒。先 CREATE IF NOT EXISTS,再 ALTER ADD COLUMN
-- IF NOT EXISTS 把 Tab2 會 insert 的「全部 18 欄」補齊;避免「先前
-- 建了較小版本造成 schema cache 找不到欄位」(customer_type / product_name
-- 等)。結尾 NOTIFY pgrst 強制 PostgREST reload schema cache。
-- 可重跑多次無副作用。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_sales (
  id                bigserial PRIMARY KEY,

  -- ERP 來源
  invoice_no        text NOT NULL,
  sales_date        date,

  -- 客戶
  category          text,
  customer_code     text,
  customer_name     text,
  hospital_id       text,
  hospital_name     text,
  system_prefix     text,
  region_code       text,
  customer_type     text,

  -- 品項
  product_code      text NOT NULL,
  product_name      text,
  product_category  text,
  product_sn        text,

  -- 金額
  unit_price        numeric,
  qty               numeric,
  total             numeric,

  source            text DEFAULT 'erp_sales'
    CHECK (source IS NULL OR source IN ('erp_sales','medsec_app','manual')),
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------- 自癒:若先前建了較小版本,把所有 Tab2 insert 的欄位都補齊 ----------
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS invoice_no       text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS sales_date       date;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS category         text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS customer_code    text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS customer_name    text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS hospital_id      text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS hospital_name    text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS system_prefix    text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS region_code      text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS customer_type    text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS product_code     text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS product_name     text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS product_category text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS product_sn       text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS unit_price       numeric;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS qty              numeric;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS total            numeric;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS source           text DEFAULT 'erp_sales';
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS notes            text;
ALTER TABLE public.medsec_sales ADD COLUMN IF NOT EXISTS created_at       timestamptz NOT NULL DEFAULT now();

-- ---------- 索引 ----------
CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_unique
  ON public.medsec_sales (invoice_no, product_code, product_sn, unit_price, qty);
CREATE INDEX IF NOT EXISTS idx_sales_hospital_product
  ON public.medsec_sales (hospital_id, product_code, sales_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_system_product
  ON public.medsec_sales (system_prefix, product_code, sales_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_date
  ON public.medsec_sales (sales_date DESC);

COMMENT ON TABLE public.medsec_sales IS
  'Sprint 3A:ERP 發票成交明細(5 年流水,累加去重);與 medsec_quote_history 分離,稽核用 lateral join。Lynn 策略資訊,業祕不可見。';

-- ---------- RLS:同 quote_history 模型(manager/老闆 full、purchasing 讀、其餘無)----------
ALTER TABLE public.medsec_sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS medsec_sales_read  ON public.medsec_sales;
DROP POLICY IF EXISTS medsec_sales_write ON public.medsec_sales;
CREATE POLICY medsec_sales_read ON public.medsec_sales
  FOR SELECT TO authenticated
  USING (public.auth_can_see_pricing());
CREATE POLICY medsec_sales_write ON public.medsec_sales
  FOR ALL TO authenticated
  USING (public.auth_can_edit_pricing())
  WITH CHECK (public.auth_can_edit_pricing());

-- ---------- 強制 PostgREST 重載 schema cache ----------
-- 補欄後若不 reload,前端會繼續看到「Could not find the 'X' column in schema cache」。
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 18 個 insert 欄全在:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='medsec_sales'
--    ORDER BY ordinal_position;
-- 2. 唯一索引 5 欄:
--    SELECT indexdef FROM pg_indexes
--    WHERE indexname='idx_sales_unique';
-- 3. 匯入後重傳同檔不增加列數(DO NOTHING)。
