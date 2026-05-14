-- ============================================================
-- 01_alter_medsec_cases.sql — Lynn V3.3 拍板
-- ============================================================
-- 動工順序 Step 1-4：補 4 欄、補約束、改 status enum、建函數 + trigger
--
-- 對應 §9 Q2 + Q3 + Q5 (sop_ref)
-- 套用順序：在既有 22 張表 schema 之後，不動既有 RLS
-- ============================================================

-- ============================================================
-- Step 1 · 補 4 個新欄位
-- ============================================================
ALTER TABLE public.medsec_cases ADD COLUMN IF NOT EXISTS company      text;
ALTER TABLE public.medsec_cases ADD COLUMN IF NOT EXISTS action_type  text;
ALTER TABLE public.medsec_cases ADD COLUMN IF NOT EXISTS erp_doc_code text;
ALTER TABLE public.medsec_cases ADD COLUMN IF NOT EXISTS sop_ref      text;

COMMENT ON COLUMN public.medsec_cases.company
  IS 'V3.3 AE=雄鷹 / LD=君華';
COMMENT ON COLUMN public.medsec_cases.action_type
  IS 'V3.3 13 種 enum：coding/quote/surplus/budget/renewal/urgent/amortize/negotiate/tender_supply/tender_equipment/borrow/repair_quote/maintenance';
COMMENT ON COLUMN public.medsec_cases.erp_doc_code
  IS 'V3.3 鼎新 4 碼。trigger 從 (company, action_type) 自動帶；秘書可改 (AECO→AEEQ/AEIN)';
COMMENT ON COLUMN public.medsec_cases.sop_ref
  IS 'V3.3 WIS01~WIS10 或 NULL。trigger 從 action_type 自動帶；給前端 SOP 提示卡用';

-- ============================================================
-- Step 2 · company 約束
-- ============================================================
ALTER TABLE public.medsec_cases DROP CONSTRAINT IF EXISTS medsec_cases_company_check;
ALTER TABLE public.medsec_cases ADD CONSTRAINT medsec_cases_company_check
  CHECK (company IS NULL OR company IN ('AE','LD'));

-- ============================================================
-- Step 3 · action_type 約束（13 種）
-- ============================================================
ALTER TABLE public.medsec_cases DROP CONSTRAINT IF EXISTS medsec_cases_action_type_check;
ALTER TABLE public.medsec_cases ADD CONSTRAINT medsec_cases_action_type_check
  CHECK (action_type IS NULL OR action_type IN (
    'coding', 'quote', 'surplus', 'budget', 'renewal', 'urgent',
    'amortize', 'negotiate', 'tender_supply', 'tender_equipment',
    'borrow', 'repair_quote', 'maintenance'
  ));

-- ============================================================
-- Step 4 · status enum 補 returned + pending_supplement
-- ============================================================
-- 既有 enum 是 7 個（pending/claimed/packaging/pending_decision/decided/crm_sent/closed）
-- V3.3 補 2 個（returned/pending_supplement）→ 共 9 個
ALTER TABLE public.medsec_cases DROP CONSTRAINT IF EXISTS medsec_cases_status_check;
ALTER TABLE public.medsec_cases ADD CONSTRAINT medsec_cases_status_check
  CHECK (status IN (
    'pending', 'claimed', 'packaging',
    'pending_decision', 'decided', 'crm_sent', 'closed',
    'returned', 'pending_supplement'
  ));

