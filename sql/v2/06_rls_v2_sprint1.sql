-- ============================================================
-- 06_rls_v2_sprint1.sql — V2 Sprint 1 step 6
-- ============================================================
-- 為什麼：
--   3 張新表（rule_suggestions / hospital_credentials / audit_log）
--   全部 enable RLS + 開 policy。不動既有 medsec_hospitals /
--   medsec_hospital_operation_rules 的 1 條既存 policy（V1 已套）。
--
-- Lynn 拍板 Q6：reuse `can_see_medsec_hospital()` 共用業祕 / 業務分區判定。
-- Lynn 拍板 Q7：credentials 主祕 + 副祕都看（不只主祕）。
--
-- Lynn(manager 0006) + 伶華(secretary 0020) 兩位都能 Approve suggestions —
-- 抽 helper auth_is_manager_or_co_reviewer() 用。
-- ============================================================

-- ============================================================
-- 1. 共用 helper：Lynn(manager) OR 伶華(0020)
-- ============================================================
CREATE OR REPLACE FUNCTION public.auth_is_manager_or_co_reviewer()
RETURNS bool LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND has_medsec_access = true
      AND (medsec_role = 'manager' OR employee_id = '0020')
  )
$$;

COMMENT ON FUNCTION public.auth_is_manager_or_co_reviewer() IS
  'V2 sprint 1：規則 suggestions Approve 權 — Lynn(manager) + 伶華(0020) 兩位皆可。';

GRANT EXECUTE ON FUNCTION public.auth_is_manager_or_co_reviewer() TO authenticated;

-- ============================================================
-- 2. 共用 helper：自己是否為該 hospital 的 primary / co secretary
-- ============================================================
CREATE OR REPLACE FUNCTION public.auth_is_assigned_secretary(h_id text)
RETURNS bool LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.medsec_secretary_assignments
    WHERE hospital_id = h_id
      AND (primary_secretary_id = auth.uid() OR co_secretary_id = auth.uid())
  )
$$;

COMMENT ON FUNCTION public.auth_is_assigned_secretary(text) IS
  'V2 sprint 1：判定 auth.uid() 是否為該醫院主祕或副祕。';

GRANT EXECUTE ON FUNCTION public.auth_is_assigned_secretary(text) TO authenticated;

-- ============================================================
-- 3. RLS · medsec_rule_suggestions
-- ============================================================
ALTER TABLE public.medsec_rule_suggestions ENABLE ROW LEVEL SECURITY;

-- 3.1 INSERT：自己分區的醫院可提 suggestion，且 suggested_by 必須 = auth.uid()
DROP POLICY IF EXISTS rule_suggestions_insert ON public.medsec_rule_suggestions;
CREATE POLICY rule_suggestions_insert ON public.medsec_rule_suggestions
  FOR INSERT TO authenticated
  WITH CHECK (
    suggested_by = auth.uid()
    AND public.auth_is_assigned_secretary(hospital_id)
  );

-- 3.2 SELECT：
--   自己提的看得到 (suggested_by = auth.uid())
--   自己分區的可看 (auth_is_assigned_secretary)
--   Lynn / 伶華 全看 (manager or 0020)
DROP POLICY IF EXISTS rule_suggestions_select ON public.medsec_rule_suggestions;
CREATE POLICY rule_suggestions_select ON public.medsec_rule_suggestions
  FOR SELECT TO authenticated
  USING (
    suggested_by = auth.uid()
    OR public.auth_is_assigned_secretary(hospital_id)
    OR public.auth_is_manager_or_co_reviewer()
  );

-- 3.3 UPDATE：只 Lynn / 伶華 可 Approve / Reject
DROP POLICY IF EXISTS rule_suggestions_update ON public.medsec_rule_suggestions;
CREATE POLICY rule_suggestions_update ON public.medsec_rule_suggestions
  FOR UPDATE TO authenticated
  USING (public.auth_is_manager_or_co_reviewer())
  WITH CHECK (public.auth_is_manager_or_co_reviewer());

-- 不開 DELETE — pending → rejected 也是 UPDATE 不是 DELETE，保留歷史。

-- ============================================================
-- 4. RLS · medsec_hospital_credentials
-- ============================================================
ALTER TABLE public.medsec_hospital_credentials ENABLE ROW LEVEL SECURITY;

