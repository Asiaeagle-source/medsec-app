-- ============================================================
-- 12_quote_review_workflow.sql — Sprint 2.5 第一批
-- ============================================================
-- 報價審核工作流:status 擴充 + timeline + advisories
--   + Cindie 採購主檔(交期/庫存,本批「不含成本」)
--
-- ⚠️ 對齊「已部署的 v10」(sql/v2/10_create_quotes.sql Lynn 已跑):
--   medsec_quotes 已有 status text DEFAULT 'draft' CHECK(5 值)
--   + manager_final_total / manager_decision / manager_decided_*。
--   所以「不能」ADD COLUMN status(會 already exists)。
--   本支:remap 舊 status → 新值 → 換 CHECK → 只 ADD 真正新欄。
--   「最終價」直接復用既有 manager_final_total,不另建重複欄。
--
-- 全檔 idempotent,可重跑。無 DROP TABLE / 無 RENAME。
-- ============================================================

-- ---------- 1. medsec_quotes status 擴充 ----------
-- ⚠️ 線上實際的 status CHECK 叫什麼名字不一定(repo v10 是 inline 自動命名
--   medsec_quotes_status_check,但部署上可能叫 quote_status_check)。
--   不要用猜的 DROP，直接「動態找出 medsec_quotes 上所有引用 status 的
--   CHECK 約束，全部 DROP」，才不會因約束名不符而整批失敗。

-- 1a. 動態拆掉舊 status CHECK(不管它叫什麼名字)
DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.medsec_quotes'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.medsec_quotes DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

-- 1b. 已知舊值 remap 成新值
UPDATE public.medsec_quotes SET status = 'pending_review'  WHERE status = 'pending_decision';
UPDATE public.medsec_quotes SET status = 'approved'        WHERE status = 'decided';
UPDATE public.medsec_quotes SET status = 'crm_keyed'       WHERE status = 'sent';
UPDATE public.medsec_quotes SET status = 'cancelled'       WHERE status = 'closed';

-- 1c. 任何無法識別 / NULL 的舊值一律收斂成 draft
--   (否則 1d 的 ADD CONSTRAINT 會被既有不合規列卡住而失敗)
UPDATE public.medsec_quotes
   SET status = 'draft'
 WHERE status IS NULL
    OR status NOT IN ('draft','pending_review','pending_andrew','approved',
       'rejected','crm_keyed','delivered_quote','negotiating','won','lost','cancelled');

-- 1d. 套新 CHECK(11 值)
ALTER TABLE public.medsec_quotes
  ADD CONSTRAINT quote_status_check CHECK (status IN (
    'draft', 'pending_review', 'pending_andrew',
    'approved', 'rejected', 'crm_keyed',
    'delivered_quote', 'negotiating', 'won', 'lost', 'cancelled'
  ));

-- 1e. v10 留的 partial index 還指向已消失的 'pending_decision',改指新狀態
DROP INDEX IF EXISTS public.idx_quotes_status;
CREATE INDEX IF NOT EXISTS idx_quotes_status
  ON public.medsec_quotes(status)
  WHERE status IN ('pending_review', 'pending_andrew');

-- 1c. 只 ADD 真正新欄(最終價沿用 manager_final_total / 拍板人 manager_decided_by)
ALTER TABLE public.medsec_quotes
  ADD COLUMN IF NOT EXISTS submitted_at           timestamptz,
  ADD COLUMN IF NOT EXISTS submitted_by           uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS reviewed_at            timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_by            uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS approved_on_behalf_of  uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS review_notes           text,
  ADD COLUMN IF NOT EXISTS crm_keyed_at           timestamptz,
  ADD COLUMN IF NOT EXISTS crm_voucher_no         text,
  ADD COLUMN IF NOT EXISTS crm_keyed_by           uuid REFERENCES public.profiles(id);

-- ---------- 2. Quote 時間軸 (audit log) ----------
CREATE TABLE IF NOT EXISTS public.medsec_quote_timeline (
  id            bigserial PRIMARY KEY,
  quote_id      uuid REFERENCES public.medsec_quotes(id) ON DELETE CASCADE,
  event_at      timestamptz NOT NULL DEFAULT now(),
  event_type    text NOT NULL,        -- submitted / approved / rejected / approved_on_behalf / requested_andrew / crm_keyed / status_change
  actor_id      uuid REFERENCES public.profiles(id),
  on_behalf_of  uuid REFERENCES public.profiles(id),
  from_status   text,
  to_status     text,
  notes         text,
  data          jsonb
);
CREATE INDEX IF NOT EXISTS idx_qtl_quote ON public.medsec_quote_timeline(quote_id, event_at);

-- status 變動自動補一筆 timeline(後端保證,不靠前端)
CREATE OR REPLACE FUNCTION public.medsec_quote_status_timeline()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.medsec_quote_timeline
      (quote_id, event_type, actor_id, from_status, to_status)
    VALUES
      (NEW.id, 'status_change', auth.uid(), OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_quote_status_timeline ON public.medsec_quotes;
CREATE TRIGGER trg_quote_status_timeline
  AFTER UPDATE ON public.medsec_quotes
  FOR EACH ROW EXECUTE FUNCTION public.medsec_quote_status_timeline();

-- ---------- 3. Cindie 採購警示 ----------
CREATE TABLE IF NOT EXISTS public.medsec_quote_advisories (
  id              bigserial PRIMARY KEY,
  quote_id        uuid REFERENCES public.medsec_quotes(id) ON DELETE CASCADE,
  quote_item_id   uuid,
  advisor_id      uuid REFERENCES public.profiles(id),
  advisory_type   text,               -- delivery_risk / product_discontinued / low_stock / margin_warning(第二批才用) / other
  severity        text DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'critical')),
  message         text,
  data            jsonb,              -- 交期 / 庫存量 / 替代品號 …(本批不放成本)
  acknowledged_by uuid REFERENCES public.profiles(id),
  acknowledged_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qadv_quote ON public.medsec_quote_advisories(quote_id);

