-- ============================================================
-- 19_inventory_view.sql — Sprint 2.5 補強(智慧庫存 view + 警示)
-- ============================================================
-- v_inventory_intelligence:同期(YoY)比較 + 季節係數 → 訂購點 / 預測 /
--   季節調整缺貨等級。複雜邏輯放 view(generated column 做不到)。
--
-- 注意:SQL 不能在同一 SELECT 互引別名,故用 LATERAL 先算聚合(agg)
--   與訂購點(calc),外層再衍生 → 可直接 CREATE OR REPLACE,可重跑。
-- 依賴:16(monthly_sales_history)、18(medsec_seasonal_calendar)、
--   15(effective_supply generated)。
-- ============================================================

CREATE OR REPLACE VIEW public.v_inventory_intelligence AS
SELECT
  i.product_code, i.product_name, i.product_category,
  i.effective_supply, i.is_discontinued, i.replacement_product_code,
  i.overdue_inbound_qty, i.current_stock_qty, i.monthly_sales_history,
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
  END AS stock_alert_level
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

-- ---------- 報價送審 → 季節調整版自動警示 ----------
-- 取代 15 的 medsec_quote_autostock_advisory:改查 v_inventory_intelligence
-- (季節 + YoY 調整後的 stock_alert_level / adjusted_reorder_point)。
CREATE OR REPLACE FUNCTION public.medsec_quote_autostock_advisory()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it  record;
  iv  record;
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

      -- 缺貨(🔴 critical / 🟠 即將缺貨 → warning)
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
          it.product_code || ' 有效供應 ' || COALESCE(iv.effective_supply, 0)
            || ' < 季節調整訂購點 ' || COALESCE(iv.adjusted_reorder_point, 0)
            || '(當前 ' || COALESCE(iv.season_label, '一般月')
            || ',係數 ' || COALESCE(iv.reorder_multiplier, 1.0) || 'x)'
            || ' YoY:' || COALESCE(iv.yoy_trend, '—'),
          jsonb_build_object('auto', 'true',
            'effective_supply', iv.effective_supply,
            'adjusted_reorder_point', iv.adjusted_reorder_point,
            'season_label', iv.season_label,
            'reorder_multiplier', iv.reorder_multiplier,
            'yoy_trend', iv.yoy_trend,
            'next_month_forecast', iv.next_month_forecast,
            'stock_alert_level', iv.stock_alert_level));
      END IF;

      -- 停產
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
-- 驗證
-- ============================================================
-- 1. SELECT product_code, recent_3m_avg, yoy_3m_avg, yoy_trend,
--      adjusted_reorder_point, next_month_forecast, stock_alert_level
--    FROM v_inventory_intelligence LIMIT 20;
-- 2. 報價含缺貨/停產品項 → status pending_review → 自動進 advisories
--    (message 含季節 label + 係數 + YoY)
