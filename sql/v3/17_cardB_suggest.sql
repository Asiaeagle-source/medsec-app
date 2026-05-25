-- ============================================================
-- sql/v3/17_cardB_suggest.sql — Card B §1 報價建議 + Lynn-only §1 守價/策略
-- ============================================================
-- 兩個 RPC:
--   fn_cardB_suggest(...)         — 業祕可調(登入即可),回建議價/折數/上次報價/上次成交
--   fn_cardB_strategy_floors(...) — Lynn-only,回守價黃線/紅線/策略提示
--
-- 公式(per §6.1 答案 A):
--   suggested = 本院上次報價 × min(該性質折數中位, 1.0)
--
-- 折數來源優先序:
--   有 notes 標籤(RM/NE/EQ/IN):
--     1) 本院 notes 同性質中位 → 2) 他院 notes 同性質中位 → 3) 同體系 fuzzy 中位
--   無 notes 標籤(CO/CC/BU):
--     1) 本院 fuzzy 中位 → 2) 他院 fuzzy 中位 → 3) 同體系 fuzzy 中位
--   (per E1 答案:CO/CC/BU 退 fuzzy,不退「所有 notes 中位混算」以免混性質)
--
-- tx_kind → notes tx_type label(per E1):
--   RM→维修  NE→汰旧  EQ→新购  IN→新购  CO/CC/BU→null(走 fuzzy)
--
-- 雄鷹/君華合併(per §6.4 答案 A):查詢不依 brand 過濾,前端可加 chip 分。
--
-- 為何不直接走 v_carda_pairs/v_carda_analysis:那兩個 view 內含
-- auth_can_edit_pricing() 守門,業祕 JWT 過不去會回 0 列。本函式
-- 用 SECURITY DEFINER 並 INLINE fuzzy 邏輯(同 v_carda_pairs 規則),
-- 避免「業祕能呼叫但拿不到 fuzzy fallback」的破洞。
-- ============================================================

