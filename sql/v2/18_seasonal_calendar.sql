-- ============================================================
-- 18_seasonal_calendar.sql — Sprint 2.5 補強(季節月曆)
-- ============================================================
-- 醫療器材有季節性,單看「近3月 vs 前3月」會把春節淡季/暑假旺季
-- 誤判。改用同期(YoY)比較 + Lynn 手動定義的月份係數。
-- 此表為「人類業務知識」來源,Lynn 可在 admin-seasonal-calendar 改。
-- idempotent:seed 用 ON CONFLICT DO NOTHING(不覆蓋 Lynn 已調的值)。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_seasonal_calendar (
  month_num          integer PRIMARY KEY CHECK (month_num BETWEEN 1 AND 12),
  season             text CHECK (season IN ('peak', 'normal', 'low')),
  season_label       text,
  reorder_multiplier numeric DEFAULT 1.0,   -- 旺季 >1 / 淡季 <1
  notes              text,
  updated_at         timestamptz DEFAULT now(),
  updated_by         uuid REFERENCES public.profiles(id)
);

INSERT INTO public.medsec_seasonal_calendar
  (month_num, season, season_label, reorder_multiplier, notes) VALUES
  (1,  'peak',   'Q1 預算季',  1.3, '醫師 Q1 拼預算開刀'),
  (2,  'low',    '春節停診',   0.7, '農曆春節前後手術量驟減'),
  (3,  'peak',   'Q1 末衝刺',  1.2, '預算季結尾'),
  (4,  'normal', 'Q1 後喘息',  1.0, '預算季結束的恢復期'),
  (5,  'normal', '一般月',     1.0, ''),
  (6,  'peak',   '暑假手術潮', 1.4, '學生族群開刀高峰'),
  (7,  'peak',   '暑假手術潮', 1.4, '同上'),
  (8,  'low',    '暑假末',     0.8, '開學潮前需求縮減'),
  (9,  'low',    '開學潮',     0.8, '醫師休假 + 學生回學校'),
  (10, 'normal', '一般月',     1.0, ''),
  (11, 'peak',   '年終預備',   1.3, 'Q4 結案前蓄勢'),
  (12, 'peak',   '年終結案',   1.5, '用完剩餘預算高峰')
ON CONFLICT (month_num) DO NOTHING;

-- ---------- RLS ----------
ALTER TABLE public.medsec_seasonal_calendar ENABLE ROW LEVEL SECURITY;

-- 讀:登入即可(view / cindie 頁 / banner 都要讀,屬參考資料)
DROP POLICY IF EXISTS seasonal_read ON public.medsec_seasonal_calendar;
CREATE POLICY seasonal_read ON public.medsec_seasonal_calendar
  FOR SELECT TO authenticated USING (true);

-- 寫:只有 Lynn(auth_can_maintain 對 manager 一律 true,purchasing 不在白名單)
DROP POLICY IF EXISTS seasonal_write ON public.medsec_seasonal_calendar;
CREATE POLICY seasonal_write ON public.medsec_seasonal_calendar
  FOR ALL TO authenticated
  USING (public.auth_can_maintain('medsec_seasonal_calendar'))
  WITH CHECK (public.auth_can_maintain('medsec_seasonal_calendar'));

COMMENT ON TABLE public.medsec_seasonal_calendar IS
  'Lynn 手動定義 12 月份 peak/normal/low + reorder_multiplier,驅動季節調整';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT month_num, season, season_label, reorder_multiplier
--   FROM medsec_seasonal_calendar ORDER BY month_num;   -- 12 列
-- SELECT public.auth_can_maintain('medsec_seasonal_calendar'); -- Lynn=t
