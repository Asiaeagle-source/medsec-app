-- ============================================================
-- sql/v3/09_qh_status_opportunity_stats.sql — status 簡化 + 銷售機會統計 RPC
-- ============================================================
-- 兩項變更:
--
-- 1) status generated 運算式改為:
--      erp_quote_no 非空 → 'won'(拋轉=成交)
--      confirmation_code = 'Y'  → 'confirmed'
--      其餘 → 'quoted'
--    移除舊邏輯:sales_date→'won'(報價表無 sales_*,移到 medsec_sales)、
--    'promoted'(拋轉等同成交,合併入 won)。
--    GENERATED 表達式無法 ALTER,必須:
--      DROP idx_qh_status → DROP chk_qh_status → DROP COLUMN status
--      → ADD COLUMN(新表達式)→ ADD CHECK(新值集)→ 重建索引
--
-- 2) Tab3 統計以「銷售機會」為單位(總單數 / 成交單數 / 成交率),
--    不以明細列數。新增 RPC qh_opp_stats(filters) 一次回 (total, won, rate)。
--    PostgREST 不支援 COUNT DISTINCT,用 RPC 最乾淨且最快。
--
-- 自癒、idempotent、無破壞性(資料保留,只重建 generated 欄)。
-- 結尾 NOTIFY pgrst 自動 reload schema cache。
-- ============================================================

-- ---------- 1. status 重建 ----------
DROP INDEX  IF EXISTS public.idx_qh_status;
ALTER TABLE public.medsec_quote_history DROP CONSTRAINT IF EXISTS chk_qh_status;
ALTER TABLE public.medsec_quote_history DROP COLUMN IF EXISTS status;

ALTER TABLE public.medsec_quote_history
  ADD COLUMN status text GENERATED ALWAYS AS (
    CASE
      WHEN erp_quote_no IS NOT NULL AND btrim(erp_quote_no) <> '' THEN 'won'
      WHEN confirmation_code = 'Y' THEN 'confirmed'
      ELSE 'quoted'
    END
  ) STORED;

ALTER TABLE public.medsec_quote_history
  ADD CONSTRAINT chk_qh_status CHECK (status IN ('quoted','confirmed','won'));

CREATE INDEX IF NOT EXISTS idx_qh_status
  ON public.medsec_quote_history (status, quoted_date DESC);

-- ---------- 2. 銷售機會統計 RPC ----------
CREATE OR REPLACE FUNCTION public.qh_opp_stats(
  p_hospital text DEFAULT NULL,
  p_system   text DEFAULT NULL,
  p_product  text DEFAULT NULL,
  p_status   text DEFAULT NULL,
  p_since    date DEFAULT NULL
)
RETURNS TABLE(total bigint, won bigint, rate numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH o AS (
    SELECT btrim(opportunity_type) AS t,
           btrim(opportunity_no)   AS n,
           bool_or(erp_quote_no IS NOT NULL AND btrim(erp_quote_no) <> '') AS hasw
    FROM public.medsec_quote_history
    WHERE opportunity_type IS NOT NULL AND btrim(opportunity_type) <> ''
      AND opportunity_no   IS NOT NULL AND btrim(opportunity_no)   <> ''
      AND (p_hospital IS NULL OR hospital_id   = p_hospital)
      AND (p_system   IS NULL OR system_prefix = p_system)
      AND (p_product  IS NULL OR product_code ILIKE '%' || p_product || '%')
      AND (p_status   IS NULL OR status        = p_status)
      AND (p_since    IS NULL OR quoted_date  >= p_since)
    GROUP BY t, n
  )
  SELECT
    count(*)::bigint                            AS total,
    count(*) FILTER (WHERE hasw)::bigint        AS won,
    CASE WHEN count(*) = 0 THEN 0
         ELSE round(100.0 * count(*) FILTER (WHERE hasw) / count(*), 1)
    END                                         AS rate
  FROM o;
$$;

GRANT EXECUTE ON FUNCTION public.qh_opp_stats(text,text,text,text,date) TO authenticated;

-- ---------- 強制 PostgREST 重載 schema cache ----------
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證(Lynn 已驗算:1272 / 192 / 15.1%)
-- ============================================================
-- 1) status 欄分佈(應只見 quoted/confirmed/won):
--    SELECT status, count(*) FROM medsec_quote_history GROUP BY 1;
--
-- 2) 銷售機會統計(無篩選,全範圍):
--    SELECT * FROM qh_opp_stats();
--    -- 期望 ≈ total=1272, won=192, rate=15.1
--
-- 3) 帶條件範例:
--    SELECT * FROM qh_opp_stats(NULL,'VG',NULL,NULL,'2025-01-01');
