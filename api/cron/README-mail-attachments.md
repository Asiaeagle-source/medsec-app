# PR A · 信件全文 + needs_reply + 訂單附件解析(cron 後端)

`api/cron/mail-triage.js` 擴充 + 新檔 `api/cron/attachment-parser.js`。以下是**上線前需 Lynn 備妥的後端**與**欄名契約**——若 Lynn 實跑的 SQL 欄名不同,以 Lynn 版為準,回報我對齊。

## 1. Vercel 環境變數
- `ANTHROPIC_API_KEY` —— PDF 文字抽品項用(model `claude-haiku-4-5`)。設定後需 redeploy 才生效。

## 2. Storage
- 私有 bucket **`mail-attachments`**。
- 上傳路徑:`{mail_digest.id}/{sanitize後檔名}`,`x-upsert:true`(cron 重跑覆蓋同檔)。

## 3. mail_digest 新欄(前置,Lynn 已備妥)
| 欄 | 型別 | 說明 |
|---|---|---|
| `body_text` | text | 純文字全文,截 10000 字。歷史信不回填,新掃進的才帶 |
| `web_link` | text | Graph `webLink`(OWA 開信連結;PR B「開啟原信」用) |
| `needs_reply` | bool | 主旨/摘要含 詢價/報價/請回覆/請確認/煩請/是否/能否/？? → true;gray 與 電子報/通知 永遠 false |

## 4. mail_attachments —— cron upsert 使用的欄(請確認與 Lynn 建表一致)
| 欄 | 型別 | 備註 |
|---|---|---|
| `mail_digest_id` | uuid | FK → mail_digest.id |
| `filename` | text | 原始檔名 |
| `storage_path` | text | bucket 內路徑;skipped(非白名單)為 null |
| `file_kind` | text | `csv` / `xlsx` / `pdf` / `pdf_scanned` / `other` |
| `parse_status` | text | `ok` / `scanned_needs_manual` / `failed` / `skipped` |
| `parsed_items` | jsonb | 解析出的品項陣列 |
| `parse_error` | text | 失敗原因(AI 回應無法解析時存原始回應前 500 字) |
| `size_bytes` | int | 附件大小 |
| `content_type` | text | MIME |

**唯一鍵**:`(mail_digest_id, filename)` —— cron 用 `on_conflict=mail_digest_id,filename` 防重跑重複。

## 5. 行為摘要
- **附件只處理 order 桶**(classify `priority==='order'`)。其餘信不拉附件。
- 過濾:`isInline=false`、`≤10MB`、白名單副檔名 `[.csv,.xlsx,.xls,.pdf]`;非白名單記一列 `skipped`(不上傳)。
- 解析:CSV(iconv big5→ fallback utf-8 → papaparse)、XLSX/XLS(SheetJS 第一個非空 sheet)、PDF(pdf-parse;<50 字標 `pdf_scanned`/`scanned_needs_manual` 不呼叫 AI,≥50 字走 haiku 抽品項)。
- 欄位對映:`品號/物料碼/料號/條碼→item_code`、`品名/名稱→item_name`、`數量/訂購量→qty`、`合約/案號→contract_no`。
- 防護:附件整段 try-catch;單信逾時 20 秒標 failed 跳過;任何附件失敗都**不中斷主 triage**。
- cron 回傳統計:`attachments_found / parsed / scanned_needs_manual / attachments_failed`。

## 6. 驗收(等前置就緒後,重打 cron)
`?days=N` 補掃 → 檢查:order 信附件入庫 + Storage 原檔;CSV 品項全對(臺中榮總樣本);文字 PDF 抽出品項(台北慈濟樣本 6 項);掃描件標 `scanned_needs_manual`(臺中老人復健樣本);新信帶 `body_text`+`web_link`;詢價信 `needs_reply=true`。

## 7. Headless(mock)驗證 —— 已過
- Parser 15/15:big5 CSV、XLSX 異名欄、mapHeaders、extractJsonArray 容錯(圍欄/雜訊/壞回應)、sanitize、非白名單 skipped、AI 抽取。
- Rules 18/18:needsReply 各 hint 與 gray/通知排除、classifyMail body_text 截斷/web_link 透傳/needs_reply。
- Handler 12/12:只對 order 拉附件、inline 不計、parsed/failed 統計、storage path、skipped 記錄、壞 PDF failed 不中斷。

## 8. 分段補掃 / 續作(Hobby 60 秒限制對策;正式排程同用)
- **時間預算**:單發 50 秒軟上限(分類階段剩 <8s、附件階段剩 <22s 不再開新工),60 秒硬限前收尾回傳。
- **`?limit=N`**(選用):每發最多分類 N 封 + 附件處理 N 封;不帶則由預算主導。
- **續作**:視窗內已入庫的信跳過重分類(歷史信不回填,對齊規格);order 信附件以
  `(mail_digest_id, filename)` 對照既有列逐附件跳過。**同指令重打即續作**(全冪等)。
- **回傳**:`existing / classified / attachment_mails_processed / remaining{to_classify, attachment_mails} / partial / budget_ms_used`。
  補掃打到 `partial=false`(remaining 全 0)即完成。
- 正式排程(days=1)增量小,通常一發跑完;首跑/補掃用 `?days=N` 連打數發即可。

## 9. GitHub Actions 高頻排程 + INGEST_FLOOR(2026-07-21)
- `.github/workflows/mail-cron.yml`:每 30 分鐘(:11/:41)打 production
  `?days=1`;concurrency 防重疊;失敗不重試(下一輪自然補)、標紅通知。
- **Lynn 唯一動作**:repo → Settings → Secrets and variables → Actions →
  New repository secret,名稱 `CRON_SECRET`(值自填,不出現在 repo 與對話)。
  Secret 就緒後 workflow 自動生效;Vercel 內建 2 發可留可刪(冪等共存無害)。
- **INGEST_FLOOR**:`api/cron/mail-triage.js` 頂部常數
  `INGEST_FLOOR_ISO = 2026-07-19T16:00:00Z`(= 2026-07-20 00:00 台北)。
  起算日前收到的信一律不入庫(視窗夾住 + 逐信過濾雙保險),防 `?days`
  回看把 Lynn 已刪除的歷史信重新抓回。回傳 JSON 的 `floored` = 本發被
  地板擋下的封數。
