-- ============================================================
-- 05_decision_package_function.sql — Lynn V3.3 V1 純 SQL aggregate
-- ============================================================
-- 對應 §9 Q4：「V1 不調 Claude API，全靠 aggregate」
--
-- 算單一案件的 ai_suggested_price + ai_confidence + reasoning，
-- 寫回 medsec_cases 主表 + medsec_case_items 各品項。
--
-- ⚠️ V1 stub：靠 medsec_sales_history（目前 0 筆）。
--    seed 完歷史成交價後才能跑出實際建議價。
--    V2 再加 Claude API 寫人話 reasoning。
-- ============================================================

CREATE OR REPLACE FUNCTION public.compute_case_decision_package(p_case_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_case          public.medsec_cases;
  v_items_data    jsonb := '[]'::jsonb;
  v_total         numeric := 0;
  v_min_samples   int     := 999999;
  v_confidence    numeric;
  v_reasoning     text;
  v_item          record;
  v_item_avg      numeric;
  v_item_median   numeric;
  v_item_min      numeric;
  v_item_max      numeric;
  v_item_n        int;
  v_op_rules      jsonb;
  v_discount_n    int;
BEGIN
  -- 1. 取案件主檔
  SELECT * INTO v_case FROM public.medsec_cases WHERE id = p_case_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'case not found', 'case_id', p_case_id);
  END IF;

  -- 2. 對每個 case_item 算近 5 筆同醫院同產品的 avg / median / min / max
  FOR v_item IN
    SELECT id, product_code, quantity
    FROM public.medsec_case_items
    WHERE case_id = p_case_id
  LOOP
    SELECT
      avg(unit_price),
      percentile_cont(0.5) WITHIN GROUP (ORDER BY unit_price),
      min(unit_price),
      max(unit_price),
      count(*)
    INTO v_item_avg, v_item_median, v_item_min, v_item_max, v_item_n
    FROM (
      SELECT unit_price
      FROM public.medsec_sales_history
      WHERE hospital_id  = v_case.hospital_id
        AND product_code = v_item.product_code
      ORDER BY sale_date DESC
      LIMIT 5
    ) recent;

    -- 寫回 medsec_case_items.ai_suggested_price = median × qty（fallback avg）
    UPDATE public.medsec_case_items
       SET ai_suggested_price = COALESCE(v_item_median, v_item_avg)
     WHERE id = v_item.id;

    IF v_item_median IS NOT NULL THEN
      v_total := v_total + v_item_median * v_item.quantity;
    END IF;
    v_min_samples := LEAST(v_min_samples, COALESCE(v_item_n, 0));

    v_items_data := v_items_data || jsonb_build_object(
      'item_id',      v_item.id,
      'product_code', v_item.product_code,
      'quantity',     v_item.quantity,
      'avg',          v_item_avg,
      'median',       v_item_median,
      'min',          v_item_min,
      'max',          v_item_max,
      'sample_size',  v_item_n
    );
  END LOOP;

  -- 3. 信心度：最少樣本數 / 5（V1 簡化）
  IF v_min_samples = 999999 THEN v_min_samples := 0; END IF;
  v_confidence := LEAST(1.0, v_min_samples::numeric / 5.0);

  -- 4. 抓醫院操作規則 + 折扣規則數（給 reasoning 用）
  SELECT to_jsonb(r) INTO v_op_rules
    FROM public.medsec_hospital_operation_rules r
   WHERE r.hospital_id = v_case.hospital_id;

  SELECT count(*) INTO v_discount_n
    FROM public.medsec_discount_rules
   WHERE (hospital_id = v_case.hospital_id OR parent_code IS NOT NULL)
     AND coalesce(is_active, true) = true;

  -- 5. 寫回 medsec_cases
  UPDATE public.medsec_cases
     SET ai_suggested_price = v_total,
         ai_confidence      = v_confidence,
         updated_at         = now()
   WHERE id = p_case_id;

  -- 6. 組 reasoning（V1 字串模板）
  v_reasoning := format(
    '建議報價合計 %s 元（最少樣本數 %s 筆），信心度 %s。',
    coalesce(v_total::text, '無'), v_min_samples, round(v_confidence, 2)
  );
  IF v_op_rules IS NOT NULL THEN
    v_reasoning := v_reasoning || ' 已套用本醫院操作規則。';
  END IF;
  IF v_discount_n > 0 THEN
    v_reasoning := v_reasoning || format(' 可用折扣規則 %s 條。', v_discount_n);
  END IF;
  IF v_min_samples = 0 THEN
    v_reasoning := v_reasoning || ' ⚠️ 無歷史成交可參考，建議價可能不準。';
  END IF;

  RETURN jsonb_build_object(
    'case_id',            p_case_id,
    'case_no',            v_case.case_no,
    'hospital_id',        v_case.hospital_id,
    'ai_suggested_price', v_total,
    'ai_confidence',      v_confidence,
    'reasoning',          v_reasoning,
    'items',              v_items_data,
    'op_rules',           v_op_rules,
    'discount_rules_count', v_discount_n,
    'computed_at',        now()
  );
END;
$$;

COMMENT ON FUNCTION public.compute_case_decision_package(uuid)
  IS 'V3.3 V1 決策包 — 純 SQL aggregate，無 LLM。Lynn 拍板 §9 Q4 V1 範圍。寫回 case + items；reasoning 用字串模板。V2 再加 Claude API。';

GRANT EXECUTE ON FUNCTION public.compute_case_decision_package(uuid) TO authenticated;

-- ============================================================
-- 驗證
-- ============================================================
-- (1) 函數存在
-- select proname from pg_proc where proname = 'compute_case_decision_package';

-- (2) 試跑（需要先有一個案件 + items + 對應 sales_history）
-- select public.compute_case_decision_package('xxx-uuid-xxx');
-- → 回 jsonb 含 ai_suggested_price / ai_confidence / reasoning / items

-- (3) 看寫回主表的效果
-- select id, case_no, ai_suggested_price, ai_confidence
-- from public.medsec_cases where id = 'xxx-uuid-xxx';

-- (4) 看 items 的效果
-- select id, product_code, quantity, ai_suggested_price
-- from public.medsec_case_items where case_id = 'xxx-uuid-xxx';