-- ---------- 4. Cindie 採購主檔 (交期 / 庫存 / 停產;本批無成本) ----------
CREATE TABLE IF NOT EXISTS public.medsec_product_procurement (
  product_code         text PRIMARY KEY,      -- → medsec_products.id (不設硬 FK,避開未匹配品號)
  factory_lead_time_days int,
  stock_qty            numeric,
  is_discontinued      boolean DEFAULT false,
  replacement_code     text,
  supplier_note        text,
  updated_by           uuid REFERENCES public.profiles(id),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.touch_procurement_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS trg_procurement_updated ON public.medsec_product_procurement;
CREATE TRIGGER trg_procurement_updated
  BEFORE UPDATE ON public.medsec_product_procurement
  FOR EACH ROW EXECUTE FUNCTION public.touch_procurement_updated_at();

-- ---------- 5. helper ----------
-- Andrew = 0001 林群雄(老闆,不登入主 app)。profiles 若已有 0001 列就回它的 id。
-- 沒有就回 NULL → 代記 Andrew 時 on_behalf_of 留 NULL,細節仍寫進 timeline.notes/data,
-- audit trail 不漏。Lynn 要確保 0001 在 profiles(60 人 seed 通常已含老闆)。
CREATE OR REPLACE FUNCTION public.andrew_profile_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.profiles WHERE employee_id = '0001' LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION public.andrew_profile_id() TO authenticated;

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.medsec_quote_timeline   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medsec_quote_advisories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medsec_product_procurement ENABLE ROW LEVEL SECURITY;

-- timeline:報價相關三角色可讀;寫只走 trigger / edge(service role),前端不直寫
DROP POLICY IF EXISTS qtl_read ON public.medsec_quote_timeline;
CREATE POLICY qtl_read ON public.medsec_quote_timeline
  FOR SELECT TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'secretary', 'bidding_team', 'purchasing'));
DROP POLICY IF EXISTS qtl_write ON public.medsec_quote_timeline;
CREATE POLICY qtl_write ON public.medsec_quote_timeline
  FOR INSERT TO authenticated
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'secretary'));

-- advisories:Cindie(purchasing)+ Lynn(manager) 可讀寫;業祕看不到
-- (避免業祕看到「停產」直接告訴業務,擾亂議價 — spec 決策 2)
DROP POLICY IF EXISTS qadv_rw ON public.medsec_quote_advisories;
CREATE POLICY qadv_rw ON public.medsec_quote_advisories
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'purchasing'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'purchasing'));

-- 採購主檔:Cindie 寫,Cindie/Lynn 讀
DROP POLICY IF EXISTS proc_rw ON public.medsec_product_procurement;
CREATE POLICY proc_rw ON public.medsec_product_procurement
  FOR ALL TO authenticated
  USING (public.auth_medsec_role() IN ('manager', 'purchasing'))
  WITH CHECK (public.auth_medsec_role() IN ('manager', 'purchasing'));

-- medsec_quotes:v10 的 quotes_rw(manager/secretary/bidding_team FOR ALL)保留。
-- 補一條讓 purchasing(Cindie)能「讀」報價(看品項/標價寫 advisory 用)。
-- 注意:PG RLS 是列級不是欄級,無法只擋 manager_final_total 單欄。
-- spec「業祕 draft 看不到 manager_final_total」本批用「前端不顯示 + 第二批
-- Cindie 遮罩 RPC」落實,RLS 不假裝做到欄級遮罩(誠實標註)。
DROP POLICY IF EXISTS quotes_purchasing_read ON public.medsec_quotes;
CREATE POLICY quotes_purchasing_read ON public.medsec_quotes
  FOR SELECT TO authenticated
  USING (public.auth_medsec_role() = 'purchasing');

-- quote_items 也讓 purchasing 讀(Cindie 看品項)
DROP POLICY IF EXISTS quote_items_purchasing_read ON public.medsec_quote_items;
CREATE POLICY quote_items_purchasing_read ON public.medsec_quote_items
  FOR SELECT TO authenticated
  USING (public.auth_medsec_role() = 'purchasing');

COMMENT ON TABLE public.medsec_quote_timeline IS
  'Sprint2.5 報價審核 audit:submitted/approved/rejected/approved_on_behalf/requested_andrew/crm_keyed/status_change';
COMMENT ON TABLE public.medsec_quote_advisories IS
  'Sprint2.5 Cindie 採購警示(本批交期/庫存/停產,無成本)。業祕無權讀。';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. status CHECK 換好:
--    SELECT conname FROM pg_constraint WHERE conname='quote_status_check';
-- 2. 新欄在:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name='medsec_quotes' AND column_name IN
--      ('submitted_at','reviewed_by','approved_on_behalf_of','crm_voucher_no');
-- 3. 三表 + policy:
--    SELECT tablename, count(*) FROM pg_policies WHERE tablename IN
--      ('medsec_quote_timeline','medsec_quote_advisories','medsec_product_procurement')
--    GROUP BY tablename;
-- 4. 舊狀態已 remap:SELECT DISTINCT status FROM medsec_quotes;  -- 應全在 11 值內
