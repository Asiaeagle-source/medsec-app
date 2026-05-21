-- ============================================================
-- sql/v3/06_quote_history_extra_columns.sql — 議價資訊欄(Sprint 3B 地基)
-- ============================================================
-- Lynn 重審 CRM 原檔對應後新加 4 欄(notes 已存在,本檔補 3 欄):
--   - discount_note    優惠價(議價/成交文字,原樣全文存)
--   - opportunity_type 銷售機會單別(議價軌跡分組鍵之一)
--   - opportunity_no   銷售機會單號(議價軌跡分組鍵之一)
--
-- 用途(Sprint 3B):同一銷售機會議價軌跡 =
--   WHERE opportunity_type=? AND opportunity_no=? ORDER BY quoted_date
-- AI 抽取成交價/折數/年月 → 來源 notes + discount_note。
--
-- idempotent:ADD COLUMN IF NOT EXISTS;不刪/不改/不動 RLS。
-- 索引:(opportunity_type, opportunity_no) 供 3B 議價軌跡查詢。
-- ============================================================

ALTER TABLE public.medsec_quote_history
  ADD COLUMN IF NOT EXISTS discount_note    text,
  ADD COLUMN IF NOT EXISTS opportunity_type text,
  ADD COLUMN IF NOT EXISTS opportunity_no   text;

COMMENT ON COLUMN public.medsec_quote_history.discount_note IS
  '優惠價/議價/成交文字,原樣全文存;空值存 NULL';
COMMENT ON COLUMN public.medsec_quote_history.opportunity_type IS
  '銷售機會單別(與 opportunity_no 一起貫穿議價過程的鍵)';
COMMENT ON COLUMN public.medsec_quote_history.opportunity_no IS
  '銷售機會單號(與 opportunity_type 一起貫穿議價過程的鍵)';

-- 議價軌跡查詢索引
CREATE INDEX IF NOT EXISTS idx_qh_opportunity
  ON public.medsec_quote_history (opportunity_type, opportunity_no, quoted_date DESC);

-- ============================================================
-- 驗證
-- ============================================================
-- \d medsec_quote_history    -- 應見 discount_note / opportunity_type / opportunity_no
-- SELECT count(*) FROM medsec_quote_history WHERE opportunity_no IS NOT NULL;
-- (本檔執行後為 0,等重新匯入 CRM 才會有資料)
