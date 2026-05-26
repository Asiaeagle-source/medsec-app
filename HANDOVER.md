# HANDOVER.md — AE MED Hub · medsec-app

> 給接手的 AI / 工程師：請從頭看完這份再動工。
> Lynn 的時間很貴，不要重複前人的坑。
> 最後更新：2026-05-13 · 分支 `claude/continue-work-pZToe` · V3.3（Lynn §9 拍板後）

---

## 0. 目前進度（一眼看完）

| 階段 | 狀態 | 備註 |
|---|---|---|
| Week 1-2 主檔建立（profiles）| ✅ 完成 | 60 員工資料、5 個 medsec_role 開通、profiles RLS |
| Week 3-0 角色頁面骨架 | ✅ 完成 | login + 5 角色 html + medsec-common.js / css |
| Week 3-0.5 共用底層 schema 擴充 | ✅ 完成 | `hospital_systems` / `product_base_prices` / `medsec_salesperson_assignments` 3 張 ADD 完 |
| Week 3-0.6 主檔 seed | 🟡 部分完成 | hospitals 185 ✓、products 5260 ✓、secretary_assignments 182 ✓、salesperson_assignments 236 ✓；其餘 18 張 medsec_* 表 0 筆 |
| Week 3-0.7 INVI02 修復 | ✅ 完成 | 從 3239 → 5260，補 15 欄位（cost / supplier / dms / warehouse），詳 §5 |
| **Week 3-1 報價模組 schema**（本輪 V3.3）| ✅ schema 就緒 | medsec_cases 補 4 欄 + status 9 種 enum；2 張新表（consignment_inventory / product_units）；medteam-app sales INSERT policy；V1 決策包 function。詳 §13 |
| Week 3-1 seed + 接線 | ⏳ 待 medsec_sales_history seed + medteam-app 提詢價按鈕 | |
| Week 3-2 ~ 3-5 | ⏳ 排隊 | |

---

## 1. 專案總覽

### 1.1 我是誰

**AE MED Hub · medsec-app**（業務祕書平台）。雄鷹有限公司 Asiaeagle 內部 SaaS。跟同公司另一個專案 `medteam-app`（業務團隊用）**共用 Supabase project `yincuegybnuzgojakkuc` + 帳號系統**，但兩個 app 各自獨立部署。

登入流程：

1. 員工輸入員工編號 + 密碼（login.html）
2. 後端 sign in：`{employee_id}@medteam.internal`（共用 medteam-app domain）
3. 拉 `profiles` 確認 `has_medsec_access = true`
4. 依 `medsec_role` 跳對應頁面（見 1.2）

### 1.2 5 角色清單（已實作守門）

| `medsec_role` | 中文 | 對應頁面 | 真人 / 員工編號 | 角色色 |
|---|---|---|---|---|
| `manager` | 管理者 | `manager.html` | 賴瑩 `0006`（Lynn）| 紫 `#7c3aed` |
| `bidding_team` | 標案團隊 | `candy.html` | 鄭欣菱 `0132`（Candy）| 青 `#0891b2` |
| `purchasing` | 採購 | `cindie.html` | 周佳蓉 `0003`（Cindie）| 橘 `#ea580c` |
| `accounting` | 會計 | `accounting.html` | 陳靖雅 `0176` | 綠 `#16a34a` |
| `secretary` | 業務祕書 | `secretary.html` | 4 人主分區 ↓ | 桃紅 `#db2777` |

### 1.3 業祕主分區 4 人（Lynn 拍板優先開通）

| 暱稱 | 員工編號 | 全名 | 負責家數（`medsec_secretary_assignments`）|
|---|---|---|---|
| 雅婷 | `0168` | 關雅婷 | ≈ 57 |
| 小飛 | `0011` | 楊斯閔 | ≈ 53 |
| 映晨 | `0150` | 黃映晨 | ≈ 45 |
| 伶華 | `0020` | 魏伶華 | ≈ 34 |

> 業祕課其實還有 4 位（彭冠豪 0129、翁若安 0140、許華翔 0156、施劭宜 0167）。V1 暫不開 `has_medsec_access`，避免代理人 RLS 變複雜。

### 1.4 技術棧

- **前端**：純靜態 HTML / CSS / Vanilla JS（不引框架、不引 build step）
- **CDN**：`@supabase/supabase-js@2`
- **字體**：Google Fonts `Noto Sans TC`
- **後端**：Supabase（Auth + Postgres + RLS + Storage 預留）
- **部署**：靜態檔托管 — repo `asiaeagle-source/medsec-app`

---

## 2. 檔案結構

```
medsec-app/
├── README.md
├── HANDOVER.md                    ← 本檔
├── index.html                     ← 入口 redirect
├── login.html                     ← 登入頁
├── manager.html                   ← Lynn 後台
├── candy.html                     ← Candy 標案後台
├── cindie.html                    ← Cindie 採購後台
├── accounting.html                ← 會計後台
├── secretary.html                 ← 業祕共用後台
├── medsec-common.css              ← 全站樣式
├── medsec-common.js               ← 全站 JS（Supabase / guardRole）
│
├── sql/
│   ├── README.md
│   ├── IMPORT_GUIDE.md            ← V3 套用步驟（products 部分已被 fix_inventory 取代）
│   ├── mapping_report.md          ← 業務暱稱 ↔ 員工編號 mapping
│   ├── sources_inventory.md       ← 5 份原始檔欄位盤點
│   │
│   ├── 01_extend_existing_schema.sql  ← V3 ADD 3 張共用表
│   ├── 02_extend_rls.sql              ← V3 RLS + trgm + search_medsec_products RPC
│   ├── 03_seed_hospital_systems.sql   ← 33 體系
│   ├── 04_seed_medsec_hospitals.sql   ← 184 醫院 → medsec_hospitals
│   ├── 06_seed_medsec_secretary_assignments.sql   ← 182 業祕分區
│   ├── 07_seed_medsec_salesperson_assignments.sql ← 236 業務分區
│   │
│   ├── fix_inventory/             ← INVI02 修復批次（取代原 05_*）
│   │   ├── step0_alter_table.sql          ← ALTER medsec_products ADD 15 欄
│   │   ├── step1~6_upsert_products_part1~6.sql  ← 5260 筆 UPSERT
│   │   └── step7_verify.sql               ← 驗證 total=5260
│   │
│   └── data/                      ← Studio Import 備援用 CSV
│       ├── employees_for_review.csv     (60 員工)
│       ├── hospital_systems.csv         (33 體系)
│       ├── medsec_hospitals.csv         (184 醫院)
│       ├── medsec_products.csv          (5239 筆 — 已被 fix_inventory 5260 取代)
│       ├── medsec_secretary_assignments.csv (182 業祕)
│       └── medsec_salesperson_assignments.csv (236 業務)
│
└── tools/                         ← 從原始檔產資料的 Python 腳本
    ├── generate_import_data.py    ← 讀 5 份原始檔 → 產 CSV
    └── generate_seed_sql.py       ← 從 CSV → 產 INSERT SQL（part 拆檔有 bug，見 §5）
```

