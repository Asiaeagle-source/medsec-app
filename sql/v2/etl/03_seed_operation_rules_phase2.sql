-- 03_seed_operation_rules_phase2.sql — V2 Sprint 1 ETL Phase-2
-- §A approved mapping (12 舊代號 → 8 新代號)
-- ON CONFLICT DO NOTHING: 多舊→同新 / phase-1 已灌 → 留第一筆
-- Mapping trace:
--   AM09 → VGTN
--   AP46 → UCGN
--   AP47 → MSSN
--   BT09 → CMUM
--   BT10-1 → CMUM
--   BT16 → CMUM
--   CC02 → S-NMS
--   CC04 → KMMS
--   CP44 → EDHS
--   CP50 → EDHS
--   CP52 → S-NNA
--   盛弘 AP69 → MSSN

INSERT INTO public.medsec_hospital_operation_rules
  (hospital_id, order_mode, shipping_destination, shipping_method, packaging_notes, invoice_mode, invoice_track, dual_invoice, payment_cycle_note, invoice_product_name, case_close_method, special_notes, source_secretary)
SELECT v.* FROM (
VALUES
  ('CMUM'::text, '傳真'::text, '開刀房'::text, '業務親送'::text, NULL::text, '雄鷹電子'::text, '06/31'::text, FALSE::bool, NULL::text, NULL::text, '※補貨單月結
※訂單直接開發票出貨'::text, '※售價皆同中國本院
中國體系-鑽頭
球型$2,980
鑽石型$4,800
F3/9TA30$4,800
8TD136$2,840'::text, '伶華 (phase-2: BT09→CMUM)'::text),
  ('CMUM', '傳真', '業務親送', '業務親送', '需貼院內碼貼紙', '雄鷹電子', '06/31', FALSE, NULL, NULL, '※補貨單月結
※訂單直接開發票出貨
3F手術室=OR
46124月結單來再出貨(先檢查借單)', '※售價皆同中國本院', '伶華 (phase-2: BT16→CMUM)'),
  ('CMUM', '傳真', '業務親送', '業務親送', '需貼院內碼貼紙', '雄鷹電子', '06/31', FALSE, NULL, NULL, '※補貨單月結
※訂單直接開發票出貨', '※售價皆同中國本院
※亞大庫 HBT10Y', '伶華 (phase-2: BT10-1→CMUM)'),
  ('S-NMS', 'Mail /
業務', '開刀房', '業務親送', NULL, '雄鷹電子', '06/31', FALSE, '年底關帳
12/20', NULL, '※出貨+開發票
※跟刀品項直接開發票', 'nan', '伶華 (phase-2: CC02→S-NMS)'),
  ('S-NNA', '業務', NULL, NULL, NULL, '雄鷹電子', '06/31', FALSE, NULL, '發票抬頭：南門醫療社團法人南門醫院
統編：74818132', '※開發票出貨', '每個月寄紙本請款對帳單， 藥庫 陳''s #206
南門凱瑞斯 成交價：
PF3001/5001  $1800
PF3003/5003 $2100
PSG500 $1500', '伶華 (phase-2: CP52→S-NNA)'),
  ('KMMS', '傳真', '業務親送', '業務親送', NULL, '雄鷹電子 + 雄鷹手開 + 君華電子 + 君華手開', '06/31 / 02/32 / 03/32', TRUE, NULL, 'PA100-A 氮氣過濾器', '同市民生', 'PSG500-1,738
PF3001-2,237
PF3002-2,473
PF3003-2,579
8004008-150/EA', '伶華 (phase-2: CC04→KMMS)'),
  ('MSSN', 'Email', '業務親送', '業務親送', '發票須帶訂單/請購單號', '雄鷹電子', '06/31', FALSE, NULL, NULL, NULL, '1. 業務通知先Key借單，之後會收到採購單之email，再轉銷單開發票。《報刀》轉借先出貨給業務，待醫院訂單來轉銷', '伶華 (phase-2: AP47→MSSN)'),
  ('MSSN', '業務
E-mail', '庫房', NULL, NULL, '雄鷹電子', '06/31', FALSE, NULL, NULL, '※開發票出貨', '（訂單上是盛弘就開盛弘、敏盛就開敏盛發票）
* Strata業務跟刀，務必只上Valve，導管用醫院的！', '伶華 (phase-2: 盛弘 AP69→MSSN)'),
  ('VGTN', '業務通知', '開刀房', '業務親送', NULL, '雄鷹電子 + 雄鷹手開 + 君華電子 + 君華手開', '06/31 / 02/32 / 03/32', TRUE, NULL, '君華品項：
Timesh
Strata

雄鷹品項：
95001
46700
450205
41101
60101', '※開發票出貨
業務通知先開借單，待報刀後再借轉銷', '開刀房#460
合約品項價格同北榮合約', '伶華 (phase-2: AM09→VGTN)'),
  ('UCGN', 'EMAIL訂單', NULL, NULL, NULL, 'nan', NULL, FALSE, NULL, '和長庚同體系同作法，發票不需要印出來，但須把訂單編號與發票號碼給長庚業秘一同上傳台塑網', '※開發票出貨', 'nan', '伶華 (phase-2: AP46→UCGN)'),
  ('EDHS', 'Mail', NULL, NULL, NULL, '雄鷹電子', '06/31', FALSE, NULL, NULL, '同義大', 'nan', '伶華 (phase-2: CP50→EDHS)'),
  ('EDHS', 'Mail', NULL, NULL, NULL, '雄鷹電子', '06/31', FALSE, NULL, NULL, '同義大', 'nan', '伶華 (phase-2: CP44→EDHS)')
) AS v (hospital_id, order_mode, shipping_destination, shipping_method, packaging_notes, invoice_mode, invoice_track, dual_invoice, payment_cycle_note, invoice_product_name, case_close_method, special_notes, source_secretary)
WHERE EXISTS (
  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id
)
ON CONFLICT (hospital_id) DO NOTHING;
