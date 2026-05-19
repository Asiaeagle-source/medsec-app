-- ============================================================
-- 24_seasonal_reset_neutral.sql — 季節月曆重置為中性(Lynn 拍板)
-- ============================================================
-- Lynn:沒有真實旺淡季知識,不該拍腦袋設係數(會誤導 Cindie 訂購點)。
-- 階段 1:全 12 個月 normal × 1.0(等同無季節調整)。
-- 階段 2-3:累積 12 個月真實月銷後再用資料分析(Sprint 4+)。
--
-- 不 DROP 表(預留未來用)。idempotent:補齊缺月並把全部重置為中性。
-- v_inventory_intelligence 仍乘 reorder_multiplier,但全 1.0 → 實質無調整。
-- ============================================================

INSERT INTO public.medsec_seasonal_calendar
  (month_num, season, season_label, reorder_multiplier, notes, updated_at)
SELECT g, 'normal', '一般月', 1.0, '', now()
FROM generate_series(1, 12) AS g
ON CONFLICT (month_num) DO UPDATE SET
  season             = 'normal',
  season_label       = '一般月',
  reorder_multiplier = 1.0,
  notes              = '',
  updated_at         = now();

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT month_num, season, season_label, reorder_multiplier
--   FROM medsec_seasonal_calendar ORDER BY month_num;
--   → 12 列,全部 normal / 一般月 / 1.0
