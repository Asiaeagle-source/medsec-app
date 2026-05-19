# Backlog

# Sprint 3:歷史報價/成交 + 健保價 + 醫院慣用折數(AI 建議價 v2)

> Lynn 拍板,基於真實資料樣本更新。本批 **不在 Sprint 2.5 動**,Sprint 3
> 啟動時實作。不碰 Sprint 2.5 的 quote_advisories trigger;不動現有
> medsec_quotes 表(quote_history 為平行新表);不做過期歷史自動清理
> (Sprint 4 報表時再說)。

## 業務背景

公司**沒有「標價」概念**,定價基於 5 維度:
1. 同醫院過去報價/成交歷史
2. 同體系過去報價/成交歷史(`hospitals.system_prefix`)
3. 健保支付標準(衛福部公告)
4. 醫院慣用折數(Lynn / Cindie 維護)
5. 自費比價網(Sprint 4+,暫緩)

AI 報價邏輯:業祕報價時看 5 維度 → AI 整合給「建議價 + 區間 + 信心」→ Lynn 拍板。

## 體系欄(已確認)

- 體系 = **`medsec_hospitals.system_prefix`**(33 種,例 `VGH`=榮民體系)。
- `parent_code` 是另一層母代碼,**不是**體系分組。
- `region_code` / `customer_type` / `payment_terms` 已存在於 medsec_hospitals。
- Sprint 3「同體系」分組直接用 `system_prefix`,**不需新建體系表**。

## Lynn 提供的真實 Excel 樣本

- **A. CRM 報價單明細**:31,642 筆(鼎新 CRM 匯出)。
- **B. 成交價查詢**:42 筆(鼎新 ERP 銷貨明細匯出)。
- 兩者都用「客戶代號/客戶編號」= 英文 4 碼 = `medsec_hospitals.id`(結尾可能有空格,需 TRIM)。

## Schema(新建,Sprint 3 做)

### 表 1:medsec_hospital_pricing_strategy(醫院定價策略)
hospital_id PK → medsec_hospitals(id) / default_pricing_multiplier
(健保價倍數, default 1.0) / default_discount_rate / min_acceptable_price_pct /
pricing_strategy(aggressive|standard|competitive|maintain) / notes /
updated_by / updated_at。

### 表 2:medsec_quote_history(統一報價/成交歷史)
CRM 來源:crm_quote_type / crm_quote_no。
客戶:customer_code(TRIM)/ customer_short_name / hospital_id(=TRIM
customer_code)/ hospital_name / parent_code / system_prefix / region_code /
customer_type(後四者由 JOIN medsec_hospitals 帶入)。
業務:quoted_by_name / quoted_by_id。
品項:product_code / product_name / product_category / product_sn(成交才有)。
報價:quoted_date(YYYYMMDD parse)/ quoted_qty / quoted_unit_price / quoted_total。
確認:confirmation_code(N/Y)/ confirmed_at / confirmed_by_name(員工碼)。
拋轉 ERP:erp_quote_type / **erp_quote_no(有=已拋,等同成交流程)** /
promoted_at / promoted_by_name。
銷貨(ERP 銷貨明細匯入):sales_date / sales_unit_price / sales_qty / sales_total。
status **GENERATED ALWAYS STORED**:
`sales_date NOT NULL → 'won'` / `erp_quote_no 非空 → 'promoted'` /
`confirmation_code='Y' → 'confirmed'` / else `'quoted'`。
source('crm_import'|'erp_sales_import'|'medsec_app')/ notes / created_at。
索引:UNIQUE(crm_quote_no,product_code) WHERE crm_quote_no NOT NULL;
(hospital_id,product_code,quoted_date desc);
(system_prefix,product_code,quoted_date desc);(status,quoted_date desc)。

### 表 3:medsec_nhi_pricing(健保價)
nhi_code UNIQUE / product_name / payment_class / payment_points /
payment_price / ceiling_price / effective_date / end_date / source_url /
imported_at。

### 表 4:medsec_product_nhi_mapping(品號↔健保碼)
product_code / nhi_code / match_confidence / mapped_by / mapped_at,
UNIQUE(product_code,nhi_code)。

## CRM Excel 匯入規格(31,642 筆,重要)

- Sheet:報價明細表;資料行從 **Row 5** 起(Row 1-3 空白,Row 4 首 header);
  column 1 永遠空白,欄位從 column 2 起。

### 欄位對應(column 2 起)
報價單別→crm_quote_type / 報價單號→crm_quote_no /
報價日期→quoted_date(YYYYMMDD parse)/ 報價人→quoted_by_name /
**客戶代號→customer_code(TRIM 結尾空格)** / 客戶簡稱→customer_short_name /
本幣總金額→quoted_total / 品號→product_code / 單身數量→quoted_qty /
單價→quoted_unit_price / 確認碼→confirmation_code(N/Y) /
確認日期→confirmed_at(parse)/ 確認者→confirmed_by_name(員工碼) /
銷售機會單別→skip / 品名→product_name / 拋轉日期→promoted_at(parse) /
拋轉人員→promoted_by_name(員工碼)/ ERP報價單別→erp_quote_type /
**ERP報價單號→erp_quote_no(有=promoted,關鍵)**。