---

## 3. AE Hub 分層原則 + V3 大轉向

### 3.1 V3 之前（已作廢，但留 git history 上）

V1/V2 構想：員工 / 客戶 / 區域分配等等底層資料**全 AE Hub 共用**（不加前綴）。要 ADD 5 張新表：`hospital_systems` / `hospitals` / `products` / `hospital_assignments` / `product_base_prices`。

→ **commit `5c1d03c` 之後作廢**：發現 Supabase 上既有的 schema 不長那樣。

### 3.2 V3 拍板（2026-05-13 09:15）

Lynn 在另一個 Claude session 拍板 C 方案：**「不動既有 22 張 medsec_* 表，對齊既有欄位灌資料」**。

具體：

- ✅ 既有的 22 張 `medsec_*` 表**不動 schema 不動 RLS**
- ✅ 只 ADD 3 張共用底層表：
  - `hospital_systems`（33 體系主檔）
  - `product_base_prices`（產品底價，鎖 manager）
  - `medsec_salesperson_assignments`（業務 ↔ 醫院 共管 normalized 結構，補既有 `medsec_secretary_assignments` 「主祕+副祕」無法裝下多人共管的缺口）

### 3.3 V3.1 text-PK 修正（commit `50adab0`）

V3 初版以為 `medsec_hospitals.id` / `medsec_products.id` 是 uuid。實際**兩個都是 text PK**：

- `medsec_hospitals.id` = COPI01 客戶代號（例 `CACN`、`TNH`、`S-YUM`）
- `medsec_products.id` = INVI02 品號（例 `0001`、`2A10`）

→ V3.1 把所有 FK 改成 `text references medsec_*(id)`，包括：
- `product_base_prices.product_id text` references `medsec_products(id)`
- `medsec_salesperson_assignments.hospital_id text` references `medsec_hospitals(id)`
- `search_medsec_products` RPC 回傳 `id text`

### 3.4 V3.3 Lynn §9 拍板（commit `564172d`，本輪）

Lynn 答完 §9 五題（原 4 題 + 補一題 SOP），動工結果：

- `medsec_cases` ALTER 4 欄（`company` / `action_type` / `erp_doc_code` / `sop_ref`），補 status 9 種 enum、補 CHECK
- 13 種 `action_type` × 2 公司 = 25 種 `erp_doc_code` 映射（`calc_erp_doc_code()` function）
- 10 個 SOP 對映（`calc_sop_ref()` function）
- `medsec_cases_autofill()` BEFORE trigger：自動帶 `case_no` = `{erp_doc_code}-{YYMMDD}-{NNN}` 流水
- 新增 2 個 medsec_cases policy 配合 medteam-app 業務 INSERT（不動既有 2 個 policy）
- 加 `auth_medteam_role()` helper（鏡像 `auth_medsec_role()`）
- 建 2 張新表：`medsec_consignment_inventory`（WIS07）+ `medsec_product_units`（WIS09 + 查保固 view）
- 建 `compute_case_decision_package(case_id)` V1 純 SQL aggregate（無 LLM）

詳 §13 + `sql/v33/00_DECISIONS.md`（Lynn 原文）+ `sql/v33/README.md`（套用順序）。

---

## 4. Supabase Schema 現狀（V3.2）

### 4.1 22 張 medsec_* 表總覽

來源：`information_schema.columns` + `pg_tables.rowsecurity` + `pg_policies` + 動態 row_count CTE（2026-05-13）。

| # | 表 | 欄位數 | 已 seed 筆數 | RLS | Policy 數 | 用途 |
|---|---|---|---|---|---|---|
| 1 | `medsec_hospitals` | 24 | **185** | ✅ | 1 | 醫院主檔（COPI01）|
| 2 | `medsec_products` | **42**（含 fix_inventory 15 新欄）| **5260** | ✅ | 1 | 產品主檔（INVI02）|
| 3 | `medsec_secretary_assignments` | 6 | **182** | ✅ | 1 | 業祕分區（主祕 + 副祕） |
| 4 | `medsec_salesperson_assignments` | 10（V3 新建）| **236** | ✅ | 2 | 業務共管分區 |
| 5 | `medsec_cases` | **33**（V3.3 +4 欄）| 0 | ✅ | **4**（V3.3 +2）| 業祕案件（詢價 / 建碼 / 標案）|
| 6 | `medsec_case_items` | 10 | 0 | ✅ | 1 | 案件下的多個產品項 |
| 7 | `medsec_case_documents` | 10 | 0 | ✅ | 1 | 案件附文件 |
| 8 | `medsec_case_timeline` | 7 | 0 | ✅ | 1 | 案件事件流 |
| 9 | `medsec_crm_chunks` | 11 | 0 | ✅ | 1 | CRM 知識庫（含 embedding） |
| 10 | `medsec_discount_rules` | 17 | **3** | ✅ | 1 | 折扣規則（已有 3 筆測試）|
| 11 | `medsec_documents` | 13 | 0 | ✅ | 2 | 文件中央庫（含 OCR 欄）|
| 12 | `medsec_approval_products` | 2 | 0 | ✅ | 1 | 衛署證 ↔ 產品 join |
| 13 | `medsec_regulatory_approvals` | 19 | 0 | ✅ | 1 | 衛署證主檔（含到期日 + IFU）|
| 14 | `medsec_qsd_certificates` | 13 | 0 | ✅ | 1 | QSD 證書（含到期日）|
| 15 | `medsec_qsd_approval_links` | 2 | 0 | ✅ | 1 | QSD ↔ 衛署證 關聯 |
| 16 | `medsec_nhi_codes` | 14 | 0 | ✅ | 1 | 健保碼 |
| 17 | `medsec_hospital_doc_templates` | 9 | 0 | ✅ | 1 | 醫院文件模板 |
| 18 | `medsec_hospital_operation_rules` | 15 | 0 | ✅ | 1 | 醫院操作規則 |
| 19 | `medsec_hospital_shipping_addresses` | 13 | 0 | ✅ | 1 | 醫院收貨地址 |
| 20 | `medsec_pending_invoices` | 11 | 0 | ✅ | 1 | 待開發票 |
| 21 | `medsec_sales_history` | 13 | 0 | ✅ | 1 | 歷史成交價 |
| 22 | `medsec_tender_bonds` | 25 | 0 | ✅ | 1 | 標案保證金（押標 / 履保 / 保固）|
| 23 | `medsec_consignment_inventory`（V3.3 新建）| 12 | 0 | ✅ | 2 | 寄售品庫存（WIS07）|
| 24 | `medsec_product_units`（V3.3 新建）| 11 | 0 | ✅ | 2 | 單台序號保固（WIS09）|

