# HANDOVER.md — AE MED Hub · medsec-app

> 給接手的 AI / 工程師：請從頭看完這份再動工。
> Lynn 的時間很貴，不要重複前人的坑。
> 最後更新：2026-05-13 · 分支 `claude/continue-work-pZToe` · V3.2（fix_inventory 之後）

---

## 0. 目前進度（一眼看完）

| 階段 | 狀態 | 備註 |
|---|---|---|
| Week 1-2 主檔建立（profiles）| ✅ 完成 | 60 員工資料、5 個 medsec_role 開通、profiles RLS |
| Week 3-0 角色頁面骨架 | ✅ 完成 | login + 5 角色 html + medsec-common.js / css |
| Week 3-0.5 共用底層 schema 擴充 | ✅ 完成 | `hospital_systems` / `product_base_prices` / `medsec_salesperson_assignments` 3 張 ADD 完 |
| Week 3-0.6 主檔 seed | 🟡 部分完成 | hospitals 185 ✓、products 5260 ✓、secretary_assignments 182 ✓、salesperson_assignments 236 ✓；其餘 18 張 medsec_* 表 0 筆 |
| **Week 3-0.7 INVI02 修復**（本輪）| ✅ 完成 | 從 3239 → 5260，補 15 欄位（cost / supplier / dms / warehouse），詳 §5 |
| Week 3-1 報價模組 | ⏳ schema 已建 0 筆 | 22 張 medsec_* 表都已 enabled RLS。動之前要回 §9 四題 |
| Week 3-2 ~ 3-5 | ⏳ 排隊 | |

---

## 1. 專案總覽

### 1.1 我是誰

**AE MED Hub · medsec-app**（業務祕書平台）。亞洲鷹眼醫療儀器股份有限公司內部 SaaS。跟同公司另一個專案 `medteam-app`（業務團隊用）**共用 Supabase project `yincuegybnuzgojakkuc` + 帳號系統**，但兩個 app 各自獨立部署。

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

---

## 4. Supabase Schema 現狀（V3.2）

### 4.1 22 張 medsec_* 表總覽

來源：`information_schema.columns` + `pg_tables.rowsecurity` + `pg_policies` + 動態 row_count CTE（2026-05-13）。

| # | 表 | 欄位數 | 已 seed 筆數 | RLS | Policy 數 | 用途 |
|---|---|---|---|---|---|---|
| 1 | `medsec_hospitals` | (未拿到) | **185** | ✅ | 1 | 醫院主檔（COPI01）|
| 2 | `medsec_products` | **42**（含 fix_inventory 15 新欄）| **5260** | ✅ | 1 | 產品主檔（INVI02）|
| 3 | `medsec_secretary_assignments` | (未拿到) | **182** | ✅ | 1 | 業祕分區（主祕 + 副祕） |
| 4 | `medsec_salesperson_assignments` | (V3 新建)| **236** | ✅ | 2 | 業務共管分區 |
| 5 | `medsec_cases` | **29** | 0 | ✅ | 2 | 業祕案件（詢價 / 建碼 / 標案）|
| 6 | `medsec_case_items` | 10 | 0 | ✅ | 1 | 案件下的多個產品項 |
| 7 | `medsec_case_documents` | 10 | 0 | ✅ | 1 | 案件附文件 |
| 8 | `medsec_case_timeline` | 7 | 0 | ✅ | 1 | 案件事件流 |
| 9 | `medsec_crm_chunks` | 11 | 0 | ✅ | 1 | CRM 知識庫（含 embedding） |
| 10 | `medsec_discount_rules` | 17 | **3** | ✅ | 1 | 折扣規則（已有 3 筆測試）|
| 11 | `medsec_documents` | 13 | 0 | ✅ | 2 | 文件中央庫（含 OCR 欄）|
| 12 | `medsec_approval_products` | 2 | 0 | ✅ | 1 | 衛署證 ↔ 產品 join |
| 13 | `medsec_regulatory_approvals` | (未拿到) | 0 | ✅ | 1 | 衛署證主檔 |
| 14 | `medsec_qsd_certificates` | (未拿到) | 0 | ✅ | 1 | QSD 證書 |
| 15 | `medsec_qsd_approval_links` | (未拿到) | 0 | ✅ | 1 | QSD ↔ 衛署證 關聯 |
| 16 | `medsec_nhi_codes` | (未拿到) | 0 | ✅ | 1 | 健保碼 |
| 17 | `medsec_hospital_doc_templates` | (未拿到) | 0 | ✅ | 1 | 醫院文件模板 |
| 18 | `medsec_hospital_operation_rules` | (未拿到) | 0 | ✅ | 1 | 醫院操作規則 |
| 19 | `medsec_hospital_shipping_addresses` | (未拿到) | 0 | ✅ | 1 | 醫院收貨地址 |
| 20 | `medsec_pending_invoices` | (未拿到) | 0 | ✅ | 1 | 待開發票 |
| 21 | `medsec_sales_history` | (未拿到) | 0 | ✅ | 1 | 歷史成交價 |
| 22 | `medsec_tender_bonds` | (未拿到) | 0 | ✅ | 1 | 標案保證金 |

