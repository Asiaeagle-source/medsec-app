-- ============================================================
-- 01_alter_operation_rules.sql — V2 Sprint 1 step 1
-- ============================================================
-- 為什麼：
--   V1 既有 medsec_hospital_operation_rules 是 15 欄、0 筆 seed。
--   V2 sprint 1 規則完整度 view 跟 secretary.html「補規則」對話需要
--   3 個新欄位（shipping_method / invoice_track / dual_invoice）。
--
-- Lynn 拍板 Q1：ADD 3 欄。不 ADD has_consignment / consignment_notes —
--   V1 已有獨立 medsec_consignment_inventory 表（WIS07），重複表達。
--
-- 套用順序：V2 sprint 1 第 1 支。idempotent。
-- ============================================================

ALTER TABLE public.medsec_hospital_operation_rules
  ADD COLUMN IF NOT EXISTS shipping_method  text;
ALTER TABLE public.medsec_hospital_operation_rules
  ADD COLUMN IF NOT EXISTS invoice_track    text;
ALTER TABLE public.medsec_hospital_operation_rules
  ADD COLUMN IF NOT EXISTS dual_invoice     bool DEFAULT false;

COMMENT ON COLUMN public.medsec_hospital_operation_rules.shipping_method IS
  'V2 sprint 1：出貨方式（業務親送 / 嘉里物流 / 郵局 / ...）。對應 V2 handoff §3.3 模式 B 提問。';
COMMENT ON COLUMN public.medsec_hospital_operation_rules.invoice_track IS
  'V2 sprint 1：發票字軌（06/31, 02/32, 03/32 ...）。雙開時填組合，例 "06/31 / 02/32 / 03/32"。';
COMMENT ON COLUMN public.medsec_hospital_operation_rules.dual_invoice IS
  'V2 sprint 1：是否需雙開發票（雄鷹電子 + 君華手開 等組合）。';

-- ============================================================
-- 驗證
-- ============================================================
-- 應該回 3 列
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name='medsec_hospital_operation_rules'
  AND column_name IN ('shipping_method','invoice_track','dual_invoice')
ORDER BY column_name;