-- ============================================================
-- Step 5 · erp_doc_code 對映函數（25 種映射，maintenance LD 不存在）
-- ============================================================
CREATE OR REPLACE FUNCTION public.calc_erp_doc_code(p_company text, p_action_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_company = 'AE' AND p_action_type = 'coding'           THEN 'AECC'
    WHEN p_company = 'LD' AND p_action_type = 'coding'           THEN 'LDCC'
    WHEN p_company = 'AE' AND p_action_type = 'quote'            THEN 'AECO'  -- V1 預設耗材；secretary 可改 AEEQ/AEIN
    WHEN p_company = 'LD' AND p_action_type = 'quote'            THEN 'LDCO'
    WHEN p_company = 'AE' AND p_action_type = 'surplus'          THEN 'AEBA'
    WHEN p_company = 'LD' AND p_action_type = 'surplus'          THEN 'LDBA'
    WHEN p_company = 'AE' AND p_action_type = 'budget'           THEN 'AEBU'
    WHEN p_company = 'LD' AND p_action_type = 'budget'           THEN 'LDBU'
    WHEN p_company = 'AE' AND p_action_type = 'renewal'          THEN 'AENE'
    WHEN p_company = 'LD' AND p_action_type = 'renewal'          THEN 'LDNE'
    WHEN p_company = 'AE' AND p_action_type = 'urgent'           THEN 'AESP'
    WHEN p_company = 'LD' AND p_action_type = 'urgent'           THEN 'LDSP'
    WHEN p_company = 'AE' AND p_action_type = 'amortize'         THEN 'AETT'
    WHEN p_company = 'LD' AND p_action_type = 'amortize'         THEN 'ALTT'
    WHEN p_company = 'AE' AND p_action_type = 'negotiate'        THEN 'AEYJ'
    WHEN p_company = 'LD' AND p_action_type = 'negotiate'        THEN 'LDYJ'
    WHEN p_company = 'AE' AND p_action_type = 'tender_supply'    THEN 'AEDB'
    WHEN p_company = 'LD' AND p_action_type = 'tender_supply'    THEN 'ALDB'
    WHEN p_company = 'AE' AND p_action_type = 'tender_equipment' THEN 'AEEB'
    WHEN p_company = 'LD' AND p_action_type = 'tender_equipment' THEN 'ALEB'
    WHEN p_company = 'AE' AND p_action_type = 'borrow'           THEN 'AEOP'
    WHEN p_company = 'LD' AND p_action_type = 'borrow'           THEN 'LDOP'
    WHEN p_company = 'AE' AND p_action_type = 'repair_quote'     THEN 'AERM'
    WHEN p_company = 'LD' AND p_action_type = 'repair_quote'     THEN 'LDRM'
    WHEN p_company = 'AE' AND p_action_type = 'maintenance'      THEN 'AEMT'
    ELSE NULL                                                     -- LD maintenance 不存在
  END
$$;

COMMENT ON FUNCTION public.calc_erp_doc_code(text, text)
  IS 'V3.3 (company, action_type) → 鼎新 4 碼。13×2-1=25 種映射，LD+maintenance 不存在。';

-- ============================================================
-- Step 6 · sop_ref 對映函數
-- ============================================================
CREATE OR REPLACE FUNCTION public.calc_sop_ref(p_action_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_action_type
    WHEN 'coding'           THEN 'WIS01'
    WHEN 'surplus'          THEN 'WIS02'
    WHEN 'budget'           THEN 'WIS02'
    WHEN 'renewal'          THEN 'WIS02'
    WHEN 'urgent'           THEN 'WIS02'
    WHEN 'amortize'         THEN 'WIS02'
    WHEN 'negotiate'        THEN 'WIS06'
    WHEN 'tender_supply'    THEN 'WIS04'
    WHEN 'tender_equipment' THEN 'WIS04'
    WHEN 'borrow'           THEN 'WIS05'
    WHEN 'repair_quote'     THEN 'WIS09'
    WHEN 'maintenance'      THEN 'WIS10'
    ELSE NULL                              -- quote (一般報價) 無對應 SOP
  END
$$;

COMMENT ON FUNCTION public.calc_sop_ref(text)
  IS 'V3.3 action_type → WIS01~WIS10。quote 無對應 SOP。';

-- ============================================================
-- Step 7 · BEFORE INSERT/UPDATE trigger — 自動帶 erp_doc_code / sop_ref / case_no
-- ============================================================
-- Lynn 拍板：trigger 不用 generated column，要保留 secretary 改 erp_doc_code 餘地
CREATE OR REPLACE FUNCTION public.medsec_cases_autofill()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_today_max int;
  v_today_str text;
BEGIN
  -- erp_doc_code：INSERT 時 NULL 且 (company, action_type) 有值才自動帶。
  -- UPDATE 不重算，保留 secretary 改 AECO→AEEQ/AEIN 的餘地。
  IF TG_OP = 'INSERT'
     AND NEW.erp_doc_code IS NULL
     AND NEW.company IS NOT NULL
     AND NEW.action_type IS NOT NULL THEN
    NEW.erp_doc_code := public.calc_erp_doc_code(NEW.company, NEW.action_type);
  END IF;

  -- sop_ref：INSERT 時帶，或 UPDATE 改 action_type 時重算（SOP 對應的是 action_type 不是 erp_doc_code）
  IF TG_OP = 'INSERT'
     OR (TG_OP = 'UPDATE' AND NEW.action_type IS DISTINCT FROM OLD.action_type) THEN
    NEW.sop_ref := public.calc_sop_ref(NEW.action_type);
  END IF;

  -- case_no：INSERT 時 NULL 且 erp_doc_code 有值，自動產 {erp_doc_code}-{YYMMDD}-{NNN}
  -- 流水號從同 (erp_doc_code, 日期) max + 1 開始
  IF TG_OP = 'INSERT'
     AND NEW.case_no IS NULL
     AND NEW.erp_doc_code IS NOT NULL THEN
    v_today_str := to_char(now() AT TIME ZONE 'Asia/Taipei', 'YYMMDD');

    SELECT COALESCE(MAX(CAST(SUBSTRING(case_no FROM '\d{3}$') AS int)), 0)
      INTO v_today_max
      FROM public.medsec_cases
     WHERE case_no LIKE NEW.erp_doc_code || '-' || v_today_str || '-%';

    NEW.case_no := NEW.erp_doc_code || '-' || v_today_str || '-'
                   || LPAD((v_today_max + 1)::text, 3, '0');
  END IF;

  -- updated_at（若既有沒 trigger 設這個，這裡保險帶）
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.medsec_cases_autofill()
  IS 'V3.3 BEFORE INSERT/UPDATE — 自動帶 erp_doc_code / sop_ref / case_no。Lynn 拍板用 trigger 不用 generated col。';

DROP TRIGGER IF EXISTS medsec_cases_autofill_trg ON public.medsec_cases;
CREATE TRIGGER medsec_cases_autofill_trg
  BEFORE INSERT OR UPDATE ON public.medsec_cases
  FOR EACH ROW EXECUTE FUNCTION public.medsec_cases_autofill();

-- ============================================================
-- 驗證
-- ============================================================
-- (1) 4 欄都存在
-- select column_name from information_schema.columns
-- where table_schema='public' and table_name='medsec_cases'
--   and column_name in ('company','action_type','erp_doc_code','sop_ref');
-- → 應該回 4 列

-- (2) 函數試算
-- select public.calc_erp_doc_code('AE','coding');           -- AECC
-- select public.calc_erp_doc_code('LD','tender_supply');    -- ALDB
-- select public.calc_erp_doc_code('LD','maintenance');      -- NULL
-- select public.calc_sop_ref('coding');                     -- WIS01
-- select public.calc_sop_ref('quote');                      -- NULL

-- (3) INSERT 試跑（記得 RLS 你要先有 manager / sales 身份；以下假設 manager）
-- insert into public.medsec_cases (case_type, title, status, company, action_type, hospital_id)
-- values ('inquiry','測試案件','pending','AE','coding','TNH')
-- returning case_no, erp_doc_code, sop_ref;
-- → case_no = AECC-260513-001, erp_doc_code = AECC, sop_ref = WIS01