-- 4.1 ALL（INSERT/SELECT/UPDATE/DELETE）：主祕 + 副祕 + Lynn / 伶華
--   USING 控視覺，WITH CHECK 控 INSERT/UPDATE 不能改 hospital_id 跑出自己權限範圍
DROP POLICY IF EXISTS hospital_credentials_all ON public.medsec_hospital_credentials;
CREATE POLICY hospital_credentials_all ON public.medsec_hospital_credentials
  FOR ALL TO authenticated
  USING (
    public.auth_is_assigned_secretary(hospital_id)
    OR public.auth_is_manager_or_co_reviewer()
  )
  WITH CHECK (
    public.auth_is_assigned_secretary(hospital_id)
    OR public.auth_is_manager_or_co_reviewer()
  );

-- 業務 / 採購 / 會計：連 SELECT 都拒（policy 不通過 = 看不到）

-- ============================================================
-- 5. RLS · medsec_audit_log
-- ============================================================
ALTER TABLE public.medsec_audit_log ENABLE ROW LEVEL SECURITY;

-- 5.1 INSERT：自己分區的醫院可寫；changed_by 必須 = auth.uid()
--   manager / 伶華 也可寫（後台 batch 操作備用）
DROP POLICY IF EXISTS audit_log_insert ON public.medsec_audit_log;
CREATE POLICY audit_log_insert ON public.medsec_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    changed_by = auth.uid()
    AND (
      hospital_id IS NULL                                            -- 非 hospital scope 事件
      OR public.auth_is_assigned_secretary(hospital_id)
      OR public.auth_is_manager_or_co_reviewer()
    )
  );

-- 5.2 SELECT：
--   自己分區的可看
--   Lynn / 伶華 全看
DROP POLICY IF EXISTS audit_log_select ON public.medsec_audit_log;
CREATE POLICY audit_log_select ON public.medsec_audit_log
  FOR SELECT TO authenticated
  USING (
    (hospital_id IS NOT NULL AND public.auth_is_assigned_secretary(hospital_id))
    OR public.auth_is_manager_or_co_reviewer()
  );

-- 不開 UPDATE / DELETE — audit log 不可變。

-- ============================================================
-- 驗證
-- ============================================================

-- (A) 看 3 張新表 RLS 是否 enabled
SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN ('medsec_rule_suggestions','medsec_hospital_credentials','medsec_audit_log')
ORDER BY relname;
-- 預期 t / t / t

-- (B) 看每張表的 policy 數
SELECT tablename, count(*) FROM pg_policies
WHERE schemaname='public'
  AND tablename IN ('medsec_rule_suggestions','medsec_hospital_credentials','medsec_audit_log')
GROUP BY tablename
ORDER BY tablename;
-- 預期 audit_log=2, credentials=1, rule_suggestions=3

-- (C) 看 helper function 存在
SELECT proname FROM pg_proc
WHERE proname IN ('auth_is_manager_or_co_reviewer','auth_is_assigned_secretary')
ORDER BY proname;
-- 預期 2 列

-- (D) 業祕實測（切到業祕 session 跑）：
--   set role authenticated;
--   set request.jwt.claim.sub = '<某業祕的 profiles.id>';
--
--   -- 應該回 0 列（pending suggestions 還沒有）
--   SELECT count(*) FROM medsec_rule_suggestions;
--
--   -- 應該回 0 列（credentials 還沒 seed）
--   SELECT count(*) FROM medsec_hospital_credentials;
--
--   -- 應該成功（INSERT 自己分區的）
--   INSERT INTO medsec_rule_suggestions (hospital_id, table_name, field_name, suggested_value, suggested_by)
--   VALUES ('<業祕分區某醫院id>', 'operation_rules', 'order_mode', '電話訂貨', auth.uid());
--
--   -- 應該失敗（INSERT 別人分區的，policy 阻擋）
--   INSERT INTO medsec_rule_suggestions (hospital_id, table_name, field_name, suggested_value, suggested_by)
--   VALUES ('<業祕分區外某醫院id>', 'operation_rules', 'order_mode', '電話訂貨', auth.uid());
--
--   -- 應該失敗（suggested_by 偽造別人，policy WITH CHECK 阻擋）
--   INSERT INTO medsec_rule_suggestions (hospital_id, table_name, field_name, suggested_value, suggested_by)
--   VALUES ('<業祕分區某醫院id>', 'operation_rules', 'order_mode', '電話訂貨', '<別人 uuid>');
--
--   reset role;
