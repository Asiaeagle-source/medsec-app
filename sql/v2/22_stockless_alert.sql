-- ============================================================
-- 22_stockless_alert.sql — 滯銷 / 過度備貨警示(Lynn 拍板)
-- ============================================================
-- Cindie 也要看「滯銷/過度備貨/市場萎縮」,對應調整訂貨建議。
-- 滯銷是「採購內部資訊」:不進 quote_advisories(業祕不該看到,
-- 否則影響 Lynn 議價策略)→ 本檔「不」改 advisory function。
--
-- 本檔 DROP+重建 v_inventory_intelligence(取代 21,沿用全部既有欄位
-- 並新增滯銷相關欄位)。advisory 維持 21 版不動。
-- 不自動 is_discontinued、不自動取消廠商單、不做歷史追蹤。
-- 執行順序:… → 19 → 20 → 21 → 22。idempotent。不刪表、不刪欄。
-- ============================================================

DROP VIEW IF EXISTS public.v_inventory_intelligence;

CREATE VIEW public.v_inventory_intelligence AS
SELECT
  i.product_code, i.product_name, i.product_category,
  i.effective_supply, i.is_discontinued, i.replacement_product_code,
  i.current_stock_qty, i.monthly_sales_history,
  COALESCE(i.monthly_avg_sales, 0)     AS monthly_avg_sales,
  COALESCE(i.overdue_inbound_qty, 0)   AS overdue_qty,
  COALESCE(i.pending_inbound_qty, 0)   AS pending_inbound_qty,
  COALESCE(i.pending_purchase_qty, 0)  AS pending_purchase_qty,
  -- 在途 = 逾期 + 待進貨(顯示用,不計入有效供應)
  (COALESCE(i.overdue_inbound_qty, 0) + COALESCE(i.pending_inbound_qty, 0)) AS in_transit_qty,
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
  ROUND(st.active_months / 18.0, 2)             AS usage_frequency,
  ROUND(st.hist_sd / NULLIF(st.hist_avg, 0), 2) AS coefficient_of_variation,
  m.tier                                        AS stability_tier,
  sm.smult                                      AS stability_multiplier,
  1.0                                           AS cost_multiplier,
  sm.frp                                        AS final_reorder_point,
  -- 滯銷相關
  x.mws                                         AS months_without_sales,
  x.r6_total                                    AS recent_6m_total_sales,
  ROUND(x.std_ratio, 1)                         AS supply_to_demand_ratio,
  ROUND(GREATEST(x.decline, 0), 2)              AS yoy_decline_rate,
  sl.lvl                                        AS stockless_alert_level,
  fin.soq                                       AS suggested_order_qty,
  fin.action                                    AS suggestion_action,
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
) sm ON true
-- 滯銷指標
LEFT JOIN LATERAL (
  SELECT
    -- 連續無銷月數:從本月倒推,第一個有銷量月份的 g(無則 18)
    COALESCE(
      MIN(gg.g) FILTER (
        WHERE (COALESCE(i.monthly_sales_history, '{}'::jsonb)
                 ->> to_char(now() - make_interval(months => gg.g), 'YYYY-MM'))::numeric > 0
      ), 18) AS mws,
    (SELECT COALESCE(sum((e.value #>> '{}')::numeric), 0)
       FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
       WHERE e.key >= to_char(now() - interval '6 months', 'YYYY-MM')) AS r6_total,
    -- 已上傳的月歷史筆數(沒資料不能斷言「連 N 月無銷」)
    (SELECT count(*) FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb))) AS hist_keys,
    (COALESCE(i.current_stock_qty, 0)
       + COALESCE(i.pending_inbound_qty, 0)
       + COALESCE(i.overdue_inbound_qty, 0))
      / NULLIF(COALESCE(i.monthly_avg_sales, 0), 0) AS std_ratio,
    GREATEST(0, 1 - (agg.recent_3m_avg / NULLIF(agg.yoy_3m_avg, 0))) AS decline
  FROM generate_series(0, 17) AS gg(g)
) x ON true
LEFT JOIN LATERAL (
  SELECT CASE
    WHEN i.is_discontinued THEN '⚫ 已停產'
    -- 需至少 6 個月歷史才能斷言「連 6 月無銷」(否則是沒上傳資料,非真滯銷)
    WHEN x.hist_keys >= 6 AND x.mws >= 6 AND COALESCE(i.current_stock_qty, 0) > 0
      THEN '☠️ 真滯銷'
    WHEN x.std_ratio > 24 THEN '💸 嚴重過度備貨'
    WHEN x.std_ratio > 12 THEN '⚠️ 過度備貨'
    WHEN x.decline > 0.5  THEN '📉 市場萎縮'
    WHEN x.decline > 0.3  THEN '↘️ 需求下滑'
    ELSE 'normal'
  END AS lvl
) sl ON true
LEFT JOIN LATERAL (
  SELECT
    CASE sl.lvl
      WHEN '☠️ 真滯銷'       THEN 0
      WHEN '💸 嚴重過度備貨' THEN 0
      WHEN '⚠️ 過度備貨'     THEN 0
      WHEN '📉 市場萎縮'
        THEN ROUND(GREATEST(sm.frp - COALESCE(i.current_stock_qty, 0), 0) * 0.5, 0)
      ELSE GREATEST(sm.frp - COALESCE(i.current_stock_qty, 0), 0)
    END AS soq,
    CASE sl.lvl
      WHEN '☠️ 真滯銷'       THEN '暫停訂購,考慮清倉'
      WHEN '💸 嚴重過度備貨' THEN '取消待進貨單'
      WHEN '⚠️ 過度備貨'     THEN '減量訂購'
      WHEN '📉 市場萎縮'     THEN '減量訂購(砍半)'
      WHEN '↘️ 需求下滑'     THEN '留意需求下滑'
      ELSE NULL
    END AS action
) fin ON true;

GRANT SELECT ON public.v_inventory_intelligence TO authenticated;

-- ============================================================
-- 驗證(Acceptance)
-- ============================================================
-- SELECT product_code, current_stock_qty, in_transit_qty, monthly_avg_sales,
--   months_without_sales, supply_to_demand_ratio, yoy_decline_rate,
--   stock_alert_level, stockless_alert_level, suggested_order_qty,
--   suggestion_action
-- FROM v_inventory_intelligence
-- WHERE product_code IN ('PSG500','PF3003','7BA30','8001215');
-- PSG500 在途645/月銷~15 → std_ratio>24 → 💸 嚴重過度備貨,soq=0,取消待進貨單
-- PF3003 在途575/月銷~9  → std_ratio>12 → ⚠️ 過度備貨,soq=0
-- 7BA30  現有0/月銷~45   → 仍 🔴 嚴重缺貨;mws/std 不誤標滯銷
-- 8001215 現有0          → 缺貨;真滯銷需 current_stock>0 故不誤標
