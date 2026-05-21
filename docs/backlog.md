# Backlog

# Sprint 3:歷史報價/成交 + 健保價 + 醫院慣用折數(AI 建議價 v2)

> Lynn 拍板。不碰 Sprint 2.5 quote_advisories trigger;不動 medsec_quotes
> 表(quote_history 為平行新表);不做過期歷史自動清理(Sprint 4)。

## 階段拆分

- **階段 3A(已實作於 branch `claude/sprint-3a`)**:4 表 schema+RLS、
  CRM 報價明細匯入(31K,forward fill+隔行 header)、ERP 成交價匯入
  (60 天回填)、`admin-pricing.html` 4 Tab(CRM/ERP 上傳、歷史列表、
  醫院慣用折數)、manager nav 入口 `💰 歷史價管理`。
  檔案:`sql/v3/01_quote_history_schema.sql`、`sql/v3/02_quote_history_rls.sql`、
  `admin-pricing.html`、`manager.html`。
- **階段 3B(未做)**:健保碼對應介面、健保價爬蟲+cron、
  `calculate_ai_suggested_price_v2` SQL function、業祕報價 4 維度 UI 升級。
  (3A 已建空表 `medsec_nhi_pricing` / `medsec_product_nhi_mapping` 供 3B 用)

---

# Sprint 3B 定價智能系統(Lynn × Claude 共同設計,2026-05-20 規格)

> 三張卡片 UI 原型已確認;以下為開發藍圖。**本批不動 code**,
> 待 3A merge + 健保資料入庫後啟動。

## 1. 資料基礎(已就緒)
- 報價 `medsec_quote_history`(23,831 筆,選項乙):opportunity_type/no(8,312 筆)、
  notes(19,295)、discount_note(831);`erp_quote_no` 非空 = won。
- 成交 `medsec_sales`(近五年 130,374 筆):invoice_no/sales_date/customer_code/
  product_code/unit_price/qty/product_sn。
- 體系 `hospitals.system_prefix`(BS 碼)。
- **健保**:⚠️ 尚未匯入(Lynn 找 codex 取得,見 §7)。

## 2. 核心計算:折數(成交 ÷ 報價)
配對 = `(hospital_id, product_code)` 同組,對每筆報價找報價日之後第一張發票。
取合理區間 0.3~1.2 排離群。**驗證**(全量):1,980 組 × 4,556 筆配對,
整體中位 90%,最低 30%;495 組配對 ≥3 有分布。
每組呈現:最常折數(5% 級距眾數)+ 占比、歷史最低 + 占比、中位數;
樣本 < 3 標「參考用」。

## 3. 卡片 A:後台慣用折數分析(Lynn / 老闆 only,機密)
RLS 同既有機密頁,業祕業務無權限。每張「醫院×品項」卡:
- 最常折數(占比)/ 歷史最低(占比)/ 中位數
- 風險標記:破底警示(最低 ≤50% 且 中位−最低 ≥20%)、波動(spread ≥20%)、穩定
- 上次報價(金額+日期)/ 上次成交(金額+日期+「本院成交過」)
- 距上次成交月數,≥12 月標「可考慮漲價」(Lynn 漲價邏輯)
- 他院同品項近期成交明細(醫院名+價格+折數)

## 4. 卡片 B:業祕報價建議(業祕看得到的部分)
**看得到**:建議價、上次報價/成交基準、他院高價參考。
**看不到**:折數分析、他院折數、營業額、成本、其他品項。
**建議價優先序**:
1. 本院這品項成交過 → 本院上次報價(主)+ 上次成交(參考)。
2. 本院沒成交過 → 同系列推估 + 他院/同體系參考。

**他院參考過濾**:只顯示「報價 ≥ 本院上次成交價」的他院;排除 >本院 3 倍離群、
過舊。格式:醫院名 + 報價/成交(沒成交寫「未成交」)+ 時間。

**守價提醒(填寫當下,不預先)**:回填金額時即時:
- < 上次成交價 → 紅「確定報這麼低?」
- < 上次報價 → 黃提醒
不預先彈黃色(免嚇人),只在填低時跳。

