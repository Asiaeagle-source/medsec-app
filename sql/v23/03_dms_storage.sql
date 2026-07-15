-- ============================================================
-- V2.3 DMS · 03 Storage(只產出,交 Lynn 審後執行)
-- ------------------------------------------------------------
-- 私有 bucket dms-files,政策比照 ticket-files,但收斂為 DMS 權限
-- (auth_can_dms());前端一律 signed URL。需先跑 01(auth_can_dms)。
-- ============================================================

-- 私有 bucket(已存在則略過)
INSERT INTO storage.buckets (id, name, public)
VALUES ('dms-files', 'dms-files', false)
ON CONFLICT (id) DO NOTHING;

-- storage.objects 政策:限 dms-files bucket + auth_can_dms()
DROP POLICY IF EXISTS dms_files_select ON storage.objects;
CREATE POLICY dms_files_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'dms-files' AND public.auth_can_dms());

DROP POLICY IF EXISTS dms_files_insert ON storage.objects;
CREATE POLICY dms_files_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'dms-files' AND public.auth_can_dms());

DROP POLICY IF EXISTS dms_files_update ON storage.objects;
CREATE POLICY dms_files_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'dms-files' AND public.auth_can_dms())
  WITH CHECK (bucket_id = 'dms-files' AND public.auth_can_dms());

DROP POLICY IF EXISTS dms_files_delete ON storage.objects;
CREATE POLICY dms_files_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'dms-files' AND public.auth_can_dms());

-- 註:ticket-files 當初是「純 authenticated」;DMS 這裡加 auth_can_dms() 收得更緊,
-- 若 Lynn 要完全比照 ticket-files(純 authenticated),把 policy 內 AND public.auth_can_dms() 拿掉即可。
