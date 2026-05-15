-- ============================================================
-- 03_create_hospital_credentials.sql — V2 Sprint 1 step 3
-- ============================================================
-- 為什麼：
--   各醫院的「供應商平台」帳密散在 13 份個人 Excel。
--   集中到 DB，副祕代理時能直接登入，不用問主祕。
--
-- Lynn 拍板 Q4：FK 改 text + uuid。
-- Lynn 拍板 Q7：主祕 + 副祕都看（不只主祕，副祕為代理人，業務互信）。
--
-- ⚠️ 安全：V2.0 帳密欄位是明文 — V2.1 應改 pgcrypto 加密 + service role
--    decrypt RPC。本表 RLS 只給「該醫院主/副祕 + manager + 伶華」SELECT，
--    其他角色（業務/採購/會計）連 SELECT 都不行。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.medsec_hospital_credentials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id     text NOT NULL REFERENCES public.medsec_hospitals(id) ON DELETE CASCADE,

  platform        text NOT NULL,        -- 「供應商平台」/「電子簽核」/...
  url             text,
  account         text,                 -- ⚠️ V2.0 明文
  password        text,                 -- ⚠️ V2.0 明文
  tax_id          text,                 -- 該帳號對應的統編（雄鷹 / 君華 兩家）

  notes           text,
  needs_review    bool NOT NULL DEFAULT true,  -- AI 抽出來時 = true，業祕審完改 false

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credentials_hospital    ON public.medsec_hospital_credentials(hospital_id);
CREATE INDEX IF NOT EXISTS idx_credentials_needs_review ON public.medsec_hospital_credentials(needs_review)
  WHERE needs_review = true;                                    -- partial：審核清單 query 快

-- updated_at 自動觸發
CREATE OR REPLACE FUNCTION public.touch_credentials_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_credentials_updated ON public.medsec_hospital_credentials;
CREATE TRIGGER trg_credentials_updated
  BEFORE UPDATE ON public.medsec_hospital_credentials
  FOR EACH ROW EXECUTE FUNCTION public.touch_credentials_updated_at();

COMMENT ON TABLE public.medsec_hospital_credentials IS
  'V2 sprint 1：醫院供應商平台帳密。V2.0 明文，V2.1 加密。RLS 限主/副祕 + 管理層。';
