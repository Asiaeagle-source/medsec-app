-- ============================================================
-- 14_cindie_maintenance.sql — Sprint 2.5 補強
-- ============================================================
-- Cindie 產品交期 / 庫存·停產 維護主檔(Lynn 馬上要灌真實 Excel)。
-- 寫入權限走 auth_can_maintain():Lynn(manager,全域職代)+
-- Cindie(purchasing)可讀寫,其他人整列擋。
-- 全檔 idempotent,可重跑。無 DROP TABLE / 無 RENAME。
-- ============================================================

-- ---------- 全域職代 / 維護權限判定 ----------
-- Lynn = manager → 任何維護表都可(全域職代)
-- Cindie = purchasing → 採購相關主檔可
-- 其他角色 → 一律 false
CREATE OR REPLACE FUNCTION public.auth_can_maintain(p_table text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN public.auth_medsec_role() = 'manager' THEN true
    WHEN public.auth_medsec_role() = 'purchasing'
         AND p_table IN ('medsec_product_delivery',
                          'medsec_product_inventory',
                          'medsec_product_procurement') THEN true
    ELSE false
  END
$$;
GRANT EXECUTE ON FUNCTION public.auth_can_maintain(text) TO authenticated;

-- ---------- 產品交期 ----------
CREATE TABLE IF NOT EXISTS public.medsec_product_delivery (
  product_code            text PRIMARY KEY,
  product_name            text,
  standard_lead_time_days int,
  stock_lead_time_days    int,
  is_delayed              boolean DEFAULT false,
  delay_reason            text,
  expected_recovery_date  date,
  updated_by              uuid REFERENCES public.profiles(id),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- ---------- 產品庫存 / 停產 ----------
CREATE TABLE IF NOT EXISTS public.medsec_product_inventory (
  product_code            text PRIMARY KEY,
  product_name            text,
  current_stock_qty       numeric,
  safety_stock_level      numeric,
  stock_status            text DEFAULT 'normal'
    CHECK (stock_status IN ('normal', 'low', 'out', 'discontinued')),
  is_discontinued         boolean DEFAULT false,
  replacement_product_code text,
  updated_by              uuid REFERENCES public.profiles(id),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- ---------- updated_at trigger(沿用 12 的通用 touch)----------
CREATE OR REPLACE FUNCTION public.touch_procurement_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS trg_delivery_updated ON public.medsec_product_delivery;
CREATE TRIGGER trg_delivery_updated
  BEFORE UPDATE ON public.medsec_product_delivery
  FOR EACH ROW EXECUTE FUNCTION public.touch_procurement_updated_at();

DROP TRIGGER IF EXISTS trg_inventory_updated ON public.medsec_product_inventory;
CREATE TRIGGER trg_inventory_updated
  BEFORE UPDATE ON public.medsec_product_inventory
  FOR EACH ROW EXECUTE FUNCTION public.touch_procurement_updated_at();

-- ---------- RLS:Cindie + Lynn 可讀寫,其他人整列擋 ----------
ALTER TABLE public.medsec_product_delivery  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medsec_product_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delivery_maintain ON public.medsec_product_delivery;
CREATE POLICY delivery_maintain ON public.medsec_product_delivery
  FOR ALL TO authenticated
  USING (public.auth_can_maintain('medsec_product_delivery'))
  WITH CHECK (public.auth_can_maintain('medsec_product_delivery'));

DROP POLICY IF EXISTS inventory_maintain ON public.medsec_product_inventory;
CREATE POLICY inventory_maintain ON public.medsec_product_inventory
  FOR ALL TO authenticated
  USING (public.auth_can_maintain('medsec_product_inventory'))
  WITH CHECK (public.auth_can_maintain('medsec_product_inventory'));

COMMENT ON TABLE public.medsec_product_delivery IS
  'Sprint2.5 補強 Cindie 產品交期主檔。寫入 = auth_can_maintain(Lynn+Cindie)';
COMMENT ON TABLE public.medsec_product_inventory IS
  'Sprint2.5 補強 Cindie 產品庫存/停產主檔。寫入 = auth_can_maintain(Lynn+Cindie)';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. SELECT public.auth_can_maintain('medsec_product_delivery');  -- Lynn/Cindie → t
-- 2. SELECT tablename, policyname FROM pg_policies
--    WHERE tablename IN ('medsec_product_delivery','medsec_product_inventory');
-- 3. \d medsec_product_delivery / medsec_product_inventory  -- 欄位齊
