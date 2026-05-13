-- ============================================================
-- 03_consignment_inventory.sql — Lynn V3.3 新增寄售品庫存（WIS07）
-- ============================================================
-- 對應 §9 Q6 (A)
-- 一家+一品號 UNIQUE。RLS: manager+secretary 全看、sales 只看自己分區。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_consignment_inventory (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id         text    NOT NULL REFERENCES public.medsec_hospitals(id),
  product_code        text    NOT NULL REFERENCES public.medsec_products(id),

  stock_qty           integer NOT NULL DEFAULT 0,
  monthly_avg_usage   numeric,                              -- 月均使用量（盤點時填）
  earliest_expiry     date,                                 -- 最早效期（觸發換貨用）

  last_inventory_date date,                                 -- 上次盤點日
  last_inventory_by   uuid    REFERENCES public.profiles(id),

  status              text    NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','expiring','returned')),
  notes               text,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  UNIQUE (hospital_id, product_code)
);

CREATE INDEX IF NOT EXISTS mci_hospital_idx ON public.medsec_consignment_inventory(hospital_id);
CREATE INDEX IF NOT EXISTS mci_product_idx  ON public.medsec_consignment_inventory(product_code);
CREATE INDEX IF NOT EXISTS mci_expiry_idx   ON public.medsec_consignment_inventory(earliest_expiry)
  WHERE earliest_expiry IS NOT NULL;
CREATE INDEX IF NOT EXISTS mci_status_idx   ON public.medsec_consignment_inventory(status);

-- updated_at trigger（用 lvZzm 已建的 touch_updated_at function）
DROP TRIGGER IF EXISTS mci_updated_at ON public.medsec_consignment_inventory;
CREATE TRIGGER mci_updated_at BEFORE UPDATE ON public.medsec_consignment_inventory
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

COMMENT ON TABLE public.medsec_consignment_inventory
  IS 'V3.3 寄售品庫存（WIS07）。一家+一品號 UNIQUE。RLS: manager+secretary 全看，sales 只看自己分區。';

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.medsec_consignment_inventory ENABLE ROW LEVEL SECURITY;

-- SELECT：manager + secretary 全看；sales 透過 medsec_salesperson_assignments 看自己分區
DROP POLICY IF EXISTS mci_select ON public.medsec_consignment_inventory;
CREATE POLICY mci_select ON public.medsec_consignment_inventory
  FOR SELECT TO authenticated USING (
    public.auth_medsec_role() IN ('manager','secretary')
    OR EXISTS (
      SELECT 1 FROM public.medsec_salesperson_assignments
      WHERE hospital_id    = medsec_consignment_inventory.hospital_id
        AND salesperson_id = auth.uid()
    )
  );

-- WRITE：只 manager + secretary（業務不可改盤點）
DROP POLICY IF EXISTS mci_write ON public.medsec_consignment_inventory;
CREATE POLICY mci_write ON public.medsec_consignment_inventory
  FOR ALL TO authenticated
  USING      (public.auth_medsec_role() IN ('manager','secretary'))
  WITH CHECK (public.auth_medsec_role() IN ('manager','secretary'));

-- ============================================================
-- 驗證
-- ============================================================
-- select count(*) from public.medsec_consignment_inventory;  -- 0
-- select tablename, rowsecurity from pg_tables
--   where schemaname='public' and tablename='medsec_consignment_inventory';
-- → rls_enabled=true
-- select policyname, cmd from pg_policies
--   where schemaname='public' and tablename='medsec_consignment_inventory';
-- → 2 policy (mci_select, mci_write)
