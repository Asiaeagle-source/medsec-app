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
