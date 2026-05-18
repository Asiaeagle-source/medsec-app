-- ============================================================
-- 21_stability_metrics.sql — 便宜常用品警示升級(Lynn 拍板)
-- ============================================================
-- 痛點:便宜常用品因金額小被忽略 → 累積缺貨,業祕痛苦不敢吵。
-- 只靠成本係數只解一半 → 加「使用頻率 + 穩定度」維度。
--
-- 決策(Lynn):本批「先不做 cost,只做穩定度」。
--   final_reorder_point = adjusted_reorder_point(已含季節)× stability_multiplier
--   cost_multiplier 保留 1.0(未來接成本再啟用,業祕不可見成本原則不變)。
--
-- 本檔 DROP+重建 v_inventory_intelligence(取代 20 的版本)並 CREATE OR
-- REPLACE advisory(只在 message/data 加 stability tier 標籤,結構不變)。
-- 執行順序:… → 19 → 20 → 21。idempotent 可重跑。不刪表、不改成本。
-- ============================================================

DROP VIEW IF EXISTS public.v_inventory_intelligence;

CREATE VIEW public.v_inventory_intelligence AS
SELECT
  i.product_code, i.product_name, i.product_category,
  i.effective_supply, i.is_discontinued, i.replacement_product_code,
  i.current_stock_qty, i.monthly_sales_history,
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
  -- 使用頻率 = 18 個月中有銷量月份數 / 18(歷史已 rolling 18)
  ROUND(st.active_months / 18.0, 2)                       AS usage_frequency,
  -- 波動係數 = 標準差 / 平均(越小越穩;無資料為 NULL)
  ROUND(st.hist_sd / NULLIF(st.hist_avg, 0), 2)           AS coefficient_of_variation,
  m.tier                                                  AS stability_tier,
  sm.smult                                                AS stability_multiplier,
  1.0                                                     AS cost_multiplier,  -- 本批保留(不漏成本)
  sm.frp                                                  AS final_reorder_point,
  -- 建議訂貨 = final_reorder_point(含季節×穩定)− 現有
  GREATEST(sm.frp - COALESCE(i.current_stock_qty, 0), 0)  AS suggested_order_qty,
  ROUND(
    COALESCE(
      agg.yoy_3m_avg * (agg.recent_3m_avg / NULLIF(agg.yoy_3m_avg, 0)),
      agg.recent_3m_avg
    ) * COALESCE(sc.reorder_multiplier, 1.0), 1
  ) AS next_month_forecast,
  -- 缺貨等級改用 final_reorder_point(高頻穩定品門檻自動拉高 → 早警示)
  CASE
    WHEN i.is_discontinued THEN '⚫ 停產'
    WHEN COALESCE(i.effective_supply, 0) = 0 AND COALESCE(agg.recent_3m_avg, 0) > 0
      THEN '🔴 嚴重缺貨'
    WHEN COALESCE(i.effective_supply, 0) < sm.frp * 0.3 THEN '🔴 嚴重缺貨'
    WHEN COALESCE(i.effective_supply, 0) < sm.frp * 0.7 THEN '🟠 即將缺貨'
    WHEN COALESCE(i.effective_supply, 0) < sm.frp       THEN '🟡 低於訂購點'
    ELSE '🟢 正常'
  END AS stock_alert_level,
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
) calc ON true
LEFT JOIN LATERAL (
  SELECT
    count(*) FILTER (WHERE (e.value #>> '{}')::numeric > 0)::numeric AS active_months,
    avg((e.value #>> '{}')::numeric)        AS hist_avg,
    stddev_samp((e.value #>> '{}')::numeric) AS hist_sd
  FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
) st ON true
LEFT JOIN LATERAL (
  SELECT q.uf, q.cv,
    CASE
      WHEN q.uf >= 0.75 AND q.cv < 0.5 THEN '⭐ 高頻穩定'
      WHEN q.uf >= 0.5  AND q.cv < 1.0 THEN '✓ 中頻'
      WHEN q.uf < 0.3                  THEN '波動偶用'
      ELSE '一般'
    END AS tier
  FROM (SELECT COALESCE(st.active_months, 0) / 18.0 AS uf,
               COALESCE(st.hist_sd, 0) / NULLIF(st.hist_avg, 0) AS cv) q
) m ON true
LEFT JOIN LATERAL (
  SELECT z.s AS smult,
         ROUND(calc.adjusted_reorder_point * z.s, 0) AS frp
  FROM (SELECT CASE m.tier
                 WHEN '⭐ 高頻穩定' THEN 1.3
                 WHEN '✓ 中頻'     THEN 1.1
                 ELSE 1.0
               END) z(s)
) sm ON true;

GRANT SELECT ON public.v_inventory_intelligence TO authenticated;

-- ---------- 報價送審警示:message/data 增補 stability tier ----------
-- 結構(advisory_type / severity / 既有 data 鍵)維持不變,只加標籤。
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
            || ' < 訂購點 ' || COALESCE(iv.final_reorder_point, 0)
            || ' → ' || iv.stock_alert_level
            || '〔' || COALESCE(iv.stability_tier, '一般') || '〕'
            || '(' || COALESCE(iv.season_label, '一般月')
            || ',季節 ' || COALESCE(iv.reorder_multiplier, 1.0)
            || 'x,穩定 ' || COALESCE(iv.stability_multiplier, 1.0) || 'x)'
            || ' 廠商欠交 ' || COALESCE(iv.overdue_qty, 0)
            || ',待進貨 ' || COALESCE(iv.pending_inbound_qty, 0)
            || ' YoY:' || COALESCE(iv.yoy_trend, '—'),
          jsonb_build_object('auto', 'true',
            'current_stock_qty', iv.current_stock_qty,
            'effective_supply', iv.effective_supply,
            'adjusted_reorder_point', iv.adjusted_reorder_point,
            'final_reorder_point', iv.final_reorder_point,
            'suggested_order_qty', iv.suggested_order_qty,
            'overdue_qty', iv.overdue_qty,
            'pending_inbound_qty', iv.pending_inbound_qty,
            'season_label', iv.season_label,
            'reorder_multiplier', iv.reorder_multiplier,
            'stability_tier', iv.stability_tier,
            'stability_multiplier', iv.stability_multiplier,
            'usage_frequency', iv.usage_frequency,
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
-- SELECT product_code, current_stock_qty, effective_supply,
--   usage_frequency, coefficient_of_variation, stability_tier,
--   stability_multiplier, adjusted_reorder_point, final_reorder_point,
--   suggested_order_qty, stock_alert_level
-- FROM v_inventory_intelligence WHERE product_code IN ('8001215','7BA30');
-- 8001215 便宜常用:usage_frequency 高 → '⭐ 高頻穩定' → final = adjusted×1.3
-- 7BA30   貴常用  :亦 '⭐ 高頻穩定' → ×1.3(本批無 cost,不再×0.8)
