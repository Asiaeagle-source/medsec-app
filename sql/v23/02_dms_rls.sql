-- ============================================================
-- V2.3 DMS · 02 RLS(只產出,交 Lynn 審後執行)
-- ------------------------------------------------------------
-- 四張表一律:auth_can_dms()(has_dms_access 或 manager/accounting)才能讀寫。
-- 需先跑 01(auth_can_dms 函式在那)。
-- ============================================================

ALTER TABLE public.consignment_sales     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recon_statements       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recon_statement_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_code_map      ENABLE ROW LEVEL SECURITY;

-- consignment_sales
DROP POLICY IF EXISTS dms_consignment_sales_all ON public.consignment_sales;
CREATE POLICY dms_consignment_sales_all ON public.consignment_sales
  FOR ALL TO authenticated
  USING (public.auth_can_dms()) WITH CHECK (public.auth_can_dms());

-- recon_statements
DROP POLICY IF EXISTS dms_recon_statements_all ON public.recon_statements;
CREATE POLICY dms_recon_statements_all ON public.recon_statements
  FOR ALL TO authenticated
  USING (public.auth_can_dms()) WITH CHECK (public.auth_can_dms());

-- recon_statement_items
DROP POLICY IF EXISTS dms_recon_statement_items_all ON public.recon_statement_items;
CREATE POLICY dms_recon_statement_items_all ON public.recon_statement_items
  FOR ALL TO authenticated
  USING (public.auth_can_dms()) WITH CHECK (public.auth_can_dms());

-- material_code_map
DROP POLICY IF EXISTS dms_material_code_map_all ON public.material_code_map;
CREATE POLICY dms_material_code_map_all ON public.material_code_map
  FOR ALL TO authenticated
  USING (public.auth_can_dms()) WITH CHECK (public.auth_can_dms());

-- ============================================================
-- 驗證(manager / has_dms_access session 應可 select;無權者回 0 列):
--   SELECT count(*) FROM public.material_code_map;
-- ============================================================
