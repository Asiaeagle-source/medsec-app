-- ============================================================
-- sql/v3/15_medsec_notes_discount.sql — D-2 notes 議價解析入庫表
-- ============================================================
-- 來源:medsec_quote_history.notes(備註一)業務手寫議價文字。
-- 解析腳本:tools/parse_notes_discount.py(Lynn 本機執行)。
-- 全量驗證(spec §0,2026-05-24):5,320 筆含議價 notes →
--   抽出 2,956 組乾淨三元組(產出率 26.7%),折數中位 0.769、
--   平均 0.773 —— 比 fuzzy 配對 0.87 更真實(無錯配/複製改價污染)。
--
-- 用途:Card B 折數真相主來源(notes > fuzzy)。
--   報維修單 → 篩 tx_type 含「维修」;報新購 → 篩「新购」。
--   解決 medsec_sales 無交易類型標籤的硬傷。
--
-- 唯一鍵:(crm_quote_type, crm_quote_no, product_code, seq)
--   同筆 notes 多組(參考多家醫院、報價+舊報價並列)用 seq 區分。
--
-- 累加式 upsert(ON CONFLICT DO UPDATE),腳本可重跑冪等。
-- 絕不 TRUNCATE。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_notes_discount (
  crm_quote_type   text    NOT NULL,
  crm_quote_no     text    NOT NULL,
  product_code     text    NOT NULL,
  seq              int     NOT NULL,                    -- 同筆 notes 多組時序號(1,2,3..)
  hospital_id      text,                                -- 從 quote_history 帶入
  quoted_price     numeric,                             -- 解析出的報價
  sale_price       numeric,                             -- 解析出的成交
  discount         numeric,                             -- 折數 = sale/quoted,護欄 0.3~1.2
  is_old_price     boolean NOT NULL DEFAULT false,      -- true=「舊報價/舊成交」格式(2023/04 前歷史價)
  tx_type          text,                                -- 交易類型標籤(汰旧/维修/新购/参考他院 可組合)
  source_notes     text,                                -- 原始 notes(備查;前 500 字截斷)
  parsed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (crm_quote_type, crm_quote_no, product_code, seq)
);

-- 自癒:既存表加欄(由本檔以外建過的小版本)
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS hospital_id   text;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS quoted_price  numeric;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS sale_price    numeric;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS discount      numeric;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS is_old_price  boolean NOT NULL DEFAULT false;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS tx_type       text;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS source_notes  text;
ALTER TABLE public.medsec_notes_discount ADD COLUMN IF NOT EXISTS parsed_at     timestamptz NOT NULL DEFAULT now();

-- ---------- 索引 ----------
-- Card B 主查詢:依本院某品項找折數歷史
CREATE INDEX IF NOT EXISTS idx_nd_hospital_product
  ON public.medsec_notes_discount (hospital_id, product_code);
-- 依品號跨醫院找折數(他院參考用)
CREATE INDEX IF NOT EXISTS idx_nd_product
  ON public.medsec_notes_discount (product_code);
-- 交易類型分流(Card B 維修 vs 新購)
CREATE INDEX IF NOT EXISTS idx_nd_txtype
  ON public.medsec_notes_discount (tx_type)
  WHERE tx_type IS NOT NULL;

COMMENT ON TABLE public.medsec_notes_discount IS
  'D-2 notes 議價解析(Sprint 3B Card B 折數真相主來源)。比 fuzzy 配對可信:無錯配/複製改價污染;補 2023/04 前歷史價 + 交易類型標籤。';

-- ---------- RLS:比照 medsec_quote_history(機密,業祕不可見折數) ----------
ALTER TABLE public.medsec_notes_discount ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS medsec_notes_discount_read  ON public.medsec_notes_discount;
DROP POLICY IF EXISTS medsec_notes_discount_write ON public.medsec_notes_discount;
CREATE POLICY medsec_notes_discount_read ON public.medsec_notes_discount
  FOR SELECT TO authenticated
  USING (public.auth_can_see_pricing());
CREATE POLICY medsec_notes_discount_write ON public.medsec_notes_discount
  FOR ALL TO authenticated
  USING (public.auth_can_edit_pricing())
  WITH CHECK (public.auth_can_edit_pricing());

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證(腳本跑完後在 SQL Editor 查)
-- ============================================================
-- 1) 總組數 ≈ 2956
--    SELECT count(*) FROM medsec_notes_discount;
--
-- 2) 折數分布中位 ≈ 0.77、min ≥ 0.30、max ≤ 1.20
--    SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY discount)::numeric, 3) AS 中位,
--           round(min(discount)::numeric,3), round(max(discount)::numeric,3),
--           count(*)
--    FROM medsec_notes_discount;
--
-- 3) 交易類型分布
--    SELECT tx_type, count(*) FROM medsec_notes_discount
--    WHERE tx_type IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;
--
-- 4) 歷史舊價(2023/04 前金礦)≈ 203
--    SELECT count(*) FROM medsec_notes_discount WHERE is_old_price;
--
-- 5) 業祕 perm test:secretary 跑 SELECT 應 0 列(RLS 擋住)
