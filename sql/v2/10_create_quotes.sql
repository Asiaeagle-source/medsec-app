-- ============================================================
-- 10_create_quotes.sql — 模組 3 報價系統 (Sprint 2)
-- ============================================================
-- Lynn 2026-05-15 拍板:
--   - medsec_quotes 是 medsec_cases 子表 (case_id NOT NULL)
--   - quote_type 7 種 enum (藍圖第八部分)
--   - AI 建議價 V1 純 SQL aggregate (藍圖 §Q4,不調 LLM,V2.1 才加 Claude)
--
-- 資料源 (AI 建議價):
--   medsec_discount_rules    406+3 筆 (折讓 ETL 剛灌) — 同醫院同產品折讓慣例
--   medsec_sales_history     0 筆 (HANDOVER §11.3,有資料才有歷史均價,graceful)
--   product_base_prices      0 筆 (HANDOVER §11.2,manager-only 底價)
-- ============================================================

-- ---------- medsec_quotes ----------
CREATE TABLE IF NOT EXISTS public.medsec_quotes (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id             uuid NOT NULL REFERENCES public.medsec_cases(id) ON DELETE CASCADE,
  hospital_id         text REFERENCES public.medsec_hospitals(id),

  quote_type          text NOT NULL
    CHECK (quote_type IN (
      'shipment',      -- 出貨用
      'registration',  -- 建碼
      'new_product',   -- 新品
      'replacement',   -- 汰舊換新
      'repair',        -- 維修
      'consumable',    -- 耗材
      'budget'         -- 設備預算
    )),

  status              text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'pending_decision', 'decided', 'sent', 'closed')),

  subtotal            numeric,            -- 各 item list_price * qty 加總
  discount_total      numeric,            -- 折讓加總
  final_total         numeric,            -- 業祕送出的總額

  ai_suggested_total  numeric,            -- compute_quote_suggestion 寫入
  ai_confidence       numeric,            -- 0-1,有幾成 item 對到折讓規則
  ai_reasoning        text,               -- 字串模板 (V1) / Claude (V2.1)

  manager_decision    text,               -- 'adopt' / 'adjust' / 'reject'
  manager_final_total numeric,            -- Lynn 拍板總額
  manager_decided_at  timestamptz,
  manager_decided_by  uuid REFERENCES public.profiles(id),

  created_by          uuid REFERENCES public.profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quotes_case      ON public.medsec_quotes(case_id);
CREATE INDEX IF NOT EXISTS idx_quotes_hospital  ON public.medsec_quotes(hospital_id);
CREATE INDEX IF NOT EXISTS idx_quotes_status    ON public.medsec_quotes(status)
  WHERE status = 'pending_decision';

-- ---------- medsec_quote_items ----------
CREATE TABLE IF NOT EXISTS public.medsec_quote_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id            uuid NOT NULL REFERENCES public.medsec_quotes(id) ON DELETE CASCADE,

  product_code        text,               -- 我方品號 (→ medsec_products.id)
  product_name        text,               -- snapshot
  hospital_item_code  text,               -- 院內碼 snapshot (from medsec_hospital_product_codes)

  quantity            int NOT NULL DEFAULT 1,
  list_price          numeric,            -- 我方標價
  ai_suggested_price  numeric,            -- compute_quote_suggestion 寫入 (單價)
  final_price         numeric,            -- 業祕 / Lynn 拍板單價
  discount_applied    numeric,            -- 套到的折讓額
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quote_items_quote ON public.medsec_quote_items(quote_id);

-- ---------- updated_at trigger ----------
CREATE OR REPLACE FUNCTION public.touch_quotes_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS trg_quotes_updated ON public.medsec_quotes;
CREATE TRIGGER trg_quotes_updated
  BEFORE UPDATE ON public.medsec_quotes
  FOR EACH ROW EXECUTE FUNCTION public.touch_quotes_updated_at();

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.medsec_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medsec_quote_items ENABLE ROW LEVEL SECURITY;

-- quotes: manager / secretary / bidding_team 全看全寫 (跟 medsec_cases 放寬一致)
DROP POLICY IF EXISTS quotes_rw ON public.medsec_quotes;
CREATE POLICY quotes_rw ON public.medsec_quotes
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'));

-- quote_items: 跟著 quote 走 (同三角色)
DROP POLICY IF EXISTS quote_items_rw ON public.medsec_quote_items;
CREATE POLICY quote_items_rw ON public.medsec_quote_items
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team'));

