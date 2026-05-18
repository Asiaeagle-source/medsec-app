-- ============================================================
-- 20_effective_supply_fix.sql — 重大業務邏輯修正(Lynn 拍板)
-- ============================================================
-- 「有效供應」定義錯誤:
--   舊 effective_supply = overdue_inbound_qty + current_stock_qty
--       → 把廠商欠交當有效供應 → 缺貨被低估、誤判正常
--   新 effective_supply = COALESCE(current_stock_qty,0)
--       → 只算「實際在倉」,缺貨判斷保守。
--
-- 逾期/待進貨/採購未確認 3 欄保留(Cindie 仍要看,不刪不合併),
-- 只當「風險參考」進 view(overdue_qty / pending_inbound_qty /
-- pending_purchase_qty / supply_risk_level),不計入有效供應。
--
-- generated 欄的生成式無法 ALTER,需 DROP+ADD;而 v_inventory_intelligence
-- 依賴此欄,故本檔順序:DROP VIEW → 改欄 → 重建 view(本檔為 view 的
-- 最新權威定義,取代 19 的版本)→ CREATE OR REPLACE advisory。
-- 執行順序:… → 19 → 20。idempotent 可重跑。
-- ============================================================

DROP VIEW IF EXISTS public.v_inventory_intelligence;

ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS effective_supply;
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN effective_supply numeric
  GENERATED ALWAYS AS (COALESCE(current_stock_qty, 0)) STORED;

COMMENT ON COLUMN public.medsec_product_inventory.effective_supply IS
  '有效供應 = 只算實際在倉(current_stock_qty);逾期/待進貨不計入';

CREATE VIEW public.v_inventory_intelligence AS
SELECT
  i.product_code, i.product_name, i.product_category,
  i.effective_supply, i.is_discontinued, i.replacement_product_code,
  i.current_stock_qty, i.monthly_sales_history,
  -- 風險參考欄(不計入有效供應)
  COALESCE(i.overdue_inbound_qty, 0)   AS overdue_qty,
  COALESCE(i.pending_inbound_qty, 0)   AS pending_inbound_qty,
  COALESCE(i.pending_purchase_qty, 0)  AS pending_purchase_qty,
  agg.current_month_sales,
  agg.last_year_same_month,
  agg.recent_3m_avg,
  agg.yoy_3m_avg,
  agg.sales_stddev,
  sc.season, sc.season_label,
  COALESCE(sc.reorder_multiplier, 1.0) AS reorder_multiplier,
  CASE
    WHEN agg.yoy_3m_avg IS NULL OR agg.yoy_3m_avg = 0 THEN '— 無同期資料'
    WHEN agg.recent_3m_avg > agg.yoy_3m_avg * 1.2
      THEN '↗ 同期成長 ' || ROUND((agg.recent_3m_avg / agg.yoy_3m_avg - 1) * 100) || '%'
    WHEN agg.recent_3m_avg < agg.yoy_3m_avg * 0.8
      THEN '↘ 同期下滑 ' || ROUND((1 - agg.recent_3m_avg / agg.yoy_3m_avg) * 100) || '%'
    ELSE '→ 同期平穩'
  END AS yoy_trend,
  calc.adjusted_reorder_point,
  -- 建議訂貨 = 季節調整訂購點 − 現有(只現有,不抵逾期/待進貨)
  GREATEST(calc.adjusted_reorder_point - COALESCE(i.current_stock_qty, 0), 0)
    AS suggested_order_qty,
  ROUND(
    COALESCE(
      agg.yoy_3m_avg * (agg.recent_3m_avg / NULLIF(agg.yoy_3m_avg, 0)),
      agg.recent_3m_avg
    ) * COALESCE(sc.reorder_multiplier, 1.0), 1
  ) AS next_month_forecast,
  CASE
    WHEN i.is_discontinued THEN '⚫ 停產'
    WHEN COALESCE(i.effective_supply, 0) = 0 AND COALESCE(agg.recent_3m_avg, 0) > 0
      THEN '🔴 嚴重缺貨'
    WHEN COALESCE(i.effective_supply, 0) < calc.adjusted_reorder_point * 0.3
      THEN '🔴 嚴重缺貨'
    WHEN COALESCE(i.effective_supply, 0) < calc.adjusted_reorder_point * 0.7
      THEN '🟠 即將缺貨'
    WHEN COALESCE(i.effective_supply, 0) < calc.adjusted_reorder_point
      THEN '🟡 低於訂購點'
    ELSE '🟢 正常'
  END AS stock_alert_level,
  -- 綜合供應風險(Cindie 自行判斷:缺貨但有訂單在等 vs 缺貨且無訂單)
  CASE
    WHEN COALESCE(i.effective_supply, 0) = 0
         AND (COALESCE(i.overdue_inbound_qty, 0) + COALESCE(i.pending_inbound_qty, 0)) > 0
      THEN '⚠️ 缺貨,但有訂單在等(逾期 '
        || COALESCE(i.overdue_inbound_qty, 0) || ' + 待進貨 '
        || COALESCE(i.pending_inbound_qty, 0) || ')'
    WHEN COALESCE(i.effective_supply, 0) = 0
      THEN '🔴 缺貨,且無訂單'
    ELSE 'normal'
  END AS supply_risk_level
FROM public.medsec_product_inventory i
LEFT JOIN public.medsec_seasonal_calendar sc
  ON sc.month_num = EXTRACT(MONTH FROM now())::int
