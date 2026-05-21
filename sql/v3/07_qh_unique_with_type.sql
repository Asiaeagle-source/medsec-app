-- ============================================================
-- sql/v3/07_qh_unique_with_type.sql — CRM 唯一鍵補上「單別」
-- ============================================================
-- 原 idx_qh_crm_unique 只用 (crm_quote_no, product_code)→ 同 quote_no
-- 在不同 quote_type(AECC/LDCC/CCCC)時被誤判同一筆,合而為一造成假重
-- 複(實測去重 353 多為此類)。
--
-- 改為 3 欄唯一:(crm_quote_type, crm_quote_no, product_code)
-- ERP 那條 idx_qh_erp_unique 不變(sales_date+sn 維度,不受此調整影響)。
-- idempotent:DROP IF EXISTS 後 CREATE IF NOT EXISTS。
-- ============================================================

DROP INDEX IF EXISTS public.idx_qh_crm_unique;

CREATE UNIQUE INDEX IF NOT EXISTS idx_qh_crm_unique
  ON public.medsec_quote_history (crm_quote_type, crm_quote_no, product_code);

-- ============================================================
-- 驗證
-- ============================================================
-- \d medsec_quote_history          -- 應見 idx_qh_crm_unique 為 3 欄
-- 之前 quote_no 撞但 type 不同的列不再衝突;Tab1 重匯入時去重數應大幅
-- 下降或歸 0(同一 quote_type+quote_no+product_code 在新檔內天然唯一)。