**RLS 摘要：24 張全部 enabled，0 張裸奔。** policy 數 1–4 之間。

**Seed 摘要：4 張有實質資料（185+5260+182+236=5863 筆）+ 1 張測試（3 筆 discount_rules）。其餘 19 張是空殼框架（含 V3.3 新建的 2 張）。**

### 4.2 22 張表欄位細節

> 完整來自 `information_schema.columns`（2026-05-13 export）。分 6 群好讀：
> 主檔 → 分區 → 案件流 → 醫院延伸 → 規範證 → 業務歷史 / 文件 / 知識庫

#### 4.2.1 主檔（2 張）

**`medsec_hospitals` — 醫院主檔（24 欄，185 筆）**

```
id                  text  PK     COPI01 客戶代號（V3.1 確認是 text，不是 uuid）
name_full           text  NOT NULL
name_short          text
tax_id              text
parent_code         text         分院串總院用
system_prefix       text         33 體系 code（對 hospital_systems）
is_standalone       bool
is_distributor      bool
customer_type       text
region_code         text
region_name         text         北 / 中 / 南 / 花東 / 宜蘭 / 離島
invoice_company     int
is_priority         bool
sales_person        text         業務名（文字，正式分區走 medsec_salesperson_assignments）
sales_person_code   text
business_department text
primary_secretary   text         主祕名（文字，正式分區走 medsec_secretary_assignments）
co_secretary        text
payment_terms       text
payment_cycle_day   int
shipping_address    text
notes               text
created_at / updated_at  timestamptz
```

**`medsec_products` — 產品主檔（42 欄，5260 筆，fix_inventory 後）**

```
基本識別：
  id text PK (INVI02 品號) / name NOT NULL / specification
  manufacturer_code / manufacturer_name / product_line / product_series
  catalog_number (INVI02 貨號 = 製造商型號)

分類：
  dms_category / dms_subcategory / classification_level
  is_sterile (bool) / storage_temp_range / storage_humidity
  packaging_standard / service_procedure
  uom / qty_per_uom (int) / status / replaced_by_product

價格 / NHI：
  list_price / cost_price / business_floor_price / has_nhi_code (bool)
  notes / created_at / updated_at

fix_inventory 新增 15 欄（commit ddfb8a1，§5）：
  stock_qty / unit_cost / fee_type_code / fee_type
  dms_category_code / dms_subcategory_code
  warehouse_code / warehouse_name / description
  supplier_code / supplier_name
  last_cost_orig / last_cost_twd / material_cost / standard_cost
```

#### 4.2.2 分區（2 張）

**`medsec_secretary_assignments` — 業祕分區（6 欄，182 筆）**

```
hospital_id text PK    → medsec_hospitals(id)
primary_secretary_id   uuid → profiles(id)
co_secretary_id        uuid → profiles(id)
effective_date         date
notes                  text
updated_at             timestamptz
```

一家醫院一行，主祕 + 副祕都在欄位上（fixed 2 人）。

**`medsec_salesperson_assignments` — 業務共管分區（10 欄，236 筆，V3 新建）**

```
id              uuid PK
hospital_id     text   NOT NULL → medsec_hospitals(id)
salesperson_id  uuid   NOT NULL → profiles(id)
is_primary      bool   NOT NULL
display_order   int    NOT NULL   0=主、1+=共管
effective_date  date   NOT NULL
source          text                'csv' / 'copi01' / 'manual'
notes           text
created_at / updated_at  NOT NULL
```

Normalized：一家可多 row，裝得下 5 人共管。`(hospital_id, salesperson_id)` UNIQUE。

#### 4.2.3 案件流（4 張，全 0 筆，待 Lynn 拍 §9）

**`medsec_cases` — V1 報價模組核心（33 欄，V3.3 +4）**

```
id                       uuid       PK
case_no                  text                 V3.3 trigger 自動帶 {erp_doc_code}-{YYMMDD}-{NNN}
case_type                text       NOT NULL  詢價 / 建碼 / 標案 / ...
quote_subtype            text
hospital_id              text                 → medsec_hospitals(id)
status                   text       NOT NULL  V3.3 9 種 enum：pending / claimed / packaging /
                                              pending_decision / decided / crm_sent / closed /
                                              returned / pending_supplement
current_owner_id         uuid                 目前負責人
current_owner_role       text                 'bidding_team' / 'secretary' / 'manager'
bidding_owner_id         uuid                 標案階段負責人
post_bid_secretary_id    uuid                 得標後轉給的業祕
handover_at              timestamptz
source                   text                 'medteam-app' / 'manual' / ...
source_request_id        uuid                 對應 medteam-app 詢價單 ID
requested_by_user_id     uuid                 業務 ID
title                    text       NOT NULL
description              text
tender_no                text
tender_budget            numeric
tender_open_date         date
due_date                 date
ai_suggested_price       numeric              compute_case_decision_package() 寫入
ai_confidence            numeric              compute_case_decision_package() 寫入（0-1）
manager_decision         text                 Lynn 決策結果
manager_final_price      numeric              Lynn 拍板價
manager_decided_at       timestamptz
manager_decided_by       uuid
created_at / updated_at / closed_at  timestamptz

▼ V3.3 新增（commit 564172d）
company                  text                 'AE' / 'LD'
action_type              text                 13 種 enum（coding / quote / surplus / budget /
                                              renewal / urgent / amortize / negotiate /
                                              tender_supply / tender_equipment / borrow /
                                              repair_quote / maintenance）
erp_doc_code             text                 鼎新 4 碼，trigger 從 (company, action_type) 自動帶
                                              （AECC / LDYJ / AETT ...）；secretary 可改
sop_ref                  text                 WIS01~WIS10 或 NULL，trigger 從 action_type 自動帶
```

