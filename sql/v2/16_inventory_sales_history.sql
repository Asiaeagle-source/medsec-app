-- ============================================================
-- 16_inventory_sales_history.sql — Sprint 2.5 補強
-- ============================================================
-- medsec_product_inventory 加「動態月銷歷史」JSONB:
--   monthly_sales_history = {"2025-01":12,"2025-02":8,...}
-- 由 cindie-inventory 上傳時把 Excel 的 YYYYMM 動態欄塞進來。
--
-- rolling window = 18 個月(Lynn 第一次上傳 16 個月 2025-01~2026-04
--   不會被誤刪,且足夠看完整年度循環 + 同期比較)。
-- 每次寫入:UPDATE 路徑「合併」舊歷史(支援之後每月只上傳當月 1 列),
--   再淘汰 > 18 個月的舊鍵。
--
-- 舊 generated stock_alert_level 由 19 的 v_inventory_intelligence
--   取代(季節調整版),這裡先移除避免雙真相;effective_supply 保留
--   (view 會用到)。idempotent,可重跑。無 DROP TABLE / 無 RENAME。
-- ============================================================

ALTER TABLE public.medsec_product_inventory
  ADD COLUMN IF NOT EXISTS monthly_sales_history jsonb DEFAULT '{}'::jsonb;

-- 舊的非季節版 generated 欄移除(改用 19 view 的季節調整邏輯)
ALTER TABLE public.medsec_product_inventory DROP COLUMN IF EXISTS stock_alert_level;

-- ---------- 合併 + 淘汰(rolling 18 個月)----------
CREATE OR REPLACE FUNCTION public.prune_old_sales_history()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  cutoff_month text := to_char(now() - interval '18 months', 'YYYY-MM');
  merged jsonb;
BEGIN
  -- UPDATE 路徑:把舊歷史合併進來(新上傳的同月覆蓋舊值);
  -- 單筆編輯沒帶 history 時 NEW 會等於 OLD,合併後不變。
  IF TG_OP = 'UPDATE' THEN
    merged := COALESCE(OLD.monthly_sales_history, '{}'::jsonb)
              || COALESCE(NEW.monthly_sales_history, '{}'::jsonb);
  ELSE
    merged := COALESCE(NEW.monthly_sales_history, '{}'::jsonb);
  END IF;

  -- 淘汰 > 18 個月(鍵為 'YYYY-MM',字典序即時序)
  SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb) INTO merged
  FROM jsonb_each(merged) AS e(k, v)
  WHERE k >= cutoff_month;

  NEW.monthly_sales_history := merged;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_prune_sales_history ON public.medsec_product_inventory;
CREATE TRIGGER trg_prune_sales_history
  BEFORE INSERT OR UPDATE ON public.medsec_product_inventory
  FOR EACH ROW EXECUTE FUNCTION public.prune_old_sales_history();

COMMENT ON COLUMN public.medsec_product_inventory.monthly_sales_history IS
  'rolling 18 個月 {"YYYY-MM":qty};上傳合併、自動淘汰更舊';

-- ============================================================
-- 驗證
-- ============================================================
-- 1. 欄在:SELECT column_name FROM information_schema.columns
--    WHERE table_name='medsec_product_inventory'
--      AND column_name='monthly_sales_history';
-- 2. 合併:先 upsert {"2025-01":10},再 upsert 同品號 {"2026-05":7}
--    → monthly_sales_history 應同時含兩鍵
-- 3. 淘汰:塞一個 19 個月前的鍵,寫入後應被移除