**RLS 摘要：22 張全部 enabled，0 張裸奔。** policy 數 1–2 之間，多數為 1。

**Seed 摘要：4 張有實質資料（185+5260+182+236=5863 筆）+ 1 張測試（3 筆 discount_rules）。其餘 17 張是空殼框架。**

### 4.2 已知欄位細節（8 張）

> 來源 CSV 在 Supabase Studio export 時被截斷在 100 行。剩 14 張 schema 待 Lynn 重 export（見 §11）。

#### 4.2.1 `medsec_cases` — V1 報價模組的核心（29 欄）

```
id                       uuid       PK
case_no                  text                 案件編號（格式待 Lynn 拍 §9 第 2 題）
case_type                text       NOT NULL  詢價 / 建碼 / 標案 / ...
quote_subtype            text
hospital_id              text                 → medsec_hospitals(id)
status                   text       NOT NULL  狀態 enum 待 Lynn 拍 §9 第 3 題
current_owner_id         uuid                 目前負責人
current_owner_role       text                 'bidding_team' / 'secretary' / 'manager'
bidding_owner_id         uuid                 標案階段負責人
post_bid_secretary_id    uuid                 得標後轉給的業祕
handover_at              timestamptz          交接時間
source                   text                 從哪來：'medteam-app' / 'manual' / ...
source_request_id        uuid                 對應 medteam-app 詢價單 ID（§9 第 1 題）
requested_by_user_id     uuid                 業務 ID
title                    text       NOT NULL
description              text
tender_no                text                 標案編號
tender_budget            numeric
tender_open_date         date
due_date                 date
ai_suggested_price       numeric              AI 建議價
ai_confidence            numeric              AI 信心度
manager_decision         text                 Lynn 決策結果
manager_final_price      numeric              Lynn 拍板價
manager_decided_at       timestamptz
manager_decided_by       uuid
created_at               timestamptz
updated_at               timestamptz
closed_at                timestamptz
```

#### 4.2.2 `medsec_case_items` — 案件項目（10 欄）

```
id, case_id, product_code, quantity (NOT NULL), unit_price,
ai_suggested_price, final_price, discount_rate, notes, created_at
```

#### 4.2.3 `medsec_case_documents` — 案件附文件（10 欄）

```
id, case_id, document_id, doc_category, doc_name, is_required,
upload_status, notes, uploaded_by, uploaded_at
```

#### 4.2.4 `medsec_case_timeline` — 案件事件流（7 欄）

```
id, case_id, event_type (NOT NULL), event_data (jsonb), actor_id,
description, created_at
```

#### 4.2.5 `medsec_crm_chunks` — CRM 知識庫（11 欄）

```
id, chunk_text (NOT NULL), chunk_category (NOT NULL), hospital_id,
parent_code, embedding (USER-DEFINED → 應該是 vector(1536) 之類),
metadata (jsonb), source_secretary, source_excel, source_date, created_at
```

#### 4.2.6 `medsec_discount_rules` — 折扣規則（17 欄，已有 3 筆測試）