**`medsec_case_items` — 案件項目（10 欄）**

```
id, case_id, product_code, quantity (int NOT NULL), unit_price,
ai_suggested_price, final_price, discount_rate, notes, created_at
```

**`medsec_case_documents` — 案件附文件（10 欄）**

```
id, case_id, document_id (→ medsec_documents), doc_category, doc_name,
is_required (bool), upload_status, notes, uploaded_by, uploaded_at
```

**`medsec_case_timeline` — 案件事件流（7 欄）**

```
id, case_id, event_type (NOT NULL), event_data (jsonb), actor_id,
description, created_at
```

#### 4.2.4 醫院延伸（4 張，全 0 筆 / discount_rules 3 筆）

**`medsec_hospital_operation_rules` — 醫院操作規則（15 欄）**

`hospital_id` 是 PK（一家一行）。包含 `order_mode`、`shipping_destination`、`packaging_notes`、`invoice_mode`、`payment_cycle_note`、`invoice_product_name`、`case_close_method`、`contact_person`、`platform_required (ARRAY)`、`special_notes`、`source_secretary` / `source_date` / `confidence`、`updated_at`。

> 給 secretary.html「CRM 知識庫」「醫院規則查詢」用 — 取代散在 13 份個人 Excel 的規則。

**`medsec_hospital_shipping_addresses` — 收貨地址（13 欄）**

```
id uuid PK
hospital_id        text → medsec_hospitals(id)
recipient_role     text       醫院端聯絡角色（採購 / 護理 / 物流 / ...）
recipient_name / recipient_title
zip_code / address / phone / ext / email
is_primary bool
notes / created_at
```

一家可多行（不同部門 / 不同收貨點）。

**`medsec_hospital_doc_templates` — 醫院文件模板（9 欄）**

```
id, hospital_id, case_type NOT NULL, doc_category NOT NULL, doc_name,
is_required bool, notes, example_path, created_at
```

**`medsec_discount_rules` — 折扣規則（17 欄，已有 3 筆測試）**

```
id, hospital_id, parent_code, product_code, product_line,
calc_method NOT NULL (fixed / percentage / donation / ...),
fixed_amount / percentage_rate / donation_amount,
description, applicable_period, source, is_active bool,
effective_date / expiry_date, created_at / updated_at
```

#### 4.2.5 規範證（5 張，全 0 筆 — cindie.html 90/60/30 提醒所需）

**`medsec_regulatory_approvals` — 衛署證主檔（19 欄）**

```
id uuid PK
approval_number       text NOT NULL    衛署字號
product_name / owner / manufacturer / manufacturer_address
ifu_full_code / ifu_version / ifu_publish_date
issued_date / expiry_date           到期日（90/60/30 提醒）
expiry_alert_days int               幾天前要提醒
is_current bool / superseded_by uuid → self  版本鏈
ifu_doc_id uuid                     → medsec_documents
created_by / created_at / updated_at / notes
```

**`medsec_qsd_certificates` — QSD 證書（13 欄）**

```
id, qsd_number NOT NULL, manufacturer, manufacturer_address,
issued_date, expiry_date, expiry_alert_days,
is_current bool, superseded_by uuid → self,
doc_id uuid → medsec_documents,
created_by, created_at, notes
```

**`medsec_qsd_approval_links` — QSD ↔ 衛署證 (2 欄)**

```
qsd_id uuid NOT NULL, approval_id uuid NOT NULL    複合 PK
```

**`medsec_approval_products` — 衛署證 ↔ 產品 (2 欄)**

```
approval_id uuid NOT NULL, product_code text NOT NULL    複合 PK
```

**`medsec_nhi_codes` — 健保碼（14 欄）**

```
id, nhi_code NOT NULL, code_type, product_code → medsec_products,
payment_points, patient_copay, hospital_price,
category, effective_date, expiry_date,
source, source_url, doc_id → medsec_documents, updated_at
```

#### 4.2.6 業務歷史 / 文件 / 知識庫 / 保證金（5 張，全 0 筆）

**`medsec_sales_history` — 歷史成交價（13 欄）**

```
id, sale_date NOT NULL, hospital_id, product_code,
quantity int, unit_price, total_amount, discount_amount,
order_no, invoice_no, sales_person_code,
imported_from, imported_at
```

> 給 secretary.html「報價優化」用 — AI 算建議價時的歷史 baseline。

**`medsec_pending_invoices` — 待開發票（11 欄）**

```
id, hospital_id, product_code, borrow_date, quantity int,
amount, order_no, status, expected_close_date,
imported_from, imported_at
```

**`medsec_documents` — 文件中央庫（13 欄）**

```
id, doc_type NOT NULL, title, storage_path NOT NULL, original_filename,
file_size bigint, mime_type, ocr_status, ocr_text,
ocr_extracted_data jsonb, version int, uploaded_by, uploaded_at
```

被 `medsec_case_documents` / `medsec_regulatory_approvals.ifu_doc_id` / `medsec_qsd_certificates.doc_id` / `medsec_nhi_codes.doc_id` 引用。

**`medsec_crm_chunks` — CRM 知識庫（11 欄）**

```
id, chunk_text NOT NULL, chunk_category NOT NULL,
hospital_id, parent_code, embedding USER-DEFINED (vector(1536) 之類),
metadata jsonb, source_secretary, source_excel, source_date, created_at
```

