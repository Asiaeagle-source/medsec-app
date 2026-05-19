-- ============================================================
-- 23_inventory_consolidated.sql — 取代並合併 19/20/21/22
-- ============================================================
-- 修正依賴順序錯誤:
--   舊 20 想 DROP COLUMN effective_supply,但 view 還依賴它;
--   舊 19 用 CREATE OR REPLACE VIEW,若已存在較多欄的新版會 42P16。
--
-- 本檔一次到位、可重複執行(idempotent):
--   1. DROP VIEW ... CASCADE(先拆掉相依的 view)
--   2. ALTER 全部 columns(effective_supply 改只算現有等)
--   3. 重建 prune trigger
--   4. CREATE 最新 v_inventory_intelligence(季節+穩定度+滯銷)
--   5. CREATE OR REPLACE 報價送審 advisory(不含滯銷,業祕不可見)
--
-- ⚠️ 19/20/21/22 已改為空白佔位(superseded);只需執行到本檔。
-- 前置:14/15(基礎欄)、16(monthly_sales_history)、18(季節月曆)。
-- 不刪表、不刪資料;effective_supply 為 generated 欄,DROP/ADD 不掉資料。
-- ============================================================

-- ---------- 1. 拆掉相依 view ----------
DROP VIEW IF EXISTS public.v_inventory_intelligence CASCADE;

-- ---------- 2. 欄位調整 ----------
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN IF NOT EXISTS monthly_sales_history jsonb DEFAULT '{}'::jsonb;

-- 舊版非季節 generated 警示欄(15 建立)→ 由 view 取代
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS stock_alert_level;

-- 有效供應 = 只算實際在倉(current_stock_qty);逾期/待進貨不計入
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS effective_supply;
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN effective_supply numeric
  GENERATED ALWAYS AS (COALESCE(current_stock_qty, 0)) STORED;

COMMENT ON COLUMN public.medsec_product_inventory.effective_supply IS
  '有效供應 = 只算實際在倉(current_stock_qty);逾期/待進貨不計入';
COMMENT ON COLUMN public.medsec_product_inventory.monthly_sales_history IS
  'rolling 18 個月 {"YYYY-MM":qty};上傳合併、自動淘汰更舊';

-- ---------- 3. 月銷歷史合併 + 淘汰(rolling 18 個月)----------
CREATE OR REPLACE FUNCTION public.prune_old_sales_history()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  cutoff_month text := to_char(now() - interval '18 months', 'YYYY-MM');
  merged jsonb;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    merged := COALESCE(OLD.monthly_sales_history, '{}'::jsonb)
              || COALESCE(NEW.monthly_sales_history, '{}'::jsonb);
  ELSE
    merged := COALESCE(NEW.monthly_sales_history, '{}'::jsonb);
  END IF;
  SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb) INTO merged
  FROM jsonb_each(merged) AS e(k, v)
  WHERE k >= cutoff_month;
  NEW.monthly_sales_history := merged;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_prune_sales_history ON public.medsec_product_inventory;
CREATE TRIGGER trg_prune_sales_history
  BEFORE INSERT OR UPDATE ON public.medsec_product_inventory
  FOR EACH ROW EXECUTE FUNCTION public.prune_old_sales_history();

-- ---------- 4. 最新智慧 view(季節 + 穩定度 + 滯銷)----------
CREATE VIEW public.v_inventory_intelligence AS
SELECT
  i.product_code, i.product_name, i.product_category,
  i.effective_supply, i.is_discontinued, i.replacement_product_code,
  i.current_stock_qty, i.monthly_sales_history,
  COALESCE(i.monthly_avg_sales, 0)     AS monthly_avg_sales,
  COALESCE(i.overdue_inbound_qty, 0)   AS overdue_qty,
  COALESCE(i.pending_inbound_qty, 0)   AS pending_inbound_qty,
  COALESCE(i.pending_purchase_qty, 0)  AS pending_purchase_qty,
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
LEFT JOIN LATERAL (
  SELECT
    COALESCE(
      MIN(gg.g) FILTER (
        WHERE (COALESCE(i.monthly_sales_history, '{}'::jsonb)
                 ->> to_char(now() - make_interval(months => gg.g), 'YYYY-MM'))::numeric > 0
      ), 18) AS mws,
    (SELECT COALESCE(sum((e.value #>> '{}')::numeric), 0)
       FROM jsonb_each(COALESCE(i.monthly_sales_history, '{}'::jsonb)) e
       WHERE e.key >= to_char(now() - interval '6 months', 'YYYY-MM')) AS r6_total,
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

-- ---------- 5. 報價送審 → 自動警示(不含滯銷;業祕不可見)----------
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
-- 驗證
-- ============================================================
-- select stability_tier, count(*) from v_inventory_intelligence group by 1;
-- select stockless_alert_level, count(*) from v_inventory_intelligence group by 1;
-- select product_code, current_stock_qty, in_transit_qty, monthly_avg_sales,
--   months_without_sales, supply_to_demand_ratio, stability_tier,
--   stock_alert_level, stockless_alert_level, suggested_order_qty, suggestion_action
-- from v_inventory_intelligence where product_code in ('PSG500','PF3003','7BA30','8001215');
