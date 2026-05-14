-- ============================================================
-- 02_create_rule_suggestions.sql — V2 Sprint 1 step 2
-- ============================================================
-- 為什麼：
--   業祕「補規則」對話（模式 B）+ 從 case 偵測異常（模式 C V2.1）
--   不能直接寫主檔，要走審核流程。Lynn(0006) + 伶華(0020) 可 Approve。
--
-- Lynn 拍板 Q3：FK 全打 text + uuid（對齊 V1 既有型別）。
--
-- RLS 在 06_rls_v2_sprint1.sql 統一加（這支只建表）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_rule_suggestions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id       text NOT NULL REFERENCES public.medsec_hospitals(id) ON DELETE CASCADE,

  source_case_id    uuid REFERENCES public.medsec_cases(id),    -- V2.1 觸發來源 case（模式 C）
  table_name        text NOT NULL,        -- 'operation_rules' / 'shipping_addresses' / 'credentials' / 'discount_rules'
  field_name        text NOT NULL,
  current_value     text,                 -- 主檔目前值（snapshot 用）
  suggested_value   text NOT NULL,        -- 業祕提的新值

  status            text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  suggested_by      uuid NOT NULL REFERENCES public.profiles(id),
  reviewed_by       uuid REFERENCES public.profiles(id),
  reviewed_at       timestamptz,
  reason            text,                 -- reject / approve 備註

  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rule_suggestions_hospital  ON public.medsec_rule_suggestions(hospital_id);
CREATE INDEX IF NOT EXISTS idx_rule_suggestions_status    ON public.medsec_rule_suggestions(status)
  WHERE status = 'pending';                                    -- partial index：審核列表 query 快
CREATE INDEX IF NOT EXISTS idx_rule_suggestions_suggested ON public.medsec_rule_suggestions(suggested_by);

COMMENT ON TABLE public.medsec_rule_suggestions IS
  'V2 sprint 1：業祕補規則 / 改規則的審核佇列。pending → approved/rejected by Lynn 或伶華。';