embedding 欄是 pgvector type，但 `data_type` 在 information_schema 顯示 `USER-DEFINED`。

#### 4.2.7 V3.3 新增 2 張（commit `564172d`）

**`medsec_consignment_inventory` — 寄售品庫存 / WIS07（12 欄）**

```
id uuid PK
hospital_id         text NOT NULL  → medsec_hospitals(id)
product_code        text NOT NULL  → medsec_products(id)
stock_qty           int  NOT NULL  default 0
monthly_avg_usage   numeric
earliest_expiry     date           最早效期，觸發 WIS07 換貨
last_inventory_date date
last_inventory_by   uuid           → profiles(id)
status              text NOT NULL  CHECK active/expiring/returned
notes               text
created_at / updated_at  NOT NULL
UNIQUE (hospital_id, product_code)
```

RLS：manager+secretary 全看 / sales 透過 `medsec_salesperson_assignments` 看自己分區；WRITE 只 manager+secretary。

**`medsec_product_units` — 單台序號保固 / WIS09（11 欄）**

```
id uuid PK
product_code        text NOT NULL  → medsec_products(id)
serial_no           text NOT NULL UNIQUE
hospital_id         text           → medsec_hospitals(id)（目前在哪家）
warranty_start      date
warranty_end        date
warranty_alert_days int default 30
status              text NOT NULL  CHECK in_use/returned/replaced/scrapped
install_case_id     uuid           → medsec_cases(id)（首次安裝那案件）
notes
created_at / updated_at  NOT NULL
```

RLS 同 consignment。

加 view `medsec_product_units_warranty`：

```sql
SELECT serial_no, warranty_end,
       (warranty_end - CURRENT_DATE) AS days_left,
       CASE WHEN warranty_end >= CURRENT_DATE THEN 'in_warranty'
            ELSE 'out_of_warranty' END AS warranty_status
FROM medsec_product_units WHERE serial_no = 'XYZ';
```

→ WIS09 自動分流：`in_warranty` 走保內換新 0 元、`out_of_warranty` 走維修報價。

**`medsec_tender_bonds` — 標案保證金（25 欄）**

```
id uuid PK
case_id              uuid → medsec_cases(id)
bond_type            text NOT NULL    bid_bond / perf_bond / warranty_bond
account_code / bank_account_code
amount               numeric NOT NULL
status               text             applied / paid_out / returned / expired / ...
applied_date / paid_out_date / expected_return_date / actual_return_date
warranty_period_months int            保固期月數
warranty_start_date / warranty_end_date
alert_60days / alert_30days / alert_at_expiry  bool   提醒 flags
ef_application_no                     EF 系統申請編號
ef_form_path                          EF 表單檔路徑
erp_voucher_no                        鼎新 ERP 傳票號
erp_form_type                         鼎新表單類型
contract_expiry_note / notes
created_at / updated_at
```

> 給 candy.html「保證金生命週期」 + accounting.html「押標金對帳」用。三類保證金都裝這張表。

### 4.3 V3 新增 3 張共用底層表

不在 `medsec_*` 前綴，但是 lvZzm 用 `01_extend_existing_schema.sql` 加進去的：

| 表 | 內容 | RLS |
|---|---|---|
| `hospital_systems` | 33 種體系（榮民 / 長庚 / 署立 / ...）| 全員工可讀，只 manager 可寫 |
| `product_base_prices` | 產品底價（FK → `medsec_products(id) text`） | **只 manager 可讀寫**（最高權限）|
| `medsec_salesperson_assignments` | 業務 ↔ 醫院 共管 normalized 結構 | 自己看自己 + manager 全看 |

### 4.4 `profiles`（既有，Week 1-2 建好）

- `id` (uuid PK = auth.users.id)
- `employee_id` (**text**，例 `0006` — 0 開頭會掉，不能改 integer)
- `name` / `nickname`
- `has_medteam_access` / `has_medsec_access` (bool)
- `medsec_role` (text)
- RLS：自己只能讀自己 row（`auth.uid() = id`）

> ⚠️ **`profiles` 沒有 `medteam_role` 欄**（V3.3 02 那支撞到才發現，HINT: `profiles.medsec_role` 才是正確欄名）。判定「是否業務」用 `has_medteam_access = true`，見 §13.3.

---

## 5. INVI02「掉 2000 筆」事件 + fix_inventory/ 修復

### 5.1 事件時序

| 時間 | commit | 事件 |
|---|---|---|
| 2026-05-13 09:57 | `ac4922f` | lvZzm session 把 1.4 MB 的 `05_seed_medsec_products.sql` 拆成 6 個 chunk（part1-6），每份 CHUNK_SIZE=1000，Lynn 預計依序貼進 SQL Editor 跑 |
| 跑完隔天 | — | 對源檔 5260 筆，DB `medsec_products` 只有 3239 筆 — 缺 2021 筆，且缺漏整段集中在 part3（2001-3000）+ part5（4001-5000）區間 |
| 本輪 | — | 重做 `fix_inventory/` 8 檔，**完整 5260 筆 UPSERT + ALTER 補 15 新欄**，已在 Supabase 跑過驗證 |

> Root cause 推測：拆檔程式 `tools/generate_seed_sql.py` `gen_medsec_products()` 的 chunking 邏輯有 `offset += 2000` 或類似 bug（應為 `+= 1000`），導致每隔一個 chunk 被跳過。`tools/` 還在 repo 裡但**不要再用它產 seed**，要重新運算 chunking 邏輯。

### 5.2 修復路徑（已執行完，留紀錄）

```
1. sql/fix_inventory/step0_alter_table.sql
   ALTER medsec_products ADD COLUMN：
     stock_qty, unit_cost, fee_type_code, fee_type,
     dms_category_code, dms_subcategory_code, warehouse_code,
     warehouse_name, description, supplier_code, supplier_name,
     last_cost_orig, last_cost_twd, material_cost, standard_cost
   → medsec_products 從 27 欄 → 42 欄

2. sql/fix_inventory/step1~6_upsert_products_part1~6.sql
   INSERT 5260 筆 ON CONFLICT (id) DO UPDATE SET …
   24 欄位 UPSERT（id, name, specification, catalog_number, uom,
     stock_qty, unit_cost, manufacturer_code, product_series,
     fee_type_code, fee_type, dms_category_code, dms_category,
     dms_subcategory_code, dms_subcategory, warehouse_code,
     warehouse_name, description, supplier_code, supplier_name,
     last_cost_orig, last_cost_twd, material_cost, standard_cost）

3. sql/fix_inventory/step7_verify.sql
   驗證 total = 5260 ✓（之前缺的 6 開頭、7 開頭品號都回來了）
```

