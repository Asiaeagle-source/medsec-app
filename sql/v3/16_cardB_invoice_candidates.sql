-- ============================================================
-- sql/v3/16_cardB_invoice_candidates.sql — Card B §3 他院發票候選 RPC
-- ============================================================
-- 用途:業祕報完價,醫院要他院發票對價時 → 點開叫出 8 張候選 →
--       Lynn 拍板選 3 張(寫入 medsec_quote_invoice_refs) →
--       業祕拿選定的 3 張(發票號/日期/醫院/品號)給醫院。
--
-- 8 張候選組成(spec §3):
--   6 張:依「單價」由高到低,同品號跨所有醫院真實成交(invoice_no 必非空)
--   2 張:依「整張發票總額」由高到低(含此品號的發票,整張所有 line items 加總)
--   去重:同一張 invoice_no 只出現一次(取單價最高的那行)
--
-- 整張發票總額(per §6.3 答案 A):整張發票所有 line items 加總,
--   不論品號 → 主機+配件+任何小耗材全算,代表「整批單的氣勢」。
--
-- 守門:此為「ERP 能查到的他院成交」,業祕需要(報價作業)→ 登入即可。
--   非 Lynn-only(spec §0 對齊)。SECURITY DEFINER + auth.uid() check。
--
-- 2026-05-26 排序加「2023/04 後優先」:
--   近期成交可查證,業務拿出去對價有底氣;老單僅作參考。
--   兩群(unit_high / total_high)各自內部:先列 2023/04 後,再列之前的;
--   群內 ORDER 維持原本(unit_price / invoice_total)。
--
-- TODO(未做):按「性質」分流(維修/設備/器械/耗材/汰舊)。
--   原因:medsec_sales 沒有 CRM 單別欄(crm_quote_type)可串回 quote 性質,
--   ERP 成交檔本身也無「性質」欄。要做需先在 sales 端建一條
--   sales↔quote 反向 join(via invoice_no → opportunity_no → quote_type),
--   且 ~30% 成交對不回 quote,涵蓋率不完整。先列 TODO,Card C 一起評估。
--
-- 2026-05-26 hotfix:
--   執行時 42702「column reference 'invoice_no' is ambiguous」。
--   原因 total_high 的子查詢 `NOT IN (SELECT invoice_no FROM unit_high)`
--   無表別名,PG 解析器在外查詢有 b.invoice_no、unit_high.invoice_no、
--   inv_totals.invoice_no 之外又看到無前綴的 invoice_no 時觸發歧義
--   (視 planner 與版本而定,可能視為 correlated reference)。
--   修法:
--     1) 子查詢加 alias `uh`:NOT IN (SELECT uh.invoice_no FROM unit_high uh)
--     2) base CTE 拒用 p.*,顯式列每欄(且 AS 同名)→ 後續解析有明確 origin
--     3) 所有 select list 統一加 AS 同名,避免 UNION ALL 對欄序判定的隱憂
--     4) 函式名統一全小寫 fn_cardb_invoice_candidates(對齊 prod 實際物件名;
--        PG 無引號宣告本來就會折小寫,這裡顯式對齊免再踩大小寫坑)
--   執行:CREATE OR REPLACE 直接覆寫 prod 函式,重跑本檔即可。
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_cardb_invoice_candidates(p_product_code text)
RETURNS TABLE(
  kind          text,         -- 'unit_high' (6 張) | 'total_high' (2 張)
  invoice_no    text,
  sales_date    date,
  hospital_id   text,
  hospital_name text,
  system_prefix text,
  customer_type text,
  product_code  text,
  unit_price    numeric,
  qty           numeric,
  invoice_total numeric        -- 整張發票所有品項加總
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH inv_totals AS (
    -- 每張發票的總額(所有 line items 加總,不限品號)
    SELECT s.invoice_no AS invoice_no,
           sum(s.unit_price * COALESCE(s.qty, 0)) AS invoice_total
    FROM public.medsec_sales s
    WHERE s.invoice_no IS NOT NULL
      AND s.unit_price IS NOT NULL
    GROUP BY s.invoice_no
  ),
  per_invoice AS (
    -- 同品號於同張發票多 line 時,取單價最高那行;一張發票一列
    SELECT
      s.invoice_no    AS invoice_no,
      s.sales_date    AS sales_date,
      btrim(s.customer_code) AS hospital_id,
      s.product_code  AS product_code,
      s.unit_price    AS unit_price,
      s.qty           AS qty,
      ROW_NUMBER() OVER (
        PARTITION BY s.invoice_no
        ORDER BY s.unit_price DESC, s.sales_date DESC
      ) AS rn
    FROM public.medsec_sales s
    WHERE s.product_code = p_product_code
      AND s.unit_price > 0
      AND s.invoice_no IS NOT NULL
  ),
  base AS (
    -- 顯式列欄(不用 p.*),避免 invoice_no 在後續 NOT IN 子查詢解析時歧義
    SELECT
      p.invoice_no    AS invoice_no,
      p.sales_date    AS sales_date,
      p.hospital_id   AS hospital_id,
      p.product_code  AS product_code,
      p.unit_price    AS unit_price,
      p.qty           AS qty,
      it.invoice_total AS invoice_total
    FROM per_invoice p
    LEFT JOIN inv_totals it ON it.invoice_no = p.invoice_no
    WHERE p.rn = 1
  ),
  unit_high AS (
    SELECT
      'unit_high'::text AS kind,
      b.invoice_no               AS invoice_no,
      b.sales_date               AS sales_date,
      b.hospital_id::text        AS hospital_id,
      COALESCE(h.name_short, h.name_full)::text AS hospital_name,
      h.system_prefix::text      AS system_prefix,
      h.customer_type::text      AS customer_type,
      b.product_code::text       AS product_code,
      b.unit_price::numeric      AS unit_price,
      b.qty::numeric             AS qty,
      b.invoice_total::numeric   AS invoice_total
    FROM base b
    LEFT JOIN public.medsec_hospitals h ON h.id = b.hospital_id
    -- 2026-05-26 排序加「2023/04 後優先」:
    --   近期成交可查證(業務手上 ERP 截圖、客服紀錄都還在),老單僅參考。
    --   群內仍依單價高到低。NULLS LAST 讓無日期者最後。
    ORDER BY (b.sales_date >= DATE '2023-04-01') DESC NULLS LAST,
             b.unit_price DESC NULLS LAST,
             b.sales_date DESC
    LIMIT 6
  ),
  total_high AS (
    SELECT
      'total_high'::text AS kind,
      b.invoice_no               AS invoice_no,
      b.sales_date               AS sales_date,
      b.hospital_id::text        AS hospital_id,
      COALESCE(h.name_short, h.name_full)::text AS hospital_name,
      h.system_prefix::text      AS system_prefix,
      h.customer_type::text      AS customer_type,
      b.product_code::text       AS product_code,
      b.unit_price::numeric      AS unit_price,
      b.qty::numeric             AS qty,
      b.invoice_total::numeric   AS invoice_total
    FROM base b
    LEFT JOIN public.medsec_hospitals h ON h.id = b.hospital_id
    WHERE b.invoice_total IS NOT NULL
      AND b.invoice_no NOT IN (SELECT uh.invoice_no FROM unit_high uh)   -- 去重發票號(alias uh)
    -- 同 unit_high:2023/04 後優先,群內依整張總額高到低
    ORDER BY (b.sales_date >= DATE '2023-04-01') DESC NULLS LAST,
             b.invoice_total DESC NULLS LAST,
             b.sales_date DESC
    LIMIT 2
  )
  SELECT * FROM unit_high
  UNION ALL
  SELECT * FROM total_high;
END $$;

GRANT EXECUTE ON FUNCTION public.fn_cardb_invoice_candidates(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- SELECT * FROM fn_cardb_invoice_candidates('10BA40');
--   -- 應回 8 列(unit_high 6 + total_high 2),invoice_no 不重複,
--   -- 6 張依 unit_price DESC,2 張依 invoice_total DESC
-- SELECT count(*) FROM fn_cardb_invoice_candidates('PM200');
--   -- 期望 ≤ 8(資料少時可能 <8;無資料時 0)
