-- ============================================================
-- 15_inventory_unified.sql — Sprint 2.5 補強(單一整併版,正典)
-- ============================================================
-- 取代舊 15_inventory_schema_v2.sql(已刪)。整併「採購狀態 + 庫存」
-- 進 medsec_product_inventory,對齊 Lynn 給 Cindie 的真實 Excel
-- (該表沒有「原廠交期」,故 cindie-delivery 暫不接 nav)。
--
-- 全檔 idempotent,可重跑;即使先前已跑過舊 v2 也安全。
-- 不刪 current_stock_qty / safety_stock_level / stock_status
--   (向後相容;stock_status 仍可由 Cindie 手動 override)。
-- 無 DROP TABLE / 無 RENAME。medsec_product_delivery 保留不動。
-- ============================================================

-- ---------- 1. 加欄(對齊真實 Excel + 停產/安全庫存資訊)----------
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN IF NOT EXISTS product_category     text,
  ADD COLUMN IF NOT EXISTS overdue_inbound_qty  integer,   -- 逾期未進貨
  ADD COLUMN IF NOT EXISTS pending_inbound_qty  integer,   -- 待進貨數量
  ADD COLUMN IF NOT EXISTS pending_purchase_qty integer,   -- 採購未確認
  ADD COLUMN IF NOT EXISTS monthly_avg_sales    numeric,   -- 月均銷(關鍵)
  ADD COLUMN IF NOT EXISTS available_months     numeric,   -- 可用月數(Excel 已算)
  ADD COLUMN IF NOT EXISTS last_excel_update    timestamptz,-- 最後一次 Excel 匯入時間
  ADD COLUMN IF NOT EXISTS safety_stock_months  numeric DEFAULT 2,
  ADD COLUMN IF NOT EXISTS discontinue_date     date,
  ADD COLUMN IF NOT EXISTS notes                text;

-- ---------- 2. generated columns ----------
-- 舊版 stock_status_auto 一併移除,改用 effective_supply + stock_alert_level
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS stock_status_auto;
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS effective_supply;
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS stock_alert_level;

-- 有效供應 = 逾期未進貨 + 現有數(這批逾期會到貨,算進供應)
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN effective_supply numeric GENERATED ALWAYS AS (
    COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0)
  ) STORED;

-- 缺貨等級(PG 不允許 generated 引用另一 generated,故 sum 內聯)
--   ⚫ discontinued
--   🔴 critical : 有效供應 = 0 且 有在賣          → 嚴重缺貨
--   🟠 low      : 有效供應 < 月均銷               → 不到 1 月
--   🟡 warning  : 有效供應 < 月均銷 × 2           → 不到 2 月
--   🟢 normal   : 其他
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN stock_alert_level text GENERATED ALWAYS AS (
    CASE
      WHEN is_discontinued THEN 'discontinued'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0) = 0
           AND COALESCE(monthly_avg_sales, 0) > 0
        THEN 'critical'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0)
           < COALESCE(monthly_avg_sales, 0)
        THEN 'low'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0)
           < COALESCE(monthly_avg_sales, 0) * 2
        THEN 'warning'
      ELSE 'normal'
    END
  ) STORED;

-- ---------- 3. 報價送審 → 自動缺貨 / 停產警示 ----------
-- 業祕把報價送 Lynn(status → pending_review)時逐品項查 inventory:
--   stock_alert_level in (critical,low) → low_stock 警示
--   is_discontinued                     → product_discontinued 警示
-- 去重:同 quote_item + 同 type 已有 auto 警示就不重插。
CREATE OR REPLACE FUNCTION public.medsec_quote_autostock_advisory()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it  record;
  inv record;
BEGIN
  IF NEW.status = 'pending_review'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    FOR it IN
      SELECT id, product_code FROM public.medsec_quote_items
      WHERE quote_id = NEW.id AND product_code IS NOT NULL
    LOOP
      SELECT * INTO inv FROM public.medsec_product_inventory
        WHERE product_code = it.product_code;
      IF NOT FOUND THEN CONTINUE; END IF;

      -- 缺貨
      IF inv.stock_alert_level IN ('critical', 'low')
         AND NOT EXISTS (
           SELECT 1 FROM public.medsec_quote_advisories
           WHERE quote_item_id = it.id AND advisory_type = 'low_stock'
             AND data ->> 'auto' = 'true') THEN
        INSERT INTO public.medsec_quote_advisories
          (quote_id, quote_item_id, advisor_id, advisory_type, severity, message, data)
        VALUES (
          NEW.id, it.id, NULL, 'low_stock',
          CASE inv.stock_alert_level WHEN 'critical' THEN 'critical' ELSE 'warning' END,
          it.product_code || ' 有效供應 ' || inv.effective_supply
            || '(逾期 ' || COALESCE(inv.overdue_inbound_qty, 0)
            || ' + 現有 ' || COALESCE(inv.current_stock_qty, 0) || ')'
            || ' < 月均銷 ' || COALESCE(inv.monthly_avg_sales, 0)
            || ' → ' || CASE inv.stock_alert_level
                          WHEN 'critical' THEN '嚴重缺貨' ELSE '即將缺貨' END,
          jsonb_build_object('auto', 'true',
            'effective_supply', inv.effective_supply,
            'overdue_inbound_qty', inv.overdue_inbound_qty,
            'current_stock_qty', inv.current_stock_qty,
            'monthly_avg_sales', inv.monthly_avg_sales,
            'stock_alert_level', inv.stock_alert_level));
      END IF;

      -- 停產
      IF inv.is_discontinued
         AND NOT EXISTS (
           SELECT 1 FROM public.medsec_quote_advisories
           WHERE quote_item_id = it.id AND advisory_type = 'product_discontinued'
             AND data ->> 'auto' = 'true') THEN
        INSERT INTO public.medsec_quote_advisories
          (quote_id, quote_item_id, advisor_id, advisory_type, severity, message, data)
        VALUES (
          NEW.id, it.id, NULL, 'product_discontinued', 'critical',
          it.product_code || ' 已停產'
            || CASE WHEN inv.replacement_product_code IS NOT NULL
                    THEN ',替代:' || inv.replacement_product_code ELSE '' END,
          jsonb_build_object('auto', 'true',
            'replacement_product_code', inv.replacement_product_code,
            'discontinue_date', inv.discontinue_date));
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_quote_autostock_advisory ON public.medsec_quotes;
CREATE TRIGGER trg_quote_autostock_advisory
  AFTER INSERT OR UPDATE OF status ON public.medsec_quotes
  FOR EACH ROW EXECUTE FUNCTION public.medsec_quote_autostock_advisory();

COMMENT ON COLUMN public.medsec_product_inventory.effective_supply IS
  'GENERATED:逾期未進貨 + 現有數';
COMMENT ON COLUMN public.medsec_product_inventory.stock_alert_level IS
  'GENERATED:依 有效供應 vs 月均銷 自動推導,Cindie 不可手寫';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. SELECT column_name,is_generated FROM information_schema.columns
--    WHERE table_name='medsec_product_inventory'
--      AND column_name IN ('effective_supply','stock_alert_level',
--        'last_excel_update','safety_stock_months');
-- 2. 推導:overdue120 current7 monthly9.14 → eff127 ≥ 18.28 → 'normal'(不誤報)
--    overdue0 current0 monthly45.5 → 'critical' ; overdue3 current0 monthly45.5 → 'low'
-- 3. trigger:報價 status→pending_review,缺貨/停產品項自動進 advisories
