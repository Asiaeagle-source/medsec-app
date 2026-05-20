-- ============================================================
-- sql/v3/02_quote_history_rls.sql — Sprint 3A RLS
-- ============================================================
-- 權限模型(Lynn 拍板):
--   - 業祕(secretary):完全不可看 quote_history / pricing 策略
--     (那是 Lynn 的議價策略資訊,外洩會影響談判)
--   - Cindie(purchasing):可讀(她要看歷史對應產品 / 健保碼維護)
--   - Lynn(manager)/ Andrew(老闆 employee_id 0001):full access
-- idempotent:DROP POLICY IF EXISTS 後重建。
-- ============================================================

-- 可編輯 = manager 或 老闆(0001);可讀 = 上述 + purchasing
CREATE OR REPLACE FUNCTION public.auth_can_edit_pricing()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.auth_medsec_role() = 'manager'
      OR EXISTS (SELECT 1 FROM public.profiles
                  WHERE id = auth.uid() AND employee_id = '0001');
$$;
CREATE OR REPLACE FUNCTION public.auth_can_see_pricing()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.auth_can_edit_pricing()
      OR public.auth_medsec_role() = 'purchasing';
$$;
GRANT EXECUTE ON FUNCTION public.auth_can_edit_pricing() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auth_can_see_pricing() TO authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'medsec_quote_history',
    'medsec_hospital_pricing_strategy',
    'medsec_nhi_pricing',
    'medsec_product_nhi_mapping'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I_read  ON public.%I;', t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I_write ON public.%I;', t, t);
    EXECUTE format($f$
      CREATE POLICY %I_read ON public.%I
        FOR SELECT TO authenticated
        USING (public.auth_can_see_pricing());$f$, t, t);
    EXECUTE format($f$
      CREATE POLICY %I_write ON public.%I
        FOR ALL TO authenticated
        USING (public.auth_can_edit_pricing())
        WITH CHECK (public.auth_can_edit_pricing());$f$, t, t);
  END LOOP;
END $$;

-- ============================================================
-- 驗證
-- ============================================================
-- 以 Lynn 登入:SELECT public.auth_can_edit_pricing();  -- t
-- 以 Cindie:   SELECT public.auth_can_see_pricing();   -- t / edit f
-- 以業祕:      兩者皆 f → SELECT * FROM medsec_quote_history 應 0 列(RLS 擋)
