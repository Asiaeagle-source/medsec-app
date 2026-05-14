# sql/v2/etl/ — V2 Sprint 1 Seed ETL

## 用途

把 V2 zip (`medsec_v2_sprint1.sql`) 裡的 115 筆操作規則 + 18 筆帳密
轉成 V1 schema 對齊版灌進去。

生成腳本：`tools/v2_seed_etl.py`（一鍵重產這 3 支 SQL，不修內容直接覆蓋）。

## 套用順序

| Step | 檔 | 動作 | 預期 |
|---|---|---|---|
| 1 | `01_seed_operation_rules.sql` | 灌 115 筆 operation_rules | INSERT 0–115（self-skip 不存在的 dingxin_code、ON CONFLICT 跳過已有 hospital_id）|
| 2 | `02_seed_credentials.sql` | 灌 18 筆 credentials | INSERT 0–18（self-skip 不存在的 dingxin_code）|
| 3 | `99_verify_skipped.sql` | 列出哪些 dingxin_code 不在 V1 185 家 | 回 N 列 dingxin_code（N = 115+18 中沒對到的） |

## 跑完看欄位有沒有對齊

```sql
-- 抽 1 筆 operation_rule 看完整欄位
SELECT *
FROM public.medsec_hospital_operation_rules
WHERE hospital_id = 'NTHN'
LIMIT 1;
-- 預期：
--   order_mode='MAil訂貨'、shipping_method='業務親送'、invoice_track='06/31 / 02/32 / 03/32'
--   dual_invoice=true、payment_cycle_note='25號之後開下個月'、invoice_product_name='依照訂單'
--   special_notes 含換行的請購單號說明、source_secretary='伶華'
--   has_consignment / consignment_notes 這兩欄不存在（V1 schema 沒 ADD）

-- 抽 1 筆 credentials 看
SELECT *
FROM public.medsec_hospital_credentials
WHERE hospital_id = 'S-FEN'
LIMIT 1;
-- 預期：
--   platform='供應商平台'、url='https://depart.femh.org.tw/...'、
--   account='70576007'、password='654321'、needs_review=true
```

## ETL 設計拍板（Lynn 2026-05-15）

| # | 題 | 拍板 |
|---|---|---|
| 1 | Password 明文還是加密 | Sprint 1 明文（V2.1 上 pgcrypto + service-role decrypt RPC）|
| 2 | dingxin_code 對不到 V1 怎麼辦 | self-skip + 99 列清單，不中斷整個 ETL |
| 3 | 灌完先停下來 sample 1 筆驗收 | 跑完 01+02 後跑上面兩條 SELECT 貼結果 |

## 為什麼 02 沒 ON CONFLICT

`medsec_hospital_credentials` 沒任何 UNIQUE 限制（一家可有多個平台、同平台可有多帳號）。
所以重跑 02 會**插重複**。Lynn 只跑一次即可。如果一定要重跑：

```sql
-- 砍掉這次 ETL 進去的 18 筆再重跑
DELETE FROM public.medsec_hospital_credentials WHERE needs_review = true;
```

（前提：18 筆都還沒有業祕審完改 false。如果已開始審，DELETE 會掉手動改的紀錄，請先 backup。）

## SKIPPED.md 補位

跑完 99_verify_skipped.sql 後，把回的 dingxin_code 清單貼給 Claude，
會生成 `SKIPPED.md` 紀錄哪幾家被略過 + 原因（缺 COPI01 / 拼錯代號 / 數據異常等）。

## ⚠️ 不要動的事

- 不要直接改這 3 支 SQL。如要改邏輯（例如改 source_secretary 寫法），
  改 `tools/v2_seed_etl.py` 後重跑 `python3 tools/v2_seed_etl.py`。
- V2 zip 原始檔（`medsec_v2_sprint1.sql` + `_part3.sql`）**不入 repo**，
  在 Lynn 本機 `/tmp/v2_zip/`。要重跑 ETL 先把 zip 解壓回那個位置。
