-- ============================================================
-- sql/v3/12_similar_products.sql — Sprint 3B §6 同系列比對引擎(地基)
-- ============================================================
-- 用途:某品項本院沒報價過 → 找同系列當參考(Card B/C 用)。
-- 評分制(spec §6,已驗證):
--   - 品名關鍵字重疊 × 2(從 product_name 抽大寫英文詞 ≥3字,
--     排除 VALVE/SML/REG 等通用詞)
--   - 品號前綴相同(前 5 字)+3
--   - score ≥ 2 視為同系列,取 top 6
--
-- 驗證範例:
--   - 92355 (STRATA SML) → 92365 / 92866(STRATA 系列)
--   - MR8-AS09 → MR8-AS07 / MR8-AVS 系列
--
-- READ-ONLY 函式;SECURITY DEFINER + 開頭 perm check(只給 pricing 編輯權者
-- 用,避免暴露品名比對能力出去)。idempotent;NOTIFY pgrst reload。
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_similar_products(p_product_code text)
RETURNS TABLE(
  product_code text,
  product_name text,
  score        int
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_target_name   text;
  v_target_prefix text;
  v_words         text[];
  -- 通用詞排除清單(spec §6 例舉 + 醫材常見規格詞)
  v_excluded text[] := ARRAY[
    'VALVE','SML','REG','MED','LRG','SET','KIT',
    'MM','CM','ML','PCS','PCK','BOX','EA','EACH','ASSY'
  ];
BEGIN
  IF NOT COALESCE(public.auth_can_edit_pricing(), FALSE) THEN RETURN; END IF;

  SELECT name, substring(id, 1, 5)
    INTO v_target_name, v_target_prefix
    FROM public.medsec_products
    WHERE id = p_product_code;
  IF v_target_name IS NULL THEN RETURN; END IF;

  -- 抽取大寫英文詞 ≥3 字、排除通用詞,得 v_words
  SELECT COALESCE(array_agg(DISTINCT w), '{}'::text[])
    INTO v_words
    FROM (
      SELECT (regexp_matches(v_target_name, '[A-Z]{3,}', 'g'))[1] AS w
    ) sub
    WHERE w <> ALL (v_excluded);

  RETURN QUERY
    SELECT s.code::text, s.name::text, s.total_score::int
    FROM (
      SELECT
        p.id   AS code,
        p.name AS name,
        ( (SELECT count(*)::int
             FROM unnest(v_words) AS uw
             WHERE p.name ~ ('\m' || uw || '\M')) * 2
          + CASE WHEN substring(p.id, 1, 5) = v_target_prefix THEN 3 ELSE 0 END
        ) AS total_score
      FROM public.medsec_products p
      WHERE p.id <> p_product_code
        AND p.name IS NOT NULL
    ) s
    WHERE s.total_score >= 2
    ORDER BY s.total_score DESC, s.code ASC
    LIMIT 6;
END $$;

GRANT EXECUTE ON FUNCTION
  public.fn_similar_products(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證(spec §6)
-- ============================================================
-- SELECT * FROM fn_similar_products('92355');     -- 期望含 92365 / 92866(STRATA 系列)
-- SELECT * FROM fn_similar_products('MR8-AS09');  -- 期望含 MR8-AS07 / MR8-AVS 系列
-- 業祕身分:SELECT * FROM fn_similar_products('92355');  -- 應回 0 列(perm check)
