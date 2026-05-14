-- 02_seed_credentials.sql — V2 Sprint 1 ETL
-- 18 列(伶華 CRM 抽出帳密,V2.0 明文 / V2.1 加密)
-- self-skip dingxin_code 不在 V1 185 家的列
-- ⚠️ 沒 ON CONFLICT — 重跑會插重複!Lynn 只跑一次
-- needs_review 走 03 schema default = true,業祕審完手動改 false

INSERT INTO public.medsec_hospital_credentials
  (hospital_id, platform, url, account, password, tax_id, notes)
SELECT v.* FROM (
VALUES
  ('S-FEN', '供應商平台', 'https://depart.femh.org.tw/supp/login.aspx', '70576007', '654321', NULL, NULL),
  ('VGKS', '供應商平台', NULL, '28863581', '40151671', NULL, NULL),
  ('VGKS', '供應商平台', 'https://eop02p.vghks.gov.tw/Rsm/RsmVendorLogin.aspx', 'ASIA', '9917d702-2', NULL, NULL),
  ('CGKS', '供應商平台', 'https://www.e-fpg.com.tw/j2sp/mgt/mgt_logon.jsp?logonstate=Big5', 'asiaeagleM1', 'AE70576007', NULL, NULL),
  ('CGKS', '供應商平台', 'http://crm4.fpg.com.tw/esup/', NULL, NULL, NULL, NULL),
  ('KCDS', '供應商平台', 'https://www.e-fpg.com.tw/j2sp/mgt/mgt_logon.jsp?logonstate=Big5', 'asiaeagleM1', 'AE70576007', NULL, NULL),
  ('KCDS', '供應商平台', 'http://crm4.fpg.com.tw/esup/', NULL, NULL, NULL, NULL),
  ('CP39', '供應商平台', 'https://b2b.cmuh.org.tw/', NULL, NULL, NULL, NULL),
  ('CKUS', '供應商平台', 'https://www.hosp.ncku.edu.tw/External/Frim/Login.aspx', NULL, NULL, NULL, NULL),
  ('CHSS', '供應商平台', 'https://rt01.sinlau.org.tw/sinlau/ACC/Login.asp', NULL, '70576007', NULL, NULL),
  ('CHMS', '供應商平台', 'https://rt01.sinlau.org.tw/sinlau/ACC/Login.asp', NULL, '70576007', NULL, NULL),
  ('CBMS', '供應商平台', 'https://lgc.tradevan.com.tw/tln-bin/APTLN/Login.do?command=checkUser', 'LGC20548M', 'ae70576007', NULL, NULL),
  ('CBLS', '供應商平台', 'https://lgc.tradevan.com.tw/tln-bin/APTLN/Login.do?command=checkUser', 'LGC20548M', 'ae70576007', NULL, NULL),
  ('CBJS', '供應商平台', 'https://lgc.tradevan.com.tw/tln-bin/APTLN/Login.do?command=checkUser', 'LGC20548M', 'ae70576007', NULL, NULL),
  ('S-PAE', '折讓單平台', 'https://www.pohai.org.tw/pohai/factory_sheet/index.php', '70576007', '70576007', NULL, NULL),
  ('S-PAE', '供應商平台', 'https://survey.pohai.org.tw/', NULL, NULL, NULL, NULL),
  ('AP51', '供應商平台', 'https://www.tyh.com.tw:88/sup/', 'SSYD001', '70576007', NULL, NULL),
  ('AP91', '廠商專區：', 'http://scm.fjuh.fju.edu.tw/SCM.NSF', '28863581', '0227089959', NULL, NULL)
) AS v (hospital_id text, platform text, url text, account text, password text, tax_id text, notes text)
WHERE EXISTS (
  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id
)
;