### 5.3 已刪除的壞檔（git history 上仍可追溯）

```
sql/05_seed_medsec_products.sql              （1.4 MB 整份）
sql/05_seed_medsec_products_part1.sql ~ part6.sql （6 份）
```

刪檔 commit：`ddfb8a1`。要復原查史請 `git show ac4922f -- sql/05_seed_medsec_products.sql`。

### 5.4 衛署字號狀態

之前 lvZzm regex 從 INVI02「商品描述」抽出 **768 筆**結構化衛署字號（commit `0675f31`）。

**fix_inventory 沒額外處理衛署字號**（24 欄 UPSERT 不含 license_no）— `medsec_products` 也沒 license_no 欄；衛署資料**正規結構是 4 張表 join**：

```
medsec_regulatory_approvals (19 欄)
  ├─ approval_number       衛署字號
  ├─ expiry_date           到期日（cindie 90/60/30 提醒的關鍵）
  ├─ expiry_alert_days     提醒天數
  ├─ ifu_doc_id            → medsec_documents（IFU PDF）
  └─ is_current / superseded_by  版本鏈
        │
        ↓
medsec_approval_products (2 欄)
  (approval_id, product_code)   多對多 join
        │
        ↓
medsec_products (id = product_code)
        │
        ↓
medsec_qsd_approval_links (2 欄)
  (qsd_id, approval_id)         衛署證 ↔ QSD
        │
        ↓
medsec_qsd_certificates (13 欄)
  ├─ qsd_number / expiry_date / expiry_alert_days
  └─ doc_id → medsec_documents
```

目前 4 張**都是 0 筆**。後續要做 cindie.html 衛署 90/60/30 提醒功能，要：

1. 從 INVI02「商品描述」regex 抽出可結構化的 768 筆衛署字號
2. seed `medsec_regulatory_approvals`（一個 approval_number 一行 + 抓 expiry_date）
3. seed `medsec_approval_products`（approval → 對應的多個 product_code）
4. QSD 部分需要 Lynn 額外提供 PDF / Excel 來源（INVI02 沒這欄）

---

## 6. 接手怎麼開始（V3.2 後）

### 6.1 確認 Supabase 已套用的內容

跑這支驗證：

```sql
select 'medsec_hospitals'     as t, count(*) from public.medsec_hospitals       union all
select 'medsec_products'      as t, count(*) from public.medsec_products        union all
select 'medsec_secretary_assignments',  count(*) from public.medsec_secretary_assignments  union all
select 'medsec_salesperson_assignments',count(*) from public.medsec_salesperson_assignments;
-- 預期：185 / 5260 / 182 / 236
```

不對的話依下面補。

### 6.2 如果某張表還沒 seed

| 表 | seed 檔 |
|---|---|
| `hospital_systems`（33 體系）| `sql/03_seed_hospital_systems.sql` |
| `medsec_hospitals`（184 醫院）| `sql/04_seed_medsec_hospitals.sql` |
| `medsec_products`（5260 產品）| `sql/fix_inventory/step0_alter_table.sql` → `step1` → ... → `step6` → `step7_verify.sql` |
| `medsec_secretary_assignments`（182 業祕）| `sql/06_seed_medsec_secretary_assignments.sql` |
| `medsec_salesperson_assignments`（236 業務）| `sql/07_seed_medsec_salesperson_assignments.sql` |

**不要再用 `sql/IMPORT_GUIDE.md` 的 Step 5**（指向已刪的 `05_*`），products 一律走 `fix_inventory/`。

### 6.3 RLS 守門驗證（最重要）

用無痕視窗逐角色登入 `login.html`：

| 帳號 | 期望結果 |
|---|---|
| 雅婷 `0168`（secretary）| 看到約 57 家醫院 |
| 莊新力 `0087`（sales）| 看到約 11 家 |
| Lynn `0006`（manager）| 看到全部 185 家 |
| Candy `0132` / Cindie `0003` / 會計 `0176` | 看到全部 185 家 |

確認方法（前端 console）：

```js
const { data } = await supa.from('medsec_hospitals').select('id, name_short');
console.log(data?.length);
```

### 6.4 Week 3-1 動 `medsec_cases`

`medsec_cases` schema 已存在（29 欄，§4.2.1），但**動之前要 Lynn 回 §9 四題**（特別是案件編號格式 + status enum + medteam-app 怎麼 INSERT 進來）。

---

## 7. 重要設計規範

### 7.1 配色（CSS 變數，`medsec-common.css`）

```css
--primary:        #1e3a8a;   /* 深靛 */
--primary-light:  #3b82f6;
--primary-dark:   #1e293b;
--accent:         #6366f1;

--role-manager:     #7c3aed;
--role-bidding:     #0891b2;
--role-purchasing:  #ea580c;
--role-accounting:  #16a34a;
--role-secretary:   #db2777;
```

### 7.2 不要做的事

- ❌ 不引框架（React / Vue / Svelte）
- ❌ 不引 build step（vite / webpack）
- ❌ 不在頁面內 hardcode Supabase URL/key（共用變數在 `medsec-common.js`）
- ❌ 不用 inline `<style>`（樣式統一進 `medsec-common.css`）
- ❌ 不要寫 `supa.from('medsec_products').select('*')`（5260 筆撈光，要走 `search_medsec_products` RPC）
- ❌ 不要再用 `tools/generate_seed_sql.py` 產 products seed（chunking bug，見 §5）
- ❌ 不要在 commit / PR 提到模型名稱

### 7.3 產品搜尋（前端範例）

```js
// ✓ 用 RPC（伺服端 trgm 比對，回 10 筆最像的）
const { data } = await supa.rpc('search_medsec_products', { q: '內視鏡', max_results: 10 });

// ✗ 不要這樣（5260 筆全撈）
const { data } = await supa.from('medsec_products').select('*');
```

