-- ============================================================
-- 05_create_completeness_view.sql — V2 Sprint 1 step 5
-- ============================================================
-- 為什麼：
--   secretary.html「我負責的醫院」每張卡片要顯示規則完整度進度條 +
--   缺哪幾個關鍵欄位 chip。hospital.html 模式 A 偵測（completeness_pct
--   < 80% 跳卡片）也走這個 view。
--
-- Lynn 拍板 Q2：分母 9（既有 7 + ADD 2 = 9）。
--   不算 dual_invoice 進完整度（bool 預設 false，沒填 ≠ 缺資訊）。
--   不算 contact_person / special_notes / source_secretary 進完整度
--   （聯絡 / 備註類，不是「操作規則」核心）。
--
-- 來源：V1 既有 medsec_hospital_operation_rules 7 欄 + V2 ADD 2 欄
--   1. order_mode
--   2. shipping_destination
--   3. shipping_method        ← V2 ADD
--   4. packaging_notes
--   5. invoice_mode
--   6. invoice_track          ← V2 ADD
--   7. payment_cycle_note     ← V1 名稱不是 payment_cycle
--   8. invoice_product_name   ← V1 名稱不是 invoice_product_name_style
--   9. case_close_method
-- ============================================================

CREATE OR REPLACE VIEW public.medsec_hospital_rule_completeness AS
SELECT
  h.id            AS hospital_id,
  h.name_short    AS hospital_name,                              -- V1 是 name_full / name_short 兩欄，UI 卡用短名
  CASE
    WHEN r.hospital_id IS NULL THEN 0
    ELSE (
      (CASE WHEN r.order_mode             IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.shipping_destination   IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.shipping_method        IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.packaging_notes        IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.invoice_mode           IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.invoice_track          IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.payment_cycle_note     IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.invoice_product_name   IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.case_close_method      IS NOT NULL THEN 1 ELSE 0 END)
    ) * 100 / 9
  END AS completeness_pct,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN r.hospital_id IS NULL OR r.order_mode           IS NULL THEN 'order_mode'           END,
    CASE WHEN r.hospital_id IS NULL OR r.shipping_destination IS NULL THEN 'shipping_destination' END,
    CASE WHEN r.hospital_id IS NULL OR r.shipping_method      IS NULL THEN 'shipping_method'      END,
    CASE WHEN r.hospital_id IS NULL OR r.packaging_notes      IS NULL THEN 'packaging_notes'      END,
    CASE WHEN r.hospital_id IS NULL OR r.invoice_mode         IS NULL THEN 'invoice_mode'         END,
    CASE WHEN r.hospital_id IS NULL OR r.invoice_track        IS NULL THEN 'invoice_track'        END,
    CASE WHEN r.hospital_id IS NULL OR r.payment_cycle_note   IS NULL THEN 'payment_cycle_note'   END,
    CASE WHEN r.hospital_id IS NULL OR r.invoice_product_name IS NULL THEN 'invoice_product_name' END,
    CASE WHEN r.hospital_id IS NULL OR r.case_close_method    IS NULL THEN 'case_close_method'    END
  ], NULL) AS missing_fields
FROM public.medsec_hospitals h
LEFT JOIN public.medsec_hospital_operation_rules r ON r.hospital_id = h.id;

COMMENT ON VIEW public.medsec_hospital_rule_completeness IS
  'V2 sprint 1：9 個關鍵操作規則欄位的完整度 %。'
  'completeness_pct 0-100、missing_fields text[]。'
  'RLS：view 不能直接 ENABLE RLS，繼承底下 medsec_hospitals + operation_rules 的 RLS。';
