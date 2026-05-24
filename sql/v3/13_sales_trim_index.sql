-- ============================================================
-- sql/v3/13_sales_trim_index.sql — Card A LATERAL 加速:trim expression 複合索引
-- ============================================================
-- 症狀:v_carda_pairs 的 LATERAL JOIN 慢爆(8.5s timeout)。
-- EXPLAIN ANALYZE 確診:medsec_sales 走 Bitmap Heap Scan,只用 idx_sales_product
-- (索引僅 product_code),每組撈 ~422 列再 filter 到 ~3 列,heap blocks 3.16M。
--
-- v_carda_pairs LATERAL 的 WHERE 條件:
--   btrim(customer_code) = q.hospital_id
--   AND product_code = q.product_code
--   AND unit_price > 0
--   AND sales_date >= q.quoted_date
-- → 三欄組合(product_code, btrim(customer_code), sales_date)+ 部分索引 unit_price>0
--
-- TRIM(x) 與 btrim(x) 在 PostgreSQL 解析後是同一個函式,planner 認得對應。
-- WHERE unit_price > 0 → partial index,索引尺寸小、命中率高。
--
-- 既有索引(sql/v3/08_medsec_sales.sql)未涵蓋此 case:
--   idx_sales_unique: 5 欄唯一鍵(去重用)
--   idx_sales_hospital_product: (hospital_id, ...) — 但 view 用 btrim(customer_code)
--     對齊 hospital_id,並非真的 hospital_id 欄位
--   idx_sales_system_product / idx_sales_date — 都對不到 LATERAL
--
-- idempotent:CREATE INDEX IF NOT EXISTS。
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_sales_match_trim
  ON public.medsec_sales (product_code, (TRIM(customer_code)), sales_date)
  WHERE unit_price > 0;

COMMENT ON INDEX public.idx_sales_match_trim IS
  'Card A v_carda_pairs LATERAL 用:(品號, trim(客戶代號), 銷貨日)+部分索引 unit_price>0';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 確認索引建立:
--    SELECT indexdef FROM pg_indexes WHERE indexname='idx_sales_match_trim';
--
-- 2. 重跑 EXPLAIN ANALYZE 應看到:
--    -> Index Scan using idx_sales_match_trim on medsec_sales
--    Execution Time < 1000 ms(原本 ~8500 ms)
--
--    EXPLAIN ANALYZE SELECT count(*) FROM v_carda_pairs;
--    EXPLAIN ANALYZE SELECT count(*) FROM v_carda_card;
--
-- 3. 索引大小(預期 < 表的 10%):
--    SELECT pg_size_pretty(pg_relation_size('idx_sales_match_trim'));