### 7.4 共用 helper 走 `medsec-common.js`

新加 data-access 函數一律加在 `medsec-common.js` 裡 export，不要每個 HTML 各複製貼上 supabase 呼叫。

既有 export：`supa` / `guardRole(role)` / `currentProfile` / `renderUserInfo` / `handleLogout` / `switchModule` / `hideLoading` / `ROLE_PAGE_MAP` / `ROLE_LABEL_MAP` / `ROLE_TAG_CLASS`.

---

## 8. 踩過的坑（不要再踩）

### 8.1 anon key zero-width space

從 Supabase Studio 複製 anon key 有時頭尾多隱形字元 → 401。長度應該 ~220 字。每次更新 key 後**強制刷新瀏覽器**（Ctrl+Shift+R）。

### 8.2 必須用無痕視窗測角色守門

非無痕會記前一個 session、永遠看自己 cache 的 profile。測「越權」一定要無痕。

### 8.3 員工編號 text 不要 integer

`0006` 是 text，改 integer 會變 6。

### 8.4 鼎新 xlsx 匯出有壞 style

COPI01 / INVI02 用 openpyxl 讀會掛（`_NamedCellStyle.name should be str but None`），改用 `xlsx2csv` 套件穩定。

### 8.5 「鄒婉萱(SCS)」/「子恩(SPS)」括號註記

CSV 業務全名有時帶 `(SCS)` `(SPS)` 品牌標註。`split_names()` 內已 regex 去掉括號內容才能對到員工。

### 8.6 Supabase Studio CSV import 不支援自動 FK lookup

舊版 `hospitals.csv` 有 `system_code` 但表是 `system_id` (uuid)。  
→ 解法：先 import 到 tmp table，再 SQL 一支 join 寫進正式表。

> V3.1 之後 `medsec_hospitals.id` / `medsec_products.id` 改用 text PK（COPI01 客戶代號 / INVI02 品號），不再需要 lookup，這個坑只在歷史 V1/V2 SQL 草稿裡。

### 8.7 既有 schema 的型別不要猜（V3 大教訓）

V3 初版直接寫 `references medsec_hospitals(id)` 假設 uuid，結果報 `ERROR 42883 text=uuid`。
→ 動既有 schema 之前一律先跑：

```sql
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='medsec_xxx';
```

### 8.8 SQL Editor 拆檔程式有 chunking bug

`tools/generate_seed_sql.py gen_medsec_products()` 拆 part1-6 時跳過了 part3、part5 範圍 → DB 少 2021 筆。已用 `sql/fix_inventory/` 取代，但 `tools/` 還在 repo（**不要再呼叫產 products seed**，要先修 chunking 邏輯）。

### 8.9 Supabase Studio export CSV 截斷

跑 `information_schema.columns` 想匯 22 張表全欄 schema，CSV export 在 100 行截斷（看起來是 Studio 預設 limit）。要拿完整 schema 要在 SQL Editor 結果頁先 `LIMIT 9999` 或改用 psql 直連。

---

## 9. ✅ Lynn 已拍板 §9 五題（V3.3）

原 4 題 + 補 1 題 SOP，全部已拍板。SQL 已落地（`sql/v33/`），詳 §13。

| # | 問題 | Lynn 拍板（節錄） |
|---|---|---|
| 1 | `medsec_cases` ↔ medteam-app 關聯 | **方案 A 共用同表**。業務在 medteam-app 直接 INSERT 一筆，`source='medteam-app'`、`requested_by_user_id=auth.uid()`。RLS 走 `sql/v33/02_*` 新增的 2 個 policy。 |
| 2 | `case_no` 格式 | `{erp_doc_code}-{YYMMDD}-{NNN}`，trigger 自動。例 `AECC-260513-001`。13 種 `action_type` × 2 公司，erp_doc_code 25 種映射見 `sql/v33/00_DECISIONS.md` §Q2。 |
| 3 | `status` 完整 enum | 9 種：`pending` / `claimed` / `packaging` / `pending_decision` / `decided` / `crm_sent` / `closed` / `returned` / `pending_supplement`。提醒規則見 `00_DECISIONS.md` §Q3。 |
| 4 | AI 決策包引擎 | **V1 純 SQL aggregate，不調 LLM**。reasoning 用字串模板。函式 `compute_case_decision_package(case_id)`。V2 再加 Claude API。 |
| 5 | SOP 流程提示（Lynn 新需求）| 不讓業祕主動查 SOP，做成系統依 `(action_type, status)` 自動跳提示卡。`medsec_cases.sop_ref` 由 trigger 帶。V1 範圍 8-12 個硬編碼提示卡。 |

完整原文：[`sql/v33/00_DECISIONS.md`](sql/v33/00_DECISIONS.md)。

---

## 10. Lynn 偏好

- **直接**。不要寫「您好我是 AI 助理」這種開場。
- **不過度問**。能從上下文推出來的不問。需要選擇時，給 2-3 個選項 + 推薦。
- **繁中、台灣用語**（軟體 / 伺服器 / 專案 / 影片）。
- **不用 emoji**（產品檔內既有的 icon emoji 留著）。
- **不過度抽象**。三段相似程式碼比一個過早抽象好。
- **commit message 說「為什麼」**而非「改了什麼」。
- **commit / PR 不寫模型 ID**。

---

## 11. 待補的事

### 11.1 衛署 / QSD seed

`medsec_regulatory_approvals` / `medsec_qsd_certificates` / `medsec_approval_products` / `medsec_qsd_approval_links` 4 張都是 0 筆。cindie.html 的衛署 90/60/30 提醒做不出來。需要：

- 從 INVI02「商品描述」regex 抽出 768 筆建構半結構化資料（§5.4 流程）
- Lynn 額外提供 QSD 證書源檔（PDF / Excel）— INVI02 沒這欄

### 11.2 產品底價

`product_base_prices` 是空的（V3 拆獨立表時就決定等 Lynn 提供）。

### 11.3 業務歷史 / 健保碼 / 待開發票 seed