-- ============================================================
-- AI 建議價 (V1 純 SQL aggregate)
-- ============================================================
-- 對 quote 每個 item:
--   1. 找 medsec_discount_rules 同 hospital + product → 算建議單價
--      (fixed_amount: list_price - fixed_amount;
--       donation:     list_price - donation_amount;
--       percentage:   list_price * (1 - percentage_rate/100))
--   2. 若無折讓規則 → 找 medsec_sales_history 同 hospital + product 近 5 筆均價
--      (V1 sales_history 0 筆,通常 fallback NULL)
--   3. 都沒有 → ai_suggested_price = list_price (不打折,confidence 低)
-- ai_confidence = 有對到折讓/歷史的 item 比例
-- SECURITY DEFINER 跨 RLS 讀 discount_rules / sales_history
CREATE OR REPLACE FUNCTION public.compute_quote_suggestion(p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_hospital_id text;
  v_total numeric := 0;
  v_matched int := 0;
  v_count int := 0;
  r record;
  v_sugg numeric;
  v_conf numeric;
BEGIN
  SELECT hospital_id INTO v_hospital_id FROM medsec_quotes WHERE id = p_quote_id;

  FOR r IN SELECT * FROM medsec_quote_items WHERE quote_id = p_quote_id LOOP
    v_count := v_count + 1;
    v_sugg := NULL;

    -- 1. 折讓規則
    SELECT CASE
             WHEN calc_method = 'fixed_amount' AND fixed_amount IS NOT NULL
               THEN coalesce(r.list_price, 0) - fixed_amount
             WHEN calc_method = 'donation' AND donation_amount IS NOT NULL
               THEN coalesce(r.list_price, 0) - donation_amount
             WHEN calc_method = 'percentage' AND percentage_rate IS NOT NULL
               THEN coalesce(r.list_price, 0) * (1 - percentage_rate / 100.0)
             ELSE NULL
           END
      INTO v_sugg
    FROM medsec_discount_rules
    WHERE hospital_id = v_hospital_id
      AND (product_code = r.product_code OR product_code IS NULL)
      AND coalesce(is_active, true) = true
    ORDER BY (product_code = r.product_code) DESC NULLS LAST
    LIMIT 1;

    IF v_sugg IS NOT NULL THEN
      v_matched := v_matched + 1;
    ELSE
      -- 2. 歷史成交均價 (V1 sales_history 多半 0 筆)
      BEGIN
        SELECT avg(final_price) INTO v_sugg
        FROM medsec_sales_history
        WHERE hospital_id = v_hospital_id AND product_code = r.product_code;
        IF v_sugg IS NOT NULL THEN v_matched := v_matched + 1; END IF;
      EXCEPTION WHEN undefined_column OR undefined_table THEN
        v_sugg := NULL;
      END;
    END IF;

    -- 3. fallback = list_price
    IF v_sugg IS NULL THEN v_sugg := r.list_price; END IF;

    UPDATE medsec_quote_items
      SET ai_suggested_price = round(v_sugg, 2)
      WHERE id = r.id;

    v_total := v_total + coalesce(v_sugg, 0) * coalesce(r.quantity, 1);
  END LOOP;

  v_conf := CASE WHEN v_count = 0 THEN 0 ELSE round(v_matched::numeric / v_count, 2) END;

  UPDATE medsec_quotes
    SET ai_suggested_total = round(v_total, 2),
        ai_confidence = v_conf,
        ai_reasoning = format(
          '依折讓規則 / 歷史成交算出 %s 個品項建議價 (共 %s 項,信心 %s)。'
          '無資料的品項以標價代入,Lynn 可調整。',
          v_matched, v_count, v_conf)
    WHERE id = p_quote_id;

  RETURN jsonb_build_object(
    'quote_id', p_quote_id, 'items', v_count, 'matched', v_matched,
    'suggested_total', round(v_total, 2), 'confidence', v_conf);
END $$;

GRANT EXECUTE ON FUNCTION public.compute_quote_suggestion(uuid) TO authenticated;

COMMENT ON TABLE public.medsec_quotes IS
  '模組 3 報價 (Sprint 2)。medsec_cases 子表。7 種 quote_type。AI 建議價 V1 純 SQL。';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT count(*) FROM medsec_quotes;        -- 0 (還沒建報價)
-- SELECT proname FROM pg_proc WHERE proname='compute_quote_suggestion';  -- 1 列
-- SELECT tablename, count(*) FROM pg_policies
--   WHERE tablename IN ('medsec_quotes','medsec_quote_items') GROUP BY tablename;
--   -- 各 1
