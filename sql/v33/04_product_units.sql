-- ============================================================
-- 04_product_units.sql — Lynn V3.3 新增單台序號保固（WIS09）
-- ============================================================
-- 對應 §9 Q6 (B)
-- serial_no UNIQUE。RLS: manager+secretary 全看、sales 只看自己分區醫院的設備。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_product_units (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_code        text NOT NULL REFERENCES public.medsec_products(id),
  serial_no           text NOT NULL UNIQUE,                 -- 製造商序號（單機）
  hospital_id         text REFERENCES public.medsec_hospitals(id),

  warranty_start      date,                                 -- 保固起日（出貨/驗收日）
  warranty_end        date,                                 -- 保固迄日
  warranty_alert_days integer DEFAULT 30,                   -- 幾天前提醒

  status              text NOT NULL DEFAULT 'in_use'
    CHECK (status IN ('in_use','returned','replaced','scrapped')),
  install_case_id     uuid REFERENCES public.medsec_cases(id),  -- 首次安裝那個案件（WIS08 來）

  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mpu_product_idx      ON public.medsec_product_units(product_code);
CREATE INDEX IF NOT EXISTS mpu_hospital_idx     ON public.medsec_product_units(hospital_id);
CREATE INDEX IF NOT EXISTS mpu_warranty_end_idx ON public.medsec_product_units(warranty_end)
  WHERE warranty_end IS NOT NULL;
CREATE INDEX IF NOT EXISTS mpu_status_idx       ON public.medsec_product_units(status);

DROP TRIGGER IF EXISTS mpu_updated_at ON public.medsec_product_units;
CREATE TRIGGER mpu_updated_at BEFORE UPDATE ON public.medsec_product_units
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

COMMENT ON TABLE public.medsec_product_units
  IS 'V3.3 單台序號保固（WIS09）。serial_no UNIQUE。可用 medsec_product_units_warranty view 一查就分流 in/out warranty。';

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.medsec_product_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mpu_select ON public.medsec_product_units;
CREATE POLICY mpu_select ON public.medsec_product_units
  FOR SELECT TO authenticated USING (
    public.auth_medsec_role() IN ('manager','secretary')
    OR (
      hospital_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.medsec_salesperson_assignments
        WHERE hospital_id    = medsec_product_units.hospital_id
          AND salesperson_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS mpu_write ON public.medsec_product_units;
CREATE POLICY mpu_write ON public.medsec_product_units
  FOR ALL TO authenticated
  USING      (public.auth_medsec_role() IN ('manager','secretary'))
  WITH CHECK (public.auth_medsec_role() IN ('manager','secretary'));

-- ============================================================
-- 查保固便利 view（WIS09 自動分流 in/out warranty）
-- ============================================================
CREATE OR REPLACE VIEW public.medsec_product_units_warranty AS
SELECT
  u.id,
  u.serial_no,
  u.product_code,
  p.name           AS product_name,
  p.specification  AS product_spec,
  u.hospital_id,
  u.warranty_start,
  u.warranty_end,
  (u.warranty_end - CURRENT_DATE) AS days_left,
  CASE
    WHEN u.warranty_end IS NULL THEN 'unknown'
    WHEN u.warranty_end >= CURRENT_DATE THEN 'in_warranty'
    ELSE 'out_of_warranty'
  END AS warranty_status,
  u.status,
  u.install_case_id
FROM public.medsec_product_units u
LEFT JOIN public.medsec_products p ON p.id = u.product_code;

COMMENT ON VIEW public.medsec_product_units_warranty
  IS 'V3.3 WIS09 查保固便利 view。直接 select 看 warranty_status: in_warranty/out_of_warranty/unknown';

-- ============================================================
-- 驗證
-- ============================================================
-- (1) 表 + 2 policy + view 都建好
-- select tablename from pg_tables where schemaname='public' and tablename='medsec_product_units';
-- select policyname from pg_policies where schemaname='public' and tablename='medsec_product_units';
-- select viewname from pg_views where schemaname='public' and viewname='medsec_product_units_warranty';

-- (2) WIS09 查保固範例
-- select * from public.medsec_product_units_warranty where serial_no = 'XYZ123';
-- → warranty_status 直接告訴你 in_warranty / out_of_warranty
