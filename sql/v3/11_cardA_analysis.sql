-- ============================================================
-- sql/v3/11_cardA_analysis.sql — Sprint 3B Card A 折數分析(地基)
-- ============================================================
-- 機密後台,Lynn/老闆 only。READ-ONLY:純 view + function,不寫入、
-- 不動來源表。
--
-- 折數邏輯已用 DB 近五年 medsec_sales 重驗(1,984 組 / 中位 90% / 與
-- Excel 一致)。本檔將其固化成 production views。
--
-- spec 草案欄名修正(已對 live schema 確認):
--   - hospitals 欄是 id(非 hospital_id)、name_short / name_full(非 name)
--   - quote_history.quoted_unit_price / quoted_date 確認存在
--   - medsec_sales.customer_code 已於 Tab2 匯入時 trim,但保留 trim() 防禦
--
-- 權限:所有 views 在 v_cardA_pairs 那層加 `auth_can_edit_pricing()` 為
-- AND 條件 → Cindie/業祕查到 0 列(下游 v_cardA_analysis/card 因 join
-- pairs 也自動 0 列)。fn_cardA_other_hospitals 是 SECURITY DEFINER +
-- 函式開頭 explicit perm check。
--
-- idempotent:CREATE OR REPLACE VIEW;結尾 NOTIFY pgrst reload。
-- ============================================================

-- ---------- 1. 折數配對層 ----------
CREATE OR REPLACE VIEW public.v_cardA_pairs AS
WITH q AS (
  SELECT
    btrim(hospital_id)   AS hospital_id,
    product_code,
    quoted_date,
    quoted_unit_price
  FROM public.medsec_quote_history
  WHERE quoted_unit_price > 0
    AND quoted_date IS NOT NULL
    AND COALESCE(public.auth_can_edit_pricing(), FALSE)  -- 沿用 edit_pricing 權當檢視折數分析閘,檢視者=定價編輯者(manager/boss 0001),非筆誤
)
SELECT
  q.hospital_id, q.product_code,
  q.quoted_date, q.quoted_unit_price,
  s.sales_date          AS paired_sales_date,
  s.unit_price          AS paired_unit_price,
  (s.unit_price / q.quoted_unit_price)::numeric AS discount
FROM q
CROSS JOIN LATERAL (
  SELECT sales_date, unit_price
  FROM public.medsec_sales
  WHERE btrim(customer_code) = q.hospital_id
    AND product_code         = q.product_code
    AND unit_price > 0
    AND sales_date >= q.quoted_date
  ORDER BY sales_date ASC, unit_price ASC
  LIMIT 1
) s
WHERE (s.unit_price / q.quoted_unit_price) BETWEEN 0.3 AND 1.2;

-- ---------- 2. 折數彙總層(每「醫院×品項」一列)----------
CREATE OR REPLACE VIEW public.v_cardA_analysis AS
WITH pairs AS (
  SELECT *, round(discount / 0.05) * 0.05 AS bucket
  FROM public.v_cardA_pairs
),
bucket_counts AS (
  SELECT hospital_id, product_code, bucket, count(*) AS n,
         row_number() OVER (PARTITION BY hospital_id, product_code
                            ORDER BY count(*) DESC, bucket DESC) AS rk_common
  FROM pairs
  GROUP BY hospital_id, product_code, bucket
),
agg AS (
  SELECT hospital_id, product_code,
         count(*)                                                AS sample_n,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY discount)   AS median_discount,
         min(discount)                                           AS min_discount,
         max(discount)                                           AS max_discount,
         max(discount) - min(discount)                           AS spread
  FROM pairs
  GROUP BY hospital_id, product_code
)
SELECT
  a.hospital_id, a.product_code, a.sample_n,
  a.median_discount, a.min_discount, a.max_discount, a.spread,
  c.bucket                                                       AS common_discount,
  round(c.n::numeric / a.sample_n, 2)                            AS common_share,
  round((SELECT count(*) FROM pairs p
          WHERE p.hospital_id = a.hospital_id
            AND p.product_code = a.product_code
            AND round(p.discount / 0.05) * 0.05
              = round(a.min_discount / 0.05) * 0.05
        )::numeric / a.sample_n, 2)                              AS min_share,
  CASE
    WHEN a.min_discount <= 0.50
         AND (a.median_discount - a.min_discount) >= 0.20 THEN '破底警示'
    WHEN a.spread >= 0.20                              THEN '折數波動'
    ELSE '穩定'
  END                                                            AS risk_flag,
  (a.sample_n < 3)                                               AS low_sample
FROM agg a
JOIN bucket_counts c
  ON c.hospital_id = a.hospital_id
 AND c.product_code = a.product_code
 AND c.rk_common = 1;