`medsec_sales_history` / `medsec_nhi_codes` / `medsec_pending_invoices` 全 0 筆。secretary 報價優化要看歷史成交價，要先有這些資料。需要 Lynn 提供匯出來源（鼎新 / 健保署 / 內部 Excel）。

> ⚠️ `compute_case_decision_package()` 在 `medsec_sales_history` seed 之前跑出來會全是 NULL / 0、信心度 0。函式已備好但無米下鍋。

### 11.4 V3.3 兩張新表 seed

`medsec_consignment_inventory`（WIS07 寄售品）+ `medsec_product_units`（WIS09 單台序號保固）都是 0 筆。需要：

- 寄售品：Lynn / 業祕從鼎新或盤點表手動匯
- 序號：從 WIS08 交貨單回填，或從原廠出貨資料匯

### 11.5 medteam-app 端「提詢價」按鈕

V3.3 動工順序 Step 8。SQL 端已準備好（medsec_cases RLS policy + schema），等 medteam-app 那邊規劃 + 實作。

---

## 12. 最後叮嚀

照順序：

1. ✅ 確認 §6.1 四張 seed 數字對得上
2. ✅ Lynn §9 五題拍板 → V3.3 SQL 批次（`sql/v33/`）schema 落地
3. ⏳ Lynn 把 `sql/v33/` 01–05 五支貼進 SQL Editor 跑，順序見 `sql/v33/README.md`
4. ⏳ 從 INVI02「商品描述」抽 768 筆衛署字號 → seed `medsec_regulatory_approvals` + `medsec_approval_products` → 接 cindie.html 90/60/30 提醒（§5.4 + §11.1）
5. ⏳ Lynn 提供歷史成交價 → seed `medsec_sales_history` → `compute_case_decision_package()` 才有米下鍋（§11.3）
6. ⏳ Lynn 拿底價檔 → 灌 `product_base_prices`（§11.2）
7. ⏳ medteam-app 端做「提詢價」按鈕（V3.3 動工順序 Step 8）
8. ⏳ 前端寫 SOP 提示卡 8-12 個（V3.3 Q5 範圍）
9. ⏳ Week 3-2 起依路線圖推

碰到沒寫到的情境 → 直接問 Lynn，不要自己猜。

— 接手 · 2026-05-13 V3.3（Lynn §9 拍板後）

---

## 13. V3.3 SQL 批次摘要（commit `564172d`）

完整代碼在 `sql/v33/`。給 Lynn 套用 + 後人快速看懂。

### 13.1 套用順序

| Step | 檔 | 動作 | 時間 |
|---|---|---|---|
| 1 | `01_alter_medsec_cases.sql` | medsec_cases ALTER 4 欄 + status 9 種 + 2 個函數 + autofill trigger | 5 秒 |
| 2 | `02_medsec_cases_sales_insert_policy.sql` | `auth_medteam_role()` + 2 條新 policy（不動既有 2 條） | 5 秒 |
| 3 | `03_consignment_inventory.sql` | 建 `medsec_consignment_inventory` + RLS | 5 秒 |
| 4 | `04_product_units.sql` | 建 `medsec_product_units` + RLS + warranty view | 5 秒 |
| 5 | `05_decision_package_function.sql` | `compute_case_decision_package()` V1 純 aggregate | 5 秒 |

### 13.2 新增 / 修改的 schema 物件清單

**新增表（2）**
- `medsec_consignment_inventory`（WIS07）
- `medsec_product_units`（WIS09）

**新增 view（1）**
- `medsec_product_units_warranty`（自動分流 in/out warranty）

**新增 function（5）**
- `calc_erp_doc_code(company, action_type) → text` — 25 種映射
- `calc_sop_ref(action_type) → text` — WIS01~WIS10
- `medsec_cases_autofill()` trigger function
- `auth_has_medteam_access() → boolean` — sales gate（V3.3 改用 boolean，profiles 沒 medteam_role）
- `compute_case_decision_package(case_id) → jsonb` — V1 決策包

**新增 trigger（3）**
- `medsec_cases_autofill_trg` — BEFORE INSERT/UPDATE
- `mci_updated_at` / `mpu_updated_at` — touch updated_at

**新增 RLS policy（6）**
- `medsec_cases_sales_insert` / `medsec_cases_sales_select`
- `mci_select` / `mci_write`
- `mpu_select` / `mpu_write`

**修改 medsec_cases（既有表，只 ALTER 不 DROP）**
- 補 4 欄、補 / 改 3 條 CHECK（company / action_type / status）

### 13.3 設計決策（為什麼這樣寫）

1. **`erp_doc_code` 用 BEFORE trigger 不用 generated column** — Lynn 拍板 secretary 可改 AECO → AEEQ/AEIN。Generated column 在 UPDATE 會強制重算覆蓋掉手動修改。Trigger 只在 INSERT NULL 時帶預設，UPDATE 不動。
2. **`case_no` 在 trigger 即席算流水** — V1 業務量低，accept race condition。V2 改 advisory lock 或 day-stamped sequence。
3. **`compute_case_decision_package` 寫 SECURITY DEFINER** — 跨 RLS 邊界讀 `medsec_sales_history` 等表算 aggregate。沒這個 sales 透過 RLS 看不到別人的成交歷史。
4. **不 DROP 既有 22 張表的 policy** — Lynn V3.3 Q4 守則。所有 V3.3 policy 都用 `DROP POLICY IF EXISTS <new_name>` 後 `CREATE POLICY <new_name>`，不覆寫既有的。
5. **sales gate 用 `has_medteam_access` boolean 不用 `medteam_role` enum** — `profiles` schema 實際上沒有 `medteam_role` 欄（HANDOVER 舊版 §4.4 寫錯）。02 那支套用時撞到才修正。函數名也從 `auth_medteam_role()` 改 `auth_has_medteam_access()` 反映實際語義。功能等價：「有 medteam-app 存取 = 業務」。

### 13.4 已知限制

- `compute_case_decision_package()` 在 `medsec_sales_history` seed 之前跑出來會全是 NULL / 信心度 0 — 函式 OK，沒米下鍋。
- SOP 提示卡是 HTML 端工作，這批 SQL 沒做。
- medteam-app 端「提詢價」按鈕還沒做（V3.3 動工順序 Step 8 由 Lynn 另外規劃）。
