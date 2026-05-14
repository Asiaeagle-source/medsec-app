-- ============================================================
-- 04_create_audit_log.sql — V2 Sprint 1 step 4
-- ============================================================
-- 為什麼：
--   分級審核（V2 handoff §2.1）— 聯絡資訊 / 備註類欄位業祕直接寫，
--   不走 suggestions 審核，但要留 audit trail 給後續查證。
--
-- Lynn 拍板 Q5：FK 改 text + uuid。
--
-- 哪些欄位走 audit log（不走 suggestions）：
--   contact_person / contact_phone / contact_email / notes /
--   free_text_notes 等聯絡 + 備註欄位。
--
-- 哪些欄位走 suggestions（不走 audit log）：
--   invoice_company / invoice_mode / invoice_track / payment_cycle_note /
--   case_close_method / order_mode / shipping_destination / shipping_method /
--   packaging_notes / invoice_product_name / discount_type / credentials 等
--   核心商務規則（V2 handoff §2.1 表）。
--
-- 由前端 medsec-common.js 的 REQUIRES_APPROVAL 清單決定走哪條路。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_audit_log (
  id            bigserial PRIMARY KEY,
  table_name    text NOT NULL,          -- 'hospital_operation_rules' / 'hospitals' / ...
  field_name    text NOT NULL,
  hospital_id   text REFERENCES public.medsec_hospitals(id) ON DELETE SET NULL,
                                        -- nullable：非 hospital scope 的事件（V2 暫不用）
  record_id     uuid,                   -- 對非主鍵 = hospital_id 的表的 row id（例 credentials.id）
  old_value     text,
  new_value     text,
  changed_by    uuid NOT NULL REFERENCES public.profiles(id),
  changed_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_hospital    ON public.medsec_audit_log(hospital_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_by  ON public.medsec_audit_log(changed_by);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at  ON public.medsec_audit_log(changed_at DESC);

COMMENT ON TABLE public.medsec_audit_log IS
  'V2 sprint 1：非核心欄位（聯絡 / 備註）的直接改寫 audit trail。'
  '核心商務欄位走 medsec_rule_suggestions 審核，不在這。';