-- ---------- 1) 業祕可用:報價建議 ----------
CREATE OR REPLACE FUNCTION public.fn_cardB_suggest(
  p_hospital_id  text,
  p_product_code text,
  p_tx_kind      text         -- 'RM','EQ','IN','CO','NE','CC','BU' or NULL
)
RETURNS TABLE(
  suggested_price   numeric,
  discount_used     numeric,
  discount_source   text,     -- notes_self/notes_other/system_median/fuzzy_self/fuzzy_other
  last_quote_price  numeric,
  last_quote_date   date,
  last_sale_price   numeric,
  last_sale_date    date
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_notes_label text;
  v_disc        numeric;
  v_src         text;
  v_lq_price    numeric;
  v_lq_date     date;
  v_ls_price    numeric;
  v_ls_date     date;
  v_target_sys  text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;

  -- ===== tx_kind → notes label =====
  v_notes_label := CASE upper(COALESCE(p_tx_kind, ''))
    WHEN 'RM' THEN '维修'
    WHEN 'NE' THEN '汰旧'
    WHEN 'EQ' THEN '新购'
    WHEN 'IN' THEN '新购'
    ELSE NULL                              -- CO/CC/BU → 退 fuzzy
  END;

  -- ===== 本院上次報價(排除已拋轉複製改價單)=====
  SELECT q.quoted_unit_price, q.quoted_date
    INTO v_lq_price, v_lq_date
  FROM public.medsec_quote_history q
  WHERE btrim(q.hospital_id) = p_hospital_id
    AND q.product_code       = p_product_code
    AND q.quoted_unit_price  > 0
    AND q.erp_quote_no IS NULL
  ORDER BY q.quoted_date DESC
  LIMIT 1;

  -- ===== 本院上次成交(價位護欄 BETWEEN lq*0.3 AND lq*1.2,與 v_carda_card 一致)=====
  IF v_lq_price IS NOT NULL THEN
    SELECT s.unit_price, s.sales_date
      INTO v_ls_price, v_ls_date
    FROM public.medsec_sales s
    WHERE btrim(s.customer_code) = p_hospital_id
      AND s.product_code         = p_product_code
      AND s.unit_price           > 0
      AND s.unit_price BETWEEN v_lq_price * 0.3 AND v_lq_price * 1.2
    ORDER BY s.sales_date DESC
    LIMIT 1;
  END IF;

  -- ===== 折數中位:依 tx_kind 走 notes 或 fuzzy 路線 =====
  IF v_notes_label IS NOT NULL THEN
    -- (1) 本院 notes 同性質中位
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY nd.discount)
      INTO v_disc
    FROM public.medsec_notes_discount nd
    WHERE nd.hospital_id  = p_hospital_id
      AND nd.product_code = p_product_code
      AND nd.tx_type LIKE '%' || v_notes_label || '%';
    IF v_disc IS NOT NULL THEN v_src := 'notes_self'; END IF;

    -- (2) 他院 notes 同性質中位
    IF v_disc IS NULL THEN
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY nd.discount)
        INTO v_disc
      FROM public.medsec_notes_discount nd
      WHERE nd.product_code = p_product_code
        AND nd.tx_type LIKE '%' || v_notes_label || '%';
      IF v_disc IS NOT NULL THEN v_src := 'notes_other'; END IF;
    END IF;
  ELSE
    -- CO/CC/BU 路線:本院 fuzzy(inline,避開 view 守門)
    WITH pairs AS (
      SELECT (s.unit_price / q.quoted_unit_price)::numeric AS discount
      FROM public.medsec_quote_history q
      CROSS JOIN LATERAL (
        SELECT unit_price, sales_date FROM public.medsec_sales
        WHERE btrim(customer_code) = btrim(q.hospital_id)
          AND product_code         = q.product_code
          AND unit_price > 0
          AND sales_date >= q.quoted_date
        ORDER BY sales_date ASC, unit_price ASC
        LIMIT 1
      ) s
      WHERE btrim(q.hospital_id) = p_hospital_id
        AND q.product_code       = p_product_code
        AND q.quoted_unit_price  > 0
        AND q.erp_quote_no IS NULL
        AND (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2
    )
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY discount) INTO v_disc FROM pairs;
    IF v_disc IS NOT NULL THEN v_src := 'fuzzy_self'; END IF;

    IF v_disc IS NULL THEN
      -- 他院 fuzzy(任意醫院 × 同品號)
      WITH pairs AS (
        SELECT (s.unit_price / q.quoted_unit_price)::numeric AS discount
        FROM public.medsec_quote_history q
        CROSS JOIN LATERAL (
          SELECT unit_price, sales_date FROM public.medsec_sales
          WHERE btrim(customer_code) = btrim(q.hospital_id)
            AND product_code         = q.product_code
            AND unit_price > 0
            AND sales_date >= q.quoted_date
          ORDER BY sales_date ASC, unit_price ASC
          LIMIT 1
        ) s
        WHERE q.product_code      = p_product_code
          AND q.quoted_unit_price > 0
          AND q.erp_quote_no IS NULL
          AND (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2
      )
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY discount) INTO v_disc FROM pairs;
      IF v_disc IS NOT NULL THEN v_src := 'fuzzy_other'; END IF;
    END IF;
  END IF;

  -- (3) 最終退路:同體系 fuzzy 中位
  IF v_disc IS NULL THEN
    SELECT h.system_prefix INTO v_target_sys
    FROM public.medsec_hospitals h WHERE h.id = p_hospital_id;
    IF v_target_sys IS NOT NULL THEN
      WITH sys_hosp AS (
        SELECT id FROM public.medsec_hospitals WHERE system_prefix = v_target_sys
      ),
      pairs AS (
        SELECT (s.unit_price / q.quoted_unit_price)::numeric AS discount
        FROM public.medsec_quote_history q
        JOIN sys_hosp sh ON sh.id = btrim(q.hospital_id)
        CROSS JOIN LATERAL (
          SELECT unit_price, sales_date FROM public.medsec_sales
          WHERE btrim(customer_code) = btrim(q.hospital_id)
            AND product_code         = q.product_code
            AND unit_price > 0
            AND sales_date >= q.quoted_date
          ORDER BY sales_date ASC, unit_price ASC
          LIMIT 1
        ) s
        WHERE q.product_code      = p_product_code
          AND q.quoted_unit_price > 0
          AND q.erp_quote_no IS NULL
          AND (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2
      )
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY discount) INTO v_disc FROM pairs;
      IF v_disc IS NOT NULL THEN v_src := 'system_median'; END IF;
    END IF;
  END IF;

  -- ===== 建議價計算 =====
  RETURN QUERY
  SELECT
    CASE
      WHEN v_lq_price IS NOT NULL AND v_disc IS NOT NULL
        THEN round(v_lq_price * LEAST(v_disc, 1.0))
      ELSE NULL
    END::numeric                              AS suggested_price,
    v_disc                                    AS discount_used,
    v_src                                     AS discount_source,
    v_lq_price                                AS last_quote_price,
    v_lq_date                                 AS last_quote_date,
    v_ls_price                                AS last_sale_price,
    v_ls_date                                 AS last_sale_date;