-- ---------- 3. 卡片顯示層(補上次報價/成交、距上次成交月數、醫院名)----------
CREATE OR REPLACE VIEW public.v_cardA_card AS
SELECT
  an.*,
  COALESCE(h.name_short, h.name_full)              AS hospital_name,
  h.system_prefix,
  lq.quoted_unit_price                             AS last_quote_price,
  lq.quoted_date                                   AS last_quote_date,
  ls.unit_price                                    AS last_sale_price,
  ls.sales_date                                    AS last_sale_date,
  (ls.sales_date IS NOT NULL)                      AS sold_here,
  CASE WHEN ls.sales_date IS NOT NULL
       THEN floor((current_date - ls.sales_date) / 30.0)::int END AS months_since_sale,
  (ls.sales_date IS NOT NULL
   AND (current_date - ls.sales_date) >= 365)      AS raise_price_hint
FROM public.v_cardA_analysis an
LEFT JOIN public.medsec_hospitals h
  ON h.id = an.hospital_id
LEFT JOIN LATERAL (
  SELECT quoted_unit_price, quoted_date
  FROM public.medsec_quote_history
  WHERE btrim(hospital_id) = an.hospital_id
    AND product_code = an.product_code
    AND quoted_unit_price > 0
  ORDER BY quoted_date DESC
  LIMIT 1
) lq ON true
LEFT JOIN LATERAL (
  SELECT unit_price, sales_date
  FROM public.medsec_sales
  WHERE btrim(customer_code) = an.hospital_id
    AND product_code = an.product_code
    AND unit_price > 0
  ORDER BY sales_date DESC
  LIMIT 1
) ls ON true;

-- ---------- 4. 他院同品項明細(Lynn/老闆 only,含折數)----------
CREATE OR REPLACE FUNCTION public.fn_cardA_other_hospitals(
  p_product_code     text,
  p_exclude_hospital text
)
RETURNS TABLE(
  hospital_id   text,
  hospital_name text,
  system_prefix text,
  sale_price    numeric,
  sale_date     date,
  discount      numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT COALESCE(public.auth_can_edit_pricing(), FALSE) THEN RETURN; END IF;
  RETURN QUERY
    SELECT btrim(s.customer_code)::text                AS hospital_id,
           COALESCE(h.name_short, h.name_full)::text   AS hospital_name,
           h.system_prefix::text                       AS system_prefix,
           s.unit_price::numeric                       AS sale_price,
           s.sales_date::date                          AS sale_date,
           p.discount::numeric                         AS discount
    FROM public.medsec_sales s
    LEFT JOIN public.medsec_hospitals h
      ON h.id = btrim(s.customer_code)
    LEFT JOIN public.v_cardA_pairs p
      ON p.hospital_id        = btrim(s.customer_code)
     AND p.product_code       = s.product_code
     AND p.paired_sales_date  = s.sales_date
    WHERE s.product_code  = p_product_code
      AND btrim(s.customer_code) <> p_exclude_hospital
      AND s.unit_price > 0
    ORDER BY s.sales_date DESC
    LIMIT 20;
END $$;

GRANT EXECUTE ON FUNCTION
  public.fn_cardA_other_hospitals(text, text) TO authenticated;

-- ---------- GRANT views(RLS 已內嵌於 v_cardA_pairs 的 WHERE)----------
GRANT SELECT ON public.v_cardA_pairs    TO authenticated;
GRANT SELECT ON public.v_cardA_analysis TO authenticated;
GRANT SELECT ON public.v_cardA_card     TO authenticated;

-- ---------- NOTIFY PostgREST ----------
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗收 / smoke test(Lynn 已用 Excel 對過)
-- ============================================================
-- 1) SELECT count(*) FROM v_cardA_analysis;          -- 期望 ≈ 1984
-- 2) SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY median_discount)
--    FROM v_cardA_analysis;                          -- 期望 ≈ 0.90
-- 3) 抽點:
--    SELECT * FROM v_cardA_card
--    WHERE hospital_id='CKUS' AND product_code='10BA40';     -- ≈ 90% 穩定
--    SELECT * FROM v_cardA_card
--    WHERE hospital_id='TCHE' AND product_code='PM200';      -- 落差大
--    SELECT * FROM v_cardA_card
--    WHERE hospital_id='VGKS' AND product_code='AF02';       -- 破底警示
-- 4) SELECT * FROM fn_cardA_other_hospitals('10BA40','CKUS');
-- 5) 業祕(secretary)身分跑 SELECT * FROM v_cardA_analysis LIMIT 1;
--    應回 0 列(auth_can_edit_pricing 擋住)
