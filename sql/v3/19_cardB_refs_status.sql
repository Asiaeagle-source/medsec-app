-- ============================================================
-- sql/v3/19_cardB_refs_status.sql — Card B §5-6 前端配套:refs 加 status 欄
-- ============================================================
-- 用途(per 2026-05-26 Lynn 拍板):
--   medsec_quote_invoice_refs 加 status('pending' / 'approved')
--   業祕勾完 8 張裡的 3 張 → INSERT(status=pending,系統強制)
--   Lynn 在 admin-pricing「報價建議」Tab 看 pending → 按核准 → UPDATE status='approved'
--   業祕端只能拿 status='approved' 的給醫院;'pending' 顯示「待 Lynn 核准」
--
-- RLS 改動(覆寫 sql/v3/18 的 qir_write):
--   SELECT:登入即可(不變,sql/v3/18 已建)
--   INSERT:登入即可 + status 強制 'pending'(業祕能塞,但只能塞 pending)
--   UPDATE:Lynn-only(auth_can_edit_pricing) — 改 status 'pending'→'approved' 的動作
--   DELETE:Lynn-only — 業祕誤勾不能刪,要 Lynn 撤回
--
-- 為何不開「業祕刪自己的 pending」:避免業祕送出 → Lynn 還沒看 → 業祕反悔刪
-- 造成 Lynn 來看時資料消失的 race。要修改一律找 Lynn,流程簡單。
--
-- 將來放寬(Lynn 對 Card B 信任後不審):
--   把 default 從 'pending' 改 'approved' 即可,前端不顯示 pending chip 就行;
--   schema 不用再改。
--
-- idempotent:ADD COLUMN IF NOT EXISTS / DROP POLICY IF EXISTS
-- ============================================================

-- ---------- 欄位:status ----------
ALTER TABLE public.medsec_quote_invoice_refs
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';

-- CHECK 約束(用 DO 區塊兼容已存在的情況)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'medsec_quote_invoice_refs_status_chk'
  ) THEN
    ALTER TABLE public.medsec_quote_invoice_refs
      ADD CONSTRAINT medsec_quote_invoice_refs_status_chk
      CHECK (status IN ('pending', 'approved'));
  END IF;
END $$;

COMMENT ON COLUMN public.medsec_quote_invoice_refs.status IS
  'pending = 業祕已勾、待 Lynn 核准;approved = Lynn 已核准、業祕可拿給醫院';

-- ---------- 索引:Lynn 撈 pending 用 ----------
CREATE INDEX IF NOT EXISTS idx_qir_pending
  ON public.medsec_quote_invoice_refs (selected_at DESC)
  WHERE status = 'pending';

-- ---------- RLS 重寫 ----------
-- 把 sql/v3/18 的 qir_write 拆成三條(INSERT / UPDATE / DELETE)
DROP POLICY IF EXISTS qir_write           ON public.medsec_quote_invoice_refs;
DROP POLICY IF EXISTS qir_insert          ON public.medsec_quote_invoice_refs;
DROP POLICY IF EXISTS qir_update_approve  ON public.medsec_quote_invoice_refs;
DROP POLICY IF EXISTS qir_delete          ON public.medsec_quote_invoice_refs;

-- INSERT:登入即可,但 status 強制 'pending'
--   (業祕不能繞過送 status='approved';前端傳值或預設都會被 CHECK 擋)
CREATE POLICY qir_insert ON public.medsec_quote_invoice_refs
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() IS NOT NULL AND status = 'pending');

-- UPDATE:Lynn-only(核准動作)
CREATE POLICY qir_update_approve ON public.medsec_quote_invoice_refs
  FOR UPDATE TO authenticated
  USING      (COALESCE(public.auth_can_edit_pricing(), FALSE))
  WITH CHECK (COALESCE(public.auth_can_edit_pricing(), FALSE));

-- DELETE:Lynn-only(業祕誤勾找 Lynn,避免送審消失 race)
CREATE POLICY qir_delete ON public.medsec_quote_invoice_refs
  FOR DELETE TO authenticated
  USING (COALESCE(public.auth_can_edit_pricing(), FALSE));

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 1) 欄位 / CHECK:
--    \d medsec_quote_invoice_refs
--      → 應見 status text NOT NULL DEFAULT 'pending'
--      → 應見 CHECK (status IN ('pending','approved'))
--
-- 2) Lynn 視角(manager 或 0001):
--    INSERT INTO medsec_quote_invoice_refs
--      (crm_quote_type, crm_quote_no, product_code, invoice_no, hospital_id)
--    VALUES ('AECC','20260526-001','10BA40','INV-2026-0001','CKUS');
--      → ok,status 自動 'pending'
--    UPDATE medsec_quote_invoice_refs SET status='approved'
--      WHERE crm_quote_no='20260526-001' AND invoice_no='INV-2026-0001';
--      → ok
--
-- 3) 業祕視角:
--    INSERT INTO medsec_quote_invoice_refs
--      (crm_quote_type, crm_quote_no, product_code, invoice_no, hospital_id)
--    VALUES ('AECC','20260526-002','10BA40','INV-2026-0002','CKUS');
--      → ok,status='pending'(預設)
--    INSERT INTO medsec_quote_invoice_refs
--      (crm_quote_type, crm_quote_no, product_code, invoice_no, hospital_id, status)
--    VALUES ('AECC','20260526-003','10BA40','INV-2026-0003','CKUS', 'approved');
--      → 42501 RLS 擋(WITH CHECK status='pending' 不通過)
--    UPDATE medsec_quote_invoice_refs SET status='approved' WHERE ...;
--      → 42501 RLS 擋(qir_update_approve 只給 Lynn)
--    DELETE FROM medsec_quote_invoice_refs WHERE ...;
--      → 42501 RLS 擋(qir_delete 只給 Lynn)
--
-- 4) 索引:
--    EXPLAIN SELECT * FROM medsec_quote_invoice_refs WHERE status='pending';
--      → 應走 idx_qir_pending
