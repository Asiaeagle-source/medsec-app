-- ============================================================
-- sql/v3/10_medsec_nhi_prices.sql — 健保價匯入(3B 封頂前置資料層)
-- ============================================================
-- 來源:扣除器械LegendMR8_現行有效健保點數與天花板.xlsx
--   sheet「現行有效_已對到」+ sheet「差額給付_自費天花板」
--   ~322 + 46 列 = 368 列(7% 涵蓋率,其餘多為自費品無健保碼)。
--
-- 命名:`medsec_nhi_prices`(複數,新表)。
--   舊 `medsec_nhi_pricing`(單數,sql/v3/01 留的 Sprint 3 placeholder)
--   schema 不同且未匯入過資料,留著不動由 Lynn 日後決定是否清掉。
--
-- 3 欄唯一鍵: (product_code, nhi_code, effective_from)
--   同品號可能多健保碼/多生效期(如 015040 → 55817 與 90744 兩規格),
--   故需 3 欄區別。匯入用 ON CONFLICT DO NOTHING(累加式)。
-- onConflict 欄序必須與 DB index 一致(吃過 CRM 3 欄 / 成交 5 欄的虧)。
--
-- 自癒、idempotent;ADD COLUMN IF NOT EXISTS 涵蓋表先存在較小版本。
-- 結尾 NOTIFY pgrst 自動 reload schema cache。
-- 本檔不做封頂提醒邏輯(那是 3B Cards B/C 的事)。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_nhi_prices (
  id                bigserial PRIMARY KEY,

  product_code      text NOT NULL,           -- 品號(TRIM)
  nhi_code          text,                    -- 健保特材碼
  nhi_points        numeric,                 -- 健保支付點數(全額給付 → 即上限)
  self_pay_ceiling  numeric,                 -- 核定費用/自費天花板(僅自付差額有值)
  payment_type      text,                    -- 全額給付 / 自付差額 / 空
  diff_pay_note     text,                    -- 差額給付標註

  effective_from    date,                    -- 生效日(民國轉西元)
  effective_to      date,                    -- 生效迄日;999/12/31 存 NULL(現行有效)

  nhi_name          text,                    -- NHI 品名
  nhi_spec          text,                    -- NHI 產品型號規格

  match_status      text,                    -- 對應狀態(codex 對碼用)
  match_note        text,                    -- 對應說明(稽核)
  source_sheet      text,                    -- 來自哪個 sheet(現行有效/差額給付)

  imported_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------- 自癒:若先前已建較小版本,把全部欄補齊 ----------
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS product_code      text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS nhi_code          text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS nhi_points        numeric;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS self_pay_ceiling  numeric;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS payment_type      text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS diff_pay_note     text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS effective_from    date;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS effective_to      date;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS nhi_name          text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS nhi_spec          text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS match_status      text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS match_note        text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS source_sheet      text;
ALTER TABLE public.medsec_nhi_prices ADD COLUMN IF NOT EXISTS imported_at       timestamptz NOT NULL DEFAULT now();

-- ---------- 索引 ----------
CREATE UNIQUE INDEX IF NOT EXISTS idx_nhi_unique
  ON public.medsec_nhi_prices (product_code, nhi_code, effective_from);

-- 品號查健保價(報價封頂用,3B Cards B/C 會打)
CREATE INDEX IF NOT EXISTS idx_nhi_product_current
  ON public.medsec_nhi_prices (product_code, effective_to NULLS FIRST);
CREATE INDEX IF NOT EXISTS idx_nhi_code
  ON public.medsec_nhi_prices (nhi_code);

COMMENT ON TABLE public.medsec_nhi_prices IS
  'Sprint 3B 健保價(累加式)。封頂邏輯:自付差額 + self_pay_ceiling>0 → 上限=self_pay_ceiling;其餘 → 上限=nhi_points;取 effective_to is null 或 >= today 的現行有效版。';

-- ---------- RLS:同 pricing 模型(Lynn/老闆 full、Cindie 讀、業祕無) ----------
ALTER TABLE public.medsec_nhi_prices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS medsec_nhi_prices_read  ON public.medsec_nhi_prices;
DROP POLICY IF EXISTS medsec_nhi_prices_write ON public.medsec_nhi_prices;
CREATE POLICY medsec_nhi_prices_read ON public.medsec_nhi_prices
  FOR SELECT TO authenticated
  USING (public.auth_can_see_pricing());
CREATE POLICY medsec_nhi_prices_write ON public.medsec_nhi_prices
  FOR ALL TO authenticated
  USING (public.auth_can_edit_pricing())
  WITH CHECK (public.auth_can_edit_pricing());

-- ---------- 強制 PostgREST 重載 schema cache ----------
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 14 欄都在(13 寫入欄 + id + imported_at = 15;扣 id 共 14):
--    SELECT count(*) FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='medsec_nhi_prices';
--    -- 應 15
-- 2. 唯一索引 3 欄:
--    SELECT indexdef FROM pg_indexes WHERE indexname='idx_nhi_unique';
-- 3. 匯入後驗實際列數 ≈ 368(322+46):
--    SELECT count(*) FROM medsec_nhi_prices;
-- 4. 重傳同檔 → 不增加(DO NOTHING 生效):
--    上傳兩次後再 SELECT count(*) 應一樣。
-- 5. 封頂查詢範例(3B Cards B/C 將用):
--    SELECT product_code,
--      CASE WHEN payment_type='自付差額' AND self_pay_ceiling>0
--           THEN self_pay_ceiling ELSE nhi_points END AS price_cap
--    FROM medsec_nhi_prices
--    WHERE product_code='015040'
--      AND (effective_to IS NULL OR effective_to >= current_date)
--    ORDER BY effective_from DESC LIMIT 1;