END $$;

GRANT EXECUTE ON FUNCTION public.fn_cardB_suggest(text, text, text) TO authenticated;


-- ---------- 2) Lynn-only:守價黃線/紅線/策略提示 ----------
-- 黃線(per §6.2):本院中位折 - 10%(警告:報太低)
-- 紅線(per §6.2):他院最低折(破底,絕對下限)
-- 兩條都是「折數值」(0.3~1.2),前端比對 (user_quote / last_quote_price) 即可
CREATE OR REPLACE FUNCTION public.fn_cardB_strategy_floors(
  p_hospital_id  text,
  p_product_code text,
  p_tx_kind      text
)
RETURNS TABLE(
  yellow_floor numeric,       -- 折數值;低於此(quote/last_quote)→ 黃色警告
  red_floor    numeric,       -- 折數值;低於此 → 紅色破底
  hint         text            -- 策略提示文字(per §1 表)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_self_med numeric;
  v_other_min numeric;
BEGIN
  IF NOT COALESCE(public.auth_can_edit_pricing(), FALSE) THEN RETURN; END IF;

  -- 本院中位折(inline fuzzy,避開 view 守門差異)
  WITH pairs AS (
    SELECT (s.unit_price / q.quoted_unit_price)::numeric AS discount
    FROM public.medsec_quote_history q
    CROSS JOIN LATERAL (
      SELECT unit_price FROM public.medsec_sales
      WHERE btrim(customer_code) = btrim(q.hospital_id)
        AND product_code         = q.product_code
        AND unit_price > 0
        AND sales_date >= q.quoted_date
      ORDER BY sales_date ASC, unit_price ASC
      LIMIT 1
    ) s
    WHERE btrim(q.hospital_id) = p_hospital_id
      AND q.product_code       = p_product_code
      AND q.quoted_unit_price  > 0
      AND q.erp_quote_no IS NULL
      AND (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2
  )
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY discount) INTO v_self_med FROM pairs;

  -- 他院最低折(任意他院 × 同品號 fuzzy min)
  WITH pairs AS (
    SELECT (s.unit_price / q.quoted_unit_price)::numeric AS discount
    FROM public.medsec_quote_history q
    CROSS JOIN LATERAL (
      SELECT unit_price FROM public.medsec_sales
      WHERE btrim(customer_code) = btrim(q.hospital_id)
        AND product_code         = q.product_code
        AND unit_price > 0
        AND sales_date >= q.quoted_date
      ORDER BY sales_date ASC, unit_price ASC
      LIMIT 1
    ) s
    WHERE q.product_code        = p_product_code
      AND btrim(q.hospital_id) <> p_hospital_id
      AND q.quoted_unit_price   > 0
      AND q.erp_quote_no IS NULL
      AND (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2
  )
  SELECT min(discount) INTO v_other_min FROM pairs;

  RETURN QUERY
  SELECT
    CASE WHEN v_self_med IS NOT NULL THEN (v_self_med - 0.10)::numeric END AS yellow_floor,
    v_other_min::numeric                                                   AS red_floor,
    CASE upper(COALESCE(p_tx_kind, ''))
      WHEN 'EQ' THEN '設備類:醫院通常不索取他院發票對價,可放手報高'
      WHEN 'IN' THEN '器械類:醫院通常不索取他院發票對價,可放手報高'
      WHEN 'RM' THEN '維修類:可能被要求他院發票,別差太多'
      WHEN 'CO' THEN '耗材類:常被要求他院發票,別差太多'
      WHEN 'NE' THEN '汰舊換新:常被要求他院發票,別差太多'
      WHEN 'CC' THEN '建碼:常被要求他院發票,別差太多'
      WHEN 'BU' THEN '預算單:價格參考度高,別差太多'
      ELSE NULL
    END                                                                    AS hint;
END $$;

GRANT EXECUTE ON FUNCTION public.fn_cardB_strategy_floors(text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 業祕視角(login):
--   SELECT * FROM fn_cardB_suggest('CKUS', '10BA40', 'RM');
--     -- 應有 suggested_price + discount_source(預期 notes_self/notes_other)
--   SELECT * FROM fn_cardB_strategy_floors('CKUS', '10BA40', 'RM');
--     -- 應回 0 列(auth_can_edit_pricing 擋住,業祕看不到守價)
-- Lynn 視角:
--   兩個都會有資料,strategy_floors 額外回 yellow_floor / red_floor / hint
