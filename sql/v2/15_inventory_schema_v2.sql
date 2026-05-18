-- ============================================================
-- 15_inventory_schema_v2.sql — Sprint 2.5 補強(對齊 Cindie 真實 Excel)
-- ============================================================
-- 在 14 的 medsec_product_inventory 上「加欄」對齊 Cindie 真實格式,
-- 並用 generated column 自動推導缺貨狀態 + 報價送審自動警示。
--
-- 不刪 current_stock_qty / safety_stock_level / stock_status
--   (向後相容;stock_status 仍可由 Cindie 手動 override)。
-- 全檔 idempotent,可重跑。無 DROP TABLE / 無 RENAME。
-- ============================================================

-- ---------- 1. 加欄(對齊真實 Excel)----------
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN IF NOT EXISTS product_category     text,
  ADD COLUMN IF NOT EXISTS overdue_inbound_qty  integer,   -- 逾期未進貨(= 已下單但原廠逾期)
  ADD COLUMN IF NOT EXISTS pending_inbound_qty  integer,   -- 待進貨數量
  ADD COLUMN IF NOT EXISTS pending_purchase_qty integer,   -- 採購未確認
  ADD COLUMN IF NOT EXISTS monthly_avg_sales    numeric,   -- 月均銷(關鍵指標)
  ADD COLUMN IF NOT EXISTS available_months     numeric;   -- 可用月數(Excel 已算)

-- ---------- 2. 自動缺貨判定(generated column)----------
-- 有效供應 effective_supply = 逾期未進貨 + 現有數
--   ⚫ discontinued  : 已停產
--   🔴 out           : 有效供應 = 0 且 有在賣(月均銷 > 0)→ 嚴重缺貨
--   🟠 low           : 有效供應 < 月均銷            → 不到 1 月,即將缺貨
--   🟡 warning       : 有效供應 < 月均銷 × 2        → 不到 2 月,庫存偏低
--   🟢 normal        : 其他
-- GENERATED ALWAYS:Cindie 改任何來源欄,系統自動重算,不可手動寫入。
ALTER TABLE public.medsec_product_inventory
  DROP COLUMN IF EXISTS stock_status_auto;
ALTER TABLE public.medsec_product_inventory
  ADD COLUMN stock_status_auto text GENERATED ALWAYS AS (
    CASE
      WHEN is_discontinued THEN 'discontinued'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0) = 0
           AND COALESCE(monthly_avg_sales, 0) > 0
        THEN 'out'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0)
           < COALESCE(monthly_avg_sales, 0)
        THEN 'low'
      WHEN COALESCE(overdue_inbound_qty, 0) + COALESCE(current_stock_qty, 0)
           < COALESCE(monthly_avg_sales, 0) * 2
        THEN 'warning'
      ELSE 'normal'
    END
  ) STORED;

-- ---------- 3. 報價送審 → 自動寫缺貨警示 ----------
-- 業祕把報價送 Lynn(status → pending_review)時,逐品項查 inventory,
-- stock_status_auto 為 out / low 就自動補一筆 quote_advisory 給 Lynn 看。
-- (warning 不自動補,只在 Cindie 頁顯示;避免雜訊)
-- 去重:同一 quote_item 已有 auto 警示就不重複插。
CREATE OR REPLACE FUNCTION public.medsec_quote_autostock_advisory()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it   record;
  inv  record;
  eff  numeric;
BEGIN
  IF NEW.status = 'pending_review'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    FOR it IN
      SELECT id, product_code FROM public.medsec_quote_items
      WHERE quote_id = NEW.id AND product_code IS NOT NULL
    LOOP
      SELECT * INTO inv FROM public.medsec_product_inventory
        WHERE product_code = it.product_code;
      IF FOUND AND inv.stock_status_auto IN ('out', 'low') THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.medsec_quote_advisories
          WHERE quote_item_id = it.id
            AND advisory_type = 'low_stock'
            AND data ->> 'auto' = 'true'
        ) THEN
          eff := COALESCE(inv.overdue_inbound_qty, 0) + COALESCE(inv.current_stock_qty, 0);
          INSERT INTO public.medsec_quote_advisories
            (quote_id, quote_item_id, advisor_id, advisory_type, severity, message, data)
          VALUES (
            NEW.id, it.id, NULL, 'low_stock',
            CASE inv.stock_status_auto WHEN 'out' THEN 'critical' ELSE 'warning' END,
            it.product_code || ' 有效供應 ' || eff
              || '(逾期 ' || COALESCE(inv.overdue_inbound_qty, 0)
              || ' + 現有 ' || COALESCE(inv.current_stock_qty, 0) || ')'
              || ' < 月均銷 ' || COALESCE(inv.monthly_avg_sales, 0)
              || ' → ' || CASE inv.stock_status_auto
                            WHEN 'out' THEN '嚴重缺貨' ELSE '即將缺貨' END,
            jsonb_build_object(
              'auto', 'true',
              'effective_supply', eff,
              'overdue_inbound_qty', inv.overdue_inbound_qty,
              'current_stock_qty', inv.current_stock_qty,
              'monthly_avg_sales', inv.monthly_avg_sales,
              'stock_status_auto', inv.stock_status_auto)
          );
        END IF;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_quote_autostock_advisory ON public.medsec_quotes;
CREATE TRIGGER trg_quote_autostock_advisory
  AFTER INSERT OR UPDATE OF status ON public.medsec_quotes
  FOR EACH ROW EXECUTE FUNCTION public.medsec_quote_autostock_advisory();

COMMENT ON COLUMN public.medsec_product_inventory.stock_status_auto IS
  'GENERATED:依 有效供應(逾期+現有) vs 月均銷 自動推導,Cindie 不可手寫';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 新欄 + generated:
--    SELECT column_name, is_generated FROM information_schema.columns
--    WHERE table_name='medsec_product_inventory'
--      AND column_name IN ('product_category','overdue_inbound_qty',
--        'monthly_avg_sales','available_months','stock_status_auto');
-- 2. 推導正確:塞 overdue=0 current=0 monthly=45.5 → stock_status_auto='out'
--    塞 overdue=3 current=0 monthly=45.5 → eff=3 < 45.5 → 'low'
--    塞 overdue=120 current=7 monthly=9.14 → eff=127 ≥ 18.28 → 'normal'
-- 3. trigger:把一張報價 status 改 pending_review,缺貨品項應自動進
--    medsec_quote_advisories(data->>'auto'='true')