```
id, hospital_id, parent_code, product_code, product_line,
calc_method (NOT NULL), fixed_amount, percentage_rate, donation_amount,
description, applicable_period, source, is_active, effective_date,
expiry_date, created_at, updated_at
```

#### 4.2.7 `medsec_documents` — 文件中央庫（13 欄）

```
id, doc_type (NOT NULL), title, storage_path (NOT NULL), original_filename,
file_size (bigint), mime_type, ocr_status, ocr_text, ocr_extracted_data (jsonb),
version (integer), uploaded_by, uploaded_at
```

#### 4.2.8 `medsec_approval_products` — 衛署證 ↔ 產品 join（2 欄）

```
approval_id (uuid, NOT NULL), product_code (text, NOT NULL)
```

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
- `medteam_role` / `medsec_role` (text)
- RLS：自己只能讀自己 row（`auth.uid() = id`）

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

**fix_inventory 沒額外處理衛署字號**（24 欄 UPSERT 不含 license_no）— 衛署相關欄位仍在 `medsec_regulatory_approvals` / `medsec_approval_products` / `medsec_qsd_certificates` / `medsec_qsd_approval_links`，目前**都是 0 筆**。後續要做衛署 90/60/30 提醒功能（cindie.html），要先 seed 這 4 張表。

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

## 9. ⏳ 等 Lynn 拍板的 4 題（動 Week 3-1 之前要回）

| # | 問題 | 用途 |
|---|---|---|
| 1 | `medsec_cases` ↔ medteam-app 怎麼關聯？業務在 medteam INSERT 進 `medsec_cases`（共用同表），還是 medteam 有自己的 `medteam_cases`、靠 `source_request_id` 外鍵？ | 影響 schema 設計 |
| 2 | 案件編號（`case_no`）格式（`YYMMDD-NNN`？`MS-2026-0001`？）| 影響 trigger |
| 3 | `medsec_cases.status` 完整 enum（pending → claimed → packaging → pending_decision → decided → crm_sent → closed？有沒有「退回」「補件」？）| 影響 enum |
| 4 | AI 決策包用什麼引擎（Claude API / OpenAI / SQL aggregate）？影響 `medsec_cases.ai_suggested_price` 怎麼算 + 決策 reasoning 存哪 | 影響架構 |

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

### 11.1 完整 schema CSV

§4.2 只詳列 8 張表（CSV 截斷在 100 行）。請在 Supabase SQL Editor 重跑：

```sql
select table_name, ordinal_position, column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and table_name like 'medsec_%'
order by table_name, ordinal_position;
-- 然後在結果頁右上點「Export to CSV」（不要從 snippet 頁的截斷 export）
```

CSV 上傳之後我把 §4.2 的 14 張 schema 補完。

### 11.2 衛署 / QSD seed

`medsec_regulatory_approvals` / `medsec_qsd_certificates` / `medsec_approval_products` / `medsec_qsd_approval_links` 4 張都是 0 筆。cindie.html 的衛署 90/60/30 提醒做不出來。需要：

- Lynn 提供衛署證源檔（PDF / Excel）
- 或從既有 INVI02「商品描述」regex 抽 768 筆建構半結構化資料

### 11.3 產品底價

`product_base_prices` 是空的（V3 拆獨立表時就決定等 Lynn 提供）。

### 11.4 等 Lynn 拍 §9 四題

---

## 12. 最後叮嚀

照順序：

1. ✅ 確認 §6.1 四張 seed 數字對得上
2. ⏳ 重跑 §11.1 query 把完整 schema 給我補 §4.2
3. ⏳ 等 Lynn 拿底價檔 → 灌 `product_base_prices`
4. ⏳ 等 Lynn 拍 §9 四題 → 動 `medsec_cases` 接 medteam-app 詢價
5. ⏳ 依 §11.2 seed 衛署 → 接 cindie.html 90 天提醒
6. ⏳ Week 3-2 起依路線圖推

碰到沒寫到的情境 → 直接問 Lynn，不要自己猜。

— 接手 · 2026-05-13 V3.2