### 解析特殊邏輯(必須做)
1. **隔行 header**:第 2 欄='報價單別' → header,skip;
   第 2 欄='AECC/LDCC/CCCC…' 實際單別 → 資料行。
2. **同單多品項 forward fill**:第 2 欄=None 但其他欄有值 → 上一張單延續品項。
   Forward fill:crm_quote_type / crm_quote_no / quoted_date / quoted_by_name /
   customer_code / customer_short_name / confirmation_code / confirmed_at /
   confirmed_by_name / promoted_at / promoted_by_name / erp_quote_type /
   erp_quote_no。**不 fill**(每行各自):product_code / quoted_qty /
   quoted_unit_price / quoted_total / product_name。
   例:Row23 LDCC 20260519002 署北 27703 → Row24 空單號 署北 46118
   = forward fill 自 Row23,同屬該 LDCC 單。
3. **醫院對應**:customer_code TRIM 後寫 hospital_id;LEFT JOIN
   medsec_hospitals 帶 system_prefix/region_code/customer_type。
4. **業務員對應**:quoted_by_name 中文姓名 → fuzzy match
   profiles.nickname/name(找不到也存字串);
   promoted_by_name/confirmed_by_name 員工碼 → match profiles.employee_id。

## ERP 成交價 Excel 匯入規格(42 筆)

- Sheet:報表 2;資料行從 **Row 3** 起(Row 2 header)。
- 欄位:分類三→product_category / 銷貨日期→sales_date(已 datetime)/
  客戶編號→customer_code(TRIM)/ 客戶全稱→hospital_name /
  產品編號→product_code / 單價全→sales_unit_price / 數量全→sales_qty /
  總價ALL→sales_total / 產品序號→product_sn。
- 匯入邏輯:每筆 ERP 成交 →
  1. 找對應 CRM:`customer_code=TRIM(?) AND product_code=? AND quoted_date
     BETWEEN sales_date-60d AND sales_date ORDER BY quoted_date DESC LIMIT 1`。
  2. 找到 → UPDATE sales_* + product_sn + product_category。
  3. 找不到 → INSERT 新列(source='erp_sales_import',quoted_* NULL,
     只有 sales_*,status 自動='won')。

## AI 建議價 v2:calculate_ai_suggested_price_v2(hospital_id, product_code, quantity)

優先序:同醫院近 12 月(成交 weight 1.0、報價未成交 weight 0.5,信心 80-95%)
→ 同體系近 12 月(50-70%)→ 健保價×醫院 multiplier(35%)→ 健保價×1.5(25%)。
信心:同醫院 3+ 95% / 同醫院 1-2 80% / 同體系 5+ 70% / 同體系 1-4 50% /
健保+醫院 multiplier 35% / 只有健保 25% / 0 資料 0%。
建議區間:下限 max(健保價, 同體系最低成交);上限 min(自費上限, 同體系最高
成交);建議落區間中位數。

## UI

- 業祕「報價優化」加品項時顯示 4 維度卡片:該醫院近 12 月 / 同體系近 12 月 /
  健保支付(健保碼)/ 醫院慣用(健保價×multiplier)→ AI 建議價+信心+區間+依據。
- 新頁 `admin-pricing.html`,入口:manager.html > 系統設定 > 💰 標價/歷史價管理:
  - Tab1 上傳 CRM 報價單明細(支援解析 31K 筆)
  - Tab2 上傳成交價查詢
  - Tab3 歷史報價列表(篩選 醫院/體系/品號/期間/狀態)
  - Tab4 健保碼對應(Cindie 主維護)
  - Tab5 醫院慣用折數(每家 multiplier)

## 自動寫入 history

Lynn approve 的 medsec_quotes → trigger 自動 INSERT quote_history
(status=quoted);業祕標「CRM 已打」+ 出貨後 → 更新 sales_* 欄位。

## 撤回之前 spec(都不需要做)
- ❌ medsec_product_pricing(公司無標價概念)
- ❌ medsec_hospital_aliases(新版 CRM 給客戶代號,exact match 即可)
- ❌ 客戶簡稱 fuzzy match 邏輯
- ❌ admin-hospital-aliases.html

## 估時:Sprint 3 整批 9 天
Schema+RLS 1 / CRM 匯入(隔行 header+forward fill)1.5 / 成交價匯入 1 /
健保碼對應介面 1 / 健保價爬蟲 2 / AI 建議價 v2 SQL 1 /
業祕報價 UI 升級(4 維度)1.5 / Lynn admin-pricing.html 1。

## 前置依賴
- ✅ Sprint 2.5 完整 ship(本週末前)
- ✅ Lynn 提供真實 CRM Excel 樣本(31K 筆)
- ✅ Lynn 提供真實成交價 Excel 樣本(42 筆)
- ✅ 體系欄確認 = `medsec_hospitals.system_prefix`
- ⏳ Lynn 拍板各醫院慣用折數(可選,有預設 1.0)

## 不要做
- Sprint 3 本身不碰:Sprint 2.5 quote_advisories trigger、現有 medsec_quotes
  表、過期歷史自動清理。
- Sprint 4+ 才考慮:自費比價網爬蟲、政府採購得標查詢(g0v)、衛署仿單管理、
  廠商議價紀錄。
