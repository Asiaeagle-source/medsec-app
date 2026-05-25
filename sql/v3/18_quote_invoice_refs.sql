-- ============================================================
-- sql/v3/18_quote_invoice_refs.sql — Card B §3 報價單↔他院發票 連結表
-- ============================================================
-- 用途:業祕報完價,醫院要他院發票對價 → 從 fn_cardB_invoice_candidates
--       的 8 張候選中,Lynn 拍板選 3 張(spec §3)→ 此表記錄選擇結果。
--       業祕之後回到此報價單即可看到 Lynn 選定的 3 張發票號/日期/醫院,
--       拿去給醫院。
--
-- PK (per E2 答案):(crm_quote_type, crm_quote_no, product_code, invoice_no)
--   一張報價單 × 一個品號最多選 3 張發票(spec §3),但 PK 沒寫死 3 張上限
--   (用程式邏輯/檢查限);schema 不強制以便日後彈性。
-- 加欄 hospital_id(per E2):記下本報價單對應的醫院,方便依醫院找已選發票。
--
-- RLS:
--   讀:任何登入者(業祕需取發票號給醫院)
--   寫:Lynn-only(拍板選擇是策略動作,業祕不可自選);用 auth_can_edit_pricing
--
-- idempotent:CREATE TABLE IF NOT EXISTS + ALTER ADD COLUMN IF NOT EXISTS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_quote_invoice_refs (
  crm_quote_type text        NOT NULL,
  crm_quote_no   text        NOT NULL,
  product_code   text        NOT NULL,
  invoice_no     text        NOT NULL,
  hospital_id    text,                                    -- 本報價單對應醫院(E2)
  selected_by    uuid        NOT NULL DEFAULT auth.uid(),
  selected_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (crm_quote_type, crm_quote_no, product_code, invoice_no)
);

-- 自癒(既存表無此欄者補)
ALTER TABLE public.medsec_quote_invoice_refs ADD COLUMN IF NOT EXISTS hospital_id text;
ALTER TABLE public.medsec_quote_invoice_refs ADD COLUMN IF NOT EXISTS selected_by uuid;
ALTER TABLE public.medsec_quote_invoice_refs ADD COLUMN IF NOT EXISTS selected_at timestamptz DEFAULT now();

-- ---------- 索引 ----------
-- 依報價單找已選發票(業祕回到單子看 Lynn 選的)
CREATE INDEX IF NOT EXISTS idx_qir_quote
  ON public.medsec_quote_invoice_refs (crm_quote_type, crm_quote_no);
-- 依醫院+品號找曾選過的發票(避免重複給同家醫院看同一張)
CREATE INDEX IF NOT EXISTS idx_qir_hospital_product
  ON public.medsec_quote_invoice_refs (hospital_id, product_code)
  WHERE hospital_id IS NOT NULL;
-- 依發票號找曾被哪幾張報價單引用過(稽核用)
CREATE INDEX IF NOT EXISTS idx_qir_invoice
  ON public.medsec_quote_invoice_refs (invoice_no);

COMMENT ON TABLE public.medsec_quote_invoice_refs IS
  'Card B §3:Lynn 拍板選的他院發票,連結回特定報價單品項。業祕讀,Lynn 寫。';

-- ---------- RLS ----------
ALTER TABLE public.medsec_quote_invoice_refs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qir_read  ON public.medsec_quote_invoice_refs;
DROP POLICY IF EXISTS qir_write ON public.medsec_quote_invoice_refs;

-- 讀:登入即可(業祕取已選發票)
CREATE POLICY qir_read ON public.medsec_quote_invoice_refs
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

-- 寫:Lynn-only(策略動作,業祕不可自選)
CREATE POLICY qir_write ON public.medsec_quote_invoice_refs
  FOR ALL TO authenticated
  USING (COALESCE(public.auth_can_edit_pricing(), FALSE))
  WITH CHECK (COALESCE(public.auth_can_edit_pricing(), FALSE));

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 1) 表結構
--    \d medsec_quote_invoice_refs
--    -- 應見 7 欄(4 欄 PK + hospital_id + selected_by + selected_at)
--
-- 2) Lynn 寫入測試(實際 UI 用):
--    INSERT INTO medsec_quote_invoice_refs
--      (crm_quote_type, crm_quote_no, product_code, invoice_no, hospital_id)
--    VALUES ('AECC','20260520-001','10BA40','INV-2025-0001','CKUS');
--
-- 3) 業祕讀:任何登入者皆可 SELECT
--    SELECT * FROM medsec_quote_invoice_refs
--    WHERE crm_quote_type='AECC' AND crm_quote_no='20260520-001';
--
-- 4) 業祕寫(應被擋):
--    業祕身分 INSERT 同上 → RLS 擋,42501 permission denied