## 5. 卡片 C:整批設備報價試算(業祕)
**用途**:業務幫醫院估整套設備預算 → 套裝總價建議 + 單品攤提。
**每單品攤提來源優先序**:
1. 本院歷史(報價/成交)
2. 同系列推估(本院無此品項 → 找同系列,見 §6)
3. 他院攤提:**有體系者優先同體系**,其次其他醫院,按金額比例攤提剩餘。

**功能**:預算輸入 → 對比建議總額(預算內空間 / 超出多少);每列顯示依據;
即時重算;**攤提/總價切換**(只給總價=保留之後單支補單賣高的空間)。
回寫業務需求單:本期 PASS,先做試算工具,結果人工貼回。

## 6. 同系列比對引擎(本院沒報價過 fallback)
評分制(已驗證):
- 品名關鍵字重疊 ×2 分(從 product_name 抽大寫英文詞 ≥3字,排除 VALVE/SML/REG)
- 品號前綴相同(前 5 字)+3 分
- score ≥2 視為同系列,取 top 6。

驗證:`92355 (STRATA SML) → 92365/92866`、`MR8-AS09 → MR8-AS07/MR8-AVS`。
品名比品號前綴準(品號常無規律,品名含系列名 STRATA/MR8)。

## 7. 健保模組(待資料匯入)
**狀態**:健保碼/健保價尚未匯入,Lynn 找 codex 取得後匯入。
**資料表**:健保碼、品號↔健保碼對應(關鍵難點)、健保價、生效日/版本。
**匯入**:比照 medsec_sales,保留版本(健保碼+生效日為鍵)看歷年變化。
**功能**:健保給付品項報價封頂 — 報價 > 健保價 → 紅框警示。

## 8. 權限總表
| 資料/功能 | Lynn/老闆 | Cindie | 業祕/業務 |
|---|---|---|---|
| 卡片 A 後台折數分析 | ✓ | — | ✗ |
| 他院折數 | ✓ | — | ✗ |
| 卡片 B 報價建議 | ✓ | — | ✓(僅建議) |
| 卡片 C 整批試算 | ✓ | — | ✓ |
| 營業額/成本/滯銷 | ✓ | 部分 | ✗ |

## 啟動前置(Sprint 3B 何時開工)
- ✅ 3A 報價/成交資料已入庫
- ⏳ 3A PR #7 merge 入 main
- ⏳ 健保資料 Lynn 取得並匯入(§7)
- ⏳ Lynn 拍板 Sprint 3B 啟動

## 業務背景

公司**沒有「標價」概念**,定價基於 5 維度:
1. 同醫院過去報價/成交歷史
2. 同體系過去報價/成交歷史
3. 健保支付標準(衛福部公告)
4. 醫院慣用折數(Lynn / Cindie 維護)
5. 自費比價網(Sprint 4+,暫緩)

AI 報價邏輯:業祕報價時看 5 維度 → AI 整合給「建議價 + 區間 + 信心」→ Lynn 拍板。

## 「體系」欄位確認(已查證,不需新建體系表)

`medsec_hospitals` 既有欄位(來自 `sql/04_seed_medsec_hospitals.sql`):
- **`system_prefix`** = 體系代碼(例 `VGH` 榮民體系),對應主檔 `hospital_systems`
  (`sql/01_extend_existing_schema.sql` / `sql/03_seed_hospital_systems.sql`,33 種體系)
- `parent_code` = 另一層母代碼(與 system_prefix 不同,非體系分組用)
- `region_code` / `region_name` = 區域(南/北…)
- `customer_type` = 醫學中心 / 區域醫院 / 地區醫院
- `payment_terms` = 付款條件

→ **Sprint 3「同體系」分組直接用 `medsec_hospitals.system_prefix`**;
  quote_history.parent_code 欄改以「自動帶入 system_prefix 值」填(欄名沿用
  spec 的 parent_code,但語意=體系代碼),不需新建體系表。

## Schema(Sprint 3 做)

