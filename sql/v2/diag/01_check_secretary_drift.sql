-- ============================================================
-- diag · 列出 hospitals.primary_secretary (text 全名) 跟
--        secretary_assignments.primary_secretary_id (uuid → profiles)
--        對不上的 7 家醫院
-- ============================================================
-- 為什麼有這支：
--   Q-S2 mismatch_count = 7。決策：source of truth = secretary_assignments
--   (B)，hospitals 的 primary_secretary / co_secretary 兩 text 欄是
--   denormalized display cache，不參與 RLS。
--
--   但這 7 筆 drift 還是要看一眼是「新分區未同步到 hospitals 文字欄」
--   還是「assignments 沒跟著最近異動」。前者只是 display 落後（可忽略
--   或排個 batch 補同步），後者表示 RLS 會用到錯誤的祕書（壞）。
--
-- 用法：直接貼到 Supabase SQL Editor 跑、不修改任何資料。
-- ============================================================

SELECT
  h.id,
  h.name_short,
  h.primary_secretary             AS hosp_text,
  p1.name                         AS assign_via_uuid,
  a.primary_secretary_id          AS assign_uuid,
  p1.employee_id                  AS assign_employee_id
FROM public.medsec_hospitals h
JOIN public.medsec_secretary_assignments a ON a.hospital_id = h.id
LEFT JOIN public.profiles p1               ON p1.id = a.primary_secretary_id
WHERE coalesce(h.primary_secretary, '') <> coalesce(p1.name, '')
ORDER BY h.id;

-- 預期回 7 列。
-- 怎麼解讀：
--   - 如果某列 hosp_text 是空 / NULL → hospitals 文字欄沒填，但 assignments 有指派
--     ＝ display cache 落後，不影響 RLS。後續 batch 同步即可。
--   - 如果某列兩邊都有值但不一樣 → 可能 assignments 過期。要確認 Lynn / 業祕端
--     最近有沒有改分區，以哪邊為準。如果 hospitals 文字才是新值 →
--     assignments 要重 seed（後者影響 RLS = 影響業祕能不能看到自己分區）。
