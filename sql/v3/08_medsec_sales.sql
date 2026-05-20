-- ============================================================
-- sql/v3/08_medsec_sales.sql — Sprint 3A Tab2 改寫:獨立成交流水表
-- ============================================================
-- 來源:成交價查詢 ERP 匯出(~206K 列,5 年累積)。
-- 設計:從 medsec_quote_history 的 sales_* 欄位移出,獨立 medsec_sales,
--   分離報價與成交,3B 用 lateral join 做稽核「最近一次報價 vs 實際成交」。
-- 唯一鍵 5 欄(spec): (invoice_no, product_code, product_sn, unit_price, qty)
--   邊界重複 ~35/206K = 0.017% 可接受。匯入用 ON CONFLICT DO NOTHING。
-- onConflict 欄序必須與 DB index 完全一致(學自 CRM 3 欄那次的教訓)。
-- idempotent:CREATE IF NOT EXISTS;RLS 同 pricing 模型。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_sales (
  id                bigserial PRIMARY KEY,

  -- ERP 來源
  invoice_no        text NOT NULL,            -- 發票號碼
  sales_date        date,                     -- 銷貨日期(Excel 序列日→date)

  -- 客戶(customer_code 結尾可能有空格;hospital_id = TRIM 後)
  category          text,                     -- 分類三
  customer_code     text,
  customer_name     text,                     -- 客戶全稱
  hospital_id       text,                     -- JOIN hospitals 帶入(可空)
  hospital_name     text,
  system_prefix     text,                     -- 體系(JOIN 帶入)
  region_code       text,
  customer_type     text,

  -- 品項
  product_code      text NOT NULL,
  product_name      text,
  product_category  text,                     -- 若 category 空可由主檔回填
  product_sn        text,                     -- 序號(可空 / 可 '0')

  -- 金額
  unit_price        numeric,
  qty               numeric,
  total             numeric,

  source            text DEFAULT 'erp_sales'
    CHECK (source IS NULL OR source IN ('erp_sales','medsec_app','manual')),
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- 5 欄唯一鍵(onConflict 必須完全一致)
CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_unique
  ON public.medsec_sales (invoice_no, product_code, product_sn, unit_price, qty);

-- 分析用索引
CREATE INDEX IF NOT EXISTS idx_sales_hospital_product
  ON public.medsec_sales (hospital_id, product_code, sales_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_system_product
  ON public.medsec_sales (system_prefix, product_code, sales_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_date
  ON public.medsec_sales (sales_date DESC);

COMMENT ON TABLE public.medsec_sales IS
  'Sprint 3A:ERP 發票成交明細(5 年流水,累加去重);與 medsec_quote_history 分離,稽核用 lateral join。Lynn 策略資訊,業祕不可見。';

-- ---------- RLS:同 quote_history 模型(manager/老闆 full、purchasing 讀、其餘無) ----------
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

-- ============================================================
-- 驗證
-- ============================================================
-- \d medsec_sales        -- 5 欄 idx_sales_unique
-- 匯入後:SELECT count(*) FROM medsec_sales;  -- 接近 206K
-- 同一檔重傳:不增加列數(do nothing 生效)
-- 邊界重複自查:
--   SELECT invoice_no, product_code, product_sn, unit_price, qty, count(*)
--   FROM medsec_sales
--   GROUP BY 1,2,3,4,5 HAVING count(*)>1 LIMIT 5;  -- 應 0 列