### 表 1:medsec_quote_history(歷史報價/成交)
欄位:hospital_id / hospital_name / parent_code(=體系 system_prefix) /
region_code / customer_type / product_code / product_name / product_category /
quoted_price / quoted_quantity / quoted_at / quoted_by /
closed_at / closed_price / closed_quantity / closed_discount_rate /
status(quoted|won|lost|expired) / source(medsec_app|erp_import|manual) /
source_quote_id / erp_invoice_no / notes / created_at。
索引:(hospital_id,product_code,quoted_at desc)、
(parent_code,product_code,quoted_at desc)、(status,quoted_at desc)。

### 表 2:medsec_nhi_pricing(健保價)
nhi_code UNIQUE / product_name / payment_class / payment_points /
payment_price / ceiling_price / effective_date / end_date / source_url /
imported_at。

### 表 3:medsec_product_nhi_mapping(品號↔健保碼)
product_code / nhi_code / match_confidence / mapped_by / mapped_at,
UNIQUE(product_code,nhi_code)。

### 表 4:medsec_hospital_pricing_strategy(醫院慣用折數,關鍵)
hospital_id PK / default_pricing_multiplier(健保價倍數) /
default_discount_rate / min_acceptable_price_pct /
pricing_strategy(aggressive|standard|competitive|maintain) /
notes / updated_by / updated_at。

## AI 建議價 v2:calculate_ai_suggested_price_v2(hospital_id, product_code, quantity)

優先序:同醫院近 12 月 → 同體系近 12 月 → 健保價×醫院慣用 multiplier →
健保價×1.5(預設)。

信心分數:同醫院 3+ 筆 95% / 同醫院 1-2 筆 80% / 同體系 5+ 筆 70% /
同體系 1-4 筆 50% / 健保+醫院折數 35% / 只有健保 25% / 0 資料 0%。

建議區間:下限 max(健保價, 同體系最低成交);上限 min(自費上限, 同體系
最高成交);建議落區間中位數。

## UI

- 業祕「報價優化」加品項時顯示 4 維度卡片(該醫院/同體系/健保/醫院慣用
  → AI 建議價+信心+區間+依據)。
- 新頁 `admin-pricing.html`,入口:manager.html > 系統設定 > 💰 標價/歷史價管理:
  - Tab1 歷史報價/成交(列表+篩選 醫院/體系/品號/期間/狀態,同體系比較圖可選)
  - Tab2 健保碼對應(Cindie 主維護,表格+上傳 Excel,✓已對應/⚠待對應)
  - Tab3 醫院慣用折數(每家設 multiplier/strategy;未設→同體系預設→全域 1.5x)
  - Tab4 匯入(鼎新成交明細 / 健保碼對應 Excel / 觸發健保價爬蟲)

## 自動寫入 history

Lynn approve 的 quote → trigger 自動 INSERT quote_history(status=quoted);
secretary 標「CRM 已打」+ 出貨後 → 更新 status=won + closed_price。

## 資料來源(實際操作)

- Lynn:鼎新 ERP 近 12-24 月發票明細、待結報價單(status=quoted)、各醫院慣用折數。
- 健保價:每月 cron 從衛福部
  `https://www.nhi.gov.tw/Content_List.aspx?n=A4FFD571B0EE0EB9` 抓,解析 Excel/PDF。

## 估時:Sprint 3 整批 8-10 天
Schema+RLS 1.5 / 鼎新匯入 1.5 / 健保碼對應介面 1 / 健保價爬蟲+cron 2 /
醫院慣用折數管理 1 / AI 建議價 v2 SQL 1 / 業祕報價 UI 升級 1.5 /
自動寫 history trigger 0.5。

## 前置依賴
- ✅ Sprint 2.5 完整 ship(本週末前)
- ⏳ Lynn 從鼎新匯出歷史明細(找會計協助)
- ✅ 「體系」欄已確認 = `medsec_hospitals.system_prefix`(本文件已查證)
- ⏳ Lynn 拍板各醫院慣用折數

## 不要做
- Sprint 3 本身不碰:Sprint 2.5 quote_advisories trigger、現有 medsec_quotes
  表、過期歷史自動清理。
- Sprint 4+ 才考慮:自費比價網爬蟲、政府採購得標查詢(g0v)、衛署仿單管理、
  廠商議價紀錄。
