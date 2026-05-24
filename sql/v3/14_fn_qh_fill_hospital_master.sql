-- ============================================================
-- sql/v3/14_fn_qh_fill_hospital_master.sql
-- CRM 全覆蓋 upsert 後補齊主檔欄
-- ============================================================
-- 用途:crmApply() 的 upsert payload 故意不含
--   hospital_name / system_prefix / region_code / customer_type
-- 以保護 COPI01 同步過來的值。但新增的列(INSERT 路徑)這些欄
-- 會是 NULL,需要從 medsec_hospitals JOIN 帶入。
-- 本函式在 Tab① 每次 crmApply 批次結束後呼叫一次。
--
-- WHERE system_prefix IS NULL:
--   只補從未設過主檔欄的列;已有值的列(COPI01 設過)不動。
--   對不到 medsec_hospitals 的列維持 NULL(spec:不可瞎填)。
--
-- SECURITY DEFINER + 開頭 perm check;只給 edit_pricing 者呼叫。
-- idempotent;多次呼叫只有 NULL 列受影響。
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_qh_fill_hospital_master()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int;
BEGIN
  IF NOT COALESCE(public.auth_can_edit_pricing(), FALSE) THEN RETURN 0; END IF;

  UPDATE public.medsec_quote_history q
  SET
    hospital_name = COALESCE(h.name_short, h.name_full),
    system_prefix = h.system_prefix,
    region_code   = h.region_code,
    customer_type = h.customer_type
  FROM public.medsec_hospitals h
  WHERE q.hospital_id  = h.id
    AND q.system_prefix IS NULL;   -- 只補 NULL;COPI01 已設的值不動

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION public.fn_qh_fill_hospital_master() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 驗證
-- ============================================================
-- 呼叫:SELECT public.fn_qh_fill_hospital_master();  -- 回傳補入的列數
-- 補後確認:
--   SELECT count(*) FROM medsec_quote_history WHERE system_prefix IS NULL;
--   -- 應只剩對不到 medsec_hospitals 的醫院代號(真正無法對應)