LEFT JOIN LATERAL (
  SELECT
    (COALESCE(i.monthly_sales_history, '{}'::jsonb)
       ->> to_char(now(), 'YYYY-MM'))::numeric AS current_month_sales,
    (COALESCE(i.monthly_sales_history, '{}'::jsonb)
       ->> to_char(now() - interval '12 months', 'YYYY-MM'))::numeric AS last_year_same_month,
    (SELECT avg((e.value #>> '{}')::numeric)
       FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
       WHERE e.key >= to_char(now() - interval '3 months', 'YYYY-MM')) AS recent_3m_avg,
    (SELECT avg((e.value #>> '{}')::numeric)
       FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
       WHERE e.key BETWEEN to_char(now() - interval '15 months', 'YYYY-MM')
                       AND to_char(now() - interval '12 months', 'YYYY-MM')) AS yoy_3m_avg,
    (SELECT stddev_samp((e.value #>> '{}')::numeric)
       FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
       WHERE e.key >= to_char(now() - interval '6 months', 'YYYY-MM')) AS sales_stddev
) agg ON true
LEFT JOIN LATERAL (
  SELECT ROUND(
    GREATEST(
      COALESCE(agg.recent_3m_avg, 0) * 1.5,
      COALESCE(agg.recent_3m_avg, 0) + COALESCE(agg.sales_stddev, 0) * 1.65
    ) * COALESCE(sc.reorder_multiplier, 1.0), 0
  ) AS adjusted_reorder_point
) calc ON true;

GRANT SELECT ON public.v_inventory_intelligence TO authenticated;

-- ---------- 報價送審警示:訊息改用「現有庫存」口徑 ----------
-- 結構(advisory_type / severity / data 鍵)維持不變,只改 message 文字
-- 與 data 增補 overdue/pending,讓 Lynn 看得懂保守口徑。
CREATE OR REPLACE FUNCTION public.medsec_quote_autostock_advisory()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it record;
  iv record;
BEGIN
  IF NEW.status = 'pending_review'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    FOR it IN
      SELECT id, product_code FROM public.medsec_quote_items
      WHERE quote_id = NEW.id AND product_code IS NOT NULL
    LOOP
      SELECT * INTO iv FROM public.v_inventory_intelligence
        WHERE product_code = it.product_code;
      IF NOT FOUND THEN CONTINUE; END IF;

      IF iv.stock_alert_level IN ('🔴 嚴重缺貨', '🟠 即將缺貨')
         AND NOT EXISTS (
           SELECT 1 FROM public.medsec_quote_advisories
           WHERE quote_item_id = it.id AND advisory_type = 'low_stock'
             AND data ->> 'auto' = 'true') THEN
        INSERT INTO public.medsec_quote_advisories
          (quote_id, quote_item_id, advisor_id, advisory_type, severity, message, data)
        VALUES (
          NEW.id, it.id, NULL, 'low_stock',
          CASE WHEN iv.stock_alert_level = '🔴 嚴重缺貨' THEN 'critical' ELSE 'warning' END,
          it.product_code || ' 現有庫存 ' || COALESCE(iv.current_stock_qty, 0)
            || ' < 季節調整訂購點 ' || COALESCE(iv.adjusted_reorder_point, 0)
            || ' → ' || iv.stock_alert_level
            || '(' || COALESCE(iv.season_label, '一般月')
            || ',係數 ' || COALESCE(iv.reorder_multiplier, 1.0) || 'x)'
            || ' 廠商欠交 ' || COALESCE(iv.overdue_qty, 0)
            || ',待進貨 ' || COALESCE(iv.pending_inbound_qty, 0)
            || ' YoY:' || COALESCE(iv.yoy_trend, '—'),
          jsonb_build_object('auto', 'true',
            'current_stock_qty', iv.current_stock_qty,
            'effective_supply', iv.effective_supply,
            'adjusted_reorder_point', iv.adjusted_reorder_point,
            'suggested_order_qty', iv.suggested_order_qty,
            'overdue_qty', iv.overdue_qty,
            'pending_inbound_qty', iv.pending_inbound_qty,
            'season_label', iv.season_label,
            'reorder_multiplier', iv.reorder_multiplier,
            'yoy_trend', iv.yoy_trend,
            'next_month_forecast', iv.next_month_forecast,
            'stock_alert_level', iv.stock_alert_level,
            'supply_risk_level', iv.supply_risk_level));
      END IF;

      IF iv.is_discontinued
         AND NOT EXISTS (
           SELECT 1 FROM public.medsec_quote_advisories
           WHERE quote_item_id = it.id AND advisory_type = 'product_discontinued'
             AND data ->> 'auto' = 'true') THEN
        INSERT INTO public.medsec_quote_advisories
          (quote_id, quote_item_id, advisor_id, advisory_type, severity, message, data)
        VALUES (
          NEW.id, it.id, NULL, 'product_discontinued', 'critical',
          it.product_code || ' 已停產'
            || CASE WHEN iv.replacement_product_code IS NOT NULL
                    THEN ',替代:' || iv.replacement_product_code ELSE '' END,
          jsonb_build_object('auto', 'true',
            'replacement_product_code', iv.replacement_product_code));
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_quote_autostock_advisory ON public.medsec_quotes;
CREATE TRIGGER trg_quote_autostock_advisory
  AFTER INSERT OR UPDATE OF status ON public.medsec_quotes
  FOR EACH ROW EXECUTE FUNCTION public.medsec_quote_autostock_advisory();

-- ============================================================
-- 驗證(Acceptance)
-- ============================================================
-- PF3003 現有7/逾期120/月銷~9 → effective_supply=7 → 應 🟠 即將缺貨
-- 7BA30  現有0/逾期3 /月銷~45 → effective_supply=0 → 應 🔴 嚴重缺貨
-- SELECT product_code, current_stock_qty, effective_supply, overdue_qty,
--   pending_inbound_qty, stock_alert_level, supply_risk_level,
--   adjusted_reorder_point, suggested_order_qty
-- FROM v_inventory_intelligence WHERE product_code IN ('PF3003','7BA30');
