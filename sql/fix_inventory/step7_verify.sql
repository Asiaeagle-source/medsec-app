-- ============================================================
-- Step 7: 驗證所有資料補進去了
-- ============================================================

-- 1. 總筆數應該是 5260
SELECT COUNT(*) AS total FROM medsec_products;

-- 2. 看 LEFT(id,1) 分布，確認 6 和 7 開頭的回來了
SELECT 
  LEFT(id, 1) AS first_char,
  COUNT(*) AS cnt
FROM medsec_products
GROUP BY LEFT(id, 1)
ORDER BY first_char;

-- 3. 抽樣看補進來的資料有沒有 24 個欄位
SELECT id, name, specification, stock_qty, unit_cost, supplier_name, last_cost_twd
FROM medsec_products
WHERE LEFT(id, 1) = '6'
LIMIT 5;
