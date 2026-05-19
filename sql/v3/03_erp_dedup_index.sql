-- ============================================================
-- sql/v3/03_erp_dedup_index.sql — ERP 200K 可恢復匯入用唯一索引
-- ============================================================
-- 需求 C:中斷後重新上傳不可產生重複。PostgREST upsert 的 onConflict
-- 必須對應一個「非 partial」唯一索引,故新增:
--   (customer_code, product_code, sales_date, product_sn)
--
-- 「Schema 不變」說明:本檔僅新增一個附加索引,
--   不改任何欄位 / 不動 medsec_quote_history 結構 / 不刪資料。
--   這是「可重複上傳不重複」在技術上的必要前提(無此索引 PostgREST
--   無法做 conflict 去重)。idempotent:IF NOT EXISTS,可重跑。
--
-- 限制:product_sn 為 NULL 時 Postgres 視 NULL 相異 → 無序號的成交列
--   重複上傳仍可能各自成列(醫材成交多半有序號,實務影響小)。
-- 與既有 idx_qh_crm_unique(crm_quote_no,product_code) 並存不衝突。
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_qh_erp_unique
  ON public.medsec_quote_history
     (customer_code, product_code, sales_date, product_sn);

-- ============================================================
-- 驗證
-- ============================================================
-- \d medsec_quote_history   -- 應見 idx_qh_erp_unique
-- 重複上傳同一份 ERP Excel 兩次:
--   SELECT count(*) FROM medsec_quote_history WHERE sales_date IS NOT NULL;
--   兩次結果應一致(有序號者不增加)
