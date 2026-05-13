# HANDOVER.md — AE MED Hub · medsec-app

> 給接手的 AI / 工程師：請從頭看完這份再動工。
> Lynn 的時間很貴，不要重複前人的坑。
> 最後更新：2026-05-13 · 分支 `claude/continue-work-lvZzm` · commit `93c2110`

---

## 0. 目前進度（一眼看完）

| 階段 | 狀態 | 備註 |
|---|---|---|
| Week 1-2 主檔建立（profiles）| ✅ 完成 | 60 員工資料、5 個 medsec_role 開通、profiles RLS |
| Week 3-0 角色頁面骨架 | ✅ 完成 | login + 5 角色 html + medsec-common.js / css |
| **Week 3-0.5 共用底層 schema + seed**（本輪新增）| ✅ **SQL 草稿就緒，待 Lynn review + 套用** | sql/01-06 + sql/data/*.csv |
| Week 3-1 報價模組 schema | ⏳ 等 Lynn 拍板（4 題見 §9）| 動 `medsec_cases` 之前要先回 4 題 |
| Week 3-2 ~ 3-5 | ⏳ 排隊 | |
| Week 6+ | ⏳ 排隊 | |

---

## 1. 專案總覽

### 1.1 我是誰

**AE MED Hub · medsec-app**（業務祕書平台）。亞洲鷹眼醫療儀器股份有限公司內部 SaaS。跟同公司另一個專案 `medteam-app`（業務團隊用）**共用 Supabase project + 帳號系統**，但兩個 app 各自獨立部署。

### 1.2 5 角色清單（已實作守門）

| `medsec_role` | 中文 | 對應頁面 | 真人 / 員工編號 | 角色色 |
|---|---|---|---|---|
| `manager` | 管理者 | `manager.html` | 賴瑩 `0006`（Lynn）| 紫 `#7c3aed` |
| `bidding_team` | 標案團隊 | `candy.html` | 鄭欣菱 `0132`（Candy）| 青 `#0891b2` |
| `purchasing` | 採購 | `cindie.html` | 周佳蓉 `0003`（Cindie）| 橘 `#ea580c` |
| `accounting` | 會計 | `accounting.html` | 陳靖雅 `0176` | 綠 `#16a34a` |
| `secretary` | 業務祕書 | `secretary.html` | 4 人主分區 ↓ | 桃紅 `#db2777` |

### 1.3 業祕主分區 4 人（Lynn 拍板優先開通）

| 暱稱 | 員工編號 | 全名 | 負責家數 |
|---|---|---|---|
| 雅婷 | `0168` | 關雅婷 | 57 |
| 小飛 | `0011` | 楊斯閔 | 53 |
| 映晨 | `0150` | 黃映晨 | 45 |
| 伶華 | `0020` | 魏伶華 | 34 |

> 業祕課其實還有 4 位（彭冠豪 0129、翁若安 0140、許華翔 0156、施劭宜 0167）。V1 暫不開 `has_medsec_access`，避免代理人 RLS 變複雜。

### 1.4 技術棧

- **前端**：純靜態 HTML / CSS / Vanilla JS（不引框架、不引 build step）
- **CDN**：`@supabase/supabase-js@2`
- **字體**：Google Fonts `Noto Sans TC`
- **後端**：Supabase（Auth + Postgres + RLS + Storage 預留）
- **部署**：靜態檔托管 — repo `asiaeagle-source/medsec-app`

---

## 2. 檔案結構（最新）

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
├── sql/                           ← Supabase schema + seed（本輪新增）
│   ├── README.md
│   ├── IMPORT_GUIDE.md            ← Lynn 套用 Supabase 的 step-by-step
│   ├── mapping_report.md          ← 5 份原始檔暱稱 mapping 報告
│   ├── sources_inventory.md       ← 原始檔欄位盤點 + 策略決策
│   ├── 01_shared_schema.sql       ← 共用底層 schema（hospitals/products/...）
│   ├── 02_shared_rls.sql          ← RLS + helper functions + search_products RPC
│   ├── 03_seed_hospital_systems.sql  ← 33 種體系
│   ├── 06_seed_assignments.sql    ← 423 筆 業務+業祕 分區
│   └── data/                      ← Studio Import 用 CSV
│       ├── employees_for_review.csv         (60 員工)
│       ├── hospital_systems.csv             (33 體系)
│       ├── hospitals.csv                    (184 家醫院)
│       ├── products.csv                     (5239 筆產品，25 MB)
│       └── hospital_assignments.csv         (423 筆分區)
│
└── tools/                         ← 從原始檔產資料的 Python 腳本（本輪新增）
    ├── generate_import_data.py    ← 讀 5 份原始檔 → 產 CSV
    └── generate_seed_sql.py       ← 從 CSV → 產 INSERT SQL
```

---

## 3. AE Hub 分層原則（**最重要的架構決策**）

Lynn 拍板：**「員工 / 客戶 / 區域分配等等底層資料」全 AE Hub 共用**。

### 3.1 共用底層（不加前綴）

| 表 | 內容 | 用到的 app |
|---|---|---|
| `profiles` | 60 員工 + role flag | 全 app（已建）|
| `hospital_systems` | 33 種體系（榮民 / 長庚 / 署立 / …）| 全 app |
| `hospitals` | 184 家醫院主檔（COPI01）| 全 app |
| `products` | 5239 筆產品（INVI02）| 全 app |
| `hospital_assignments` | 通用「誰負責哪家」分配 | 全 app |
| `product_base_prices` | 產品業務底價 | **只 manager 可讀寫** |

### 3.2 medsec-app 專屬（`medsec_` 前綴）

V1 預計建這 4 張表（Week 3-1+）：

- `medsec_cases` — 業祕案件（業務詢價 / 建碼需求）
- `medsec_case_items` — 案件項目（每個案件下的多個產品）
- `medsec_quote_decisions` — 決策包（AI 自動組裝 + Lynn 採納 / 調整）
- `medsec_bonds` — 保證金（押標 / 履保 / 保固）

---

## 4. Supabase Schema 現狀

### 4.1 已建好（Week 1-2）

`profiles` 表既有欄位重點：
- `id` (uuid PK = auth.users.id)
- `employee_id` (text，例 `0006`) — 員工編號（**text 不是 integer**，0 開頭會掉）
- `name` / `nickname`
- `has_medteam_access` / `has_medsec_access` (bool)
- `medteam_role` / `medsec_role` (text)

`profiles` RLS：自己只能讀自己 row（`auth.uid() = id`）。

### 4.2 待 Lynn review + 套用（本輪產出）

`sql/01_shared_schema.sql` 建 5 張表 + 1 個 trigger function：
- `hospital_systems`（33 種）
- `hospitals`（含 COPI01 全 159 欄位的精選 + 全欄存 `raw_copi01_data` jsonb）
- `products`（INVI02 5239 筆 + 全欄存 `raw_invi02_data` jsonb）
- `hospital_assignments`（含 enum `salesperson` / `secretary` / `backup_secretary`）
- `product_base_prices`（**獨立鎖 manager**，等 Lynn 底價檔）

`sql/02_shared_rls.sql` 開：
- Helper functions：`auth_medsec_role()`、`is_global_hospital_viewer()`、`can_see_hospital()`
- 5 表 RLS policy
- `search_products(q, max_results)` RPC（前端唯一查產品入口）
- `hospitals_with_system` view（自動 join 體系，給前端方便用）

### 4.3 RLS 守門邏輯一覽

| 表 | SELECT | INSERT/UPDATE/DELETE |
|---|---|---|
| `profiles` | 自己 | 自己 |
| `hospital_systems` | 全員工 | 只 manager |
| `hospitals` | 業務/業祕只看分配；manager/Candy/Cindie/會計 全看 | 只 manager |
| `products` | 全員工（但前端走 `search_products` RPC）| 只 manager + purchasing |
| `hospital_assignments` | 自己 + 代理人 + manager | 只 manager |
| `product_base_prices` | **只 manager** | **只 manager** |

⚠️ 如果未來 Candy / Cindie / 會計 要分區，改 `is_global_hospital_viewer()` 函數。

---

## 5. 主檔資料現狀（待套用）

### 5.1 來源檔 5 份

| 來源 | 用途 |
|---|---|
| `_______4.xlsx` 員工總表 | 60 員工 → profiles |
| `0fc190f9-COPI01_1.XLSX` | 301 客戶 → 篩 184 醫院 + 33 體系 |
| `719f7d88-INVI02_1.XLSX` | 5260 筆 → 篩 5239 產品（商品分類一=商品）|
| `93c2ca1b-hospitals_template_20260505_filled.csv` | Lynn 親自填的醫院白名單 185 家 |
| `239363ab-_____202605111.xlsx` 分區歷史 | 取 `20260511分區` 欄當業祕最新分區 |

### 5.2 業務暱稱 mapping（Lynn 已拍板）

44 個業務暱稱，已對到員工編號 38 個 / 離職 1 個（JOSIE）/ 找不到 5 個（宇容 / 小駱 / 欣怡 / 欣翎 / 靜彤 已補 0077 董靜彤）。

> 完整 mapping：`sql/mapping_report.md`

### 5.3 醫院 4 個特殊處理

| 醫院 | 處理 |
|---|---|
| 員榮（CSV 缺 code）| Lynn 拍板：= COPI01 `S-YUM` |
| 星采（CSV 缺 code）| Lynn 拍板：= COPI01 `C02` |
| 博仁綜合醫院（COPI01 沒）| Lynn 拍板：跳過 |
| 天祥醫院 TNTC（xlsx 獨有）| Lynn 拍板：= 天成（已不納入主檔，CSV 未列）|

### 5.4 衛署字號

INVI02 沒有獨立的衛署字號欄位。腳本 regex 從「商品描述」抽出 768/5239 筆（剩下的格式不一致，待後續優化）。

### 5.5 產品底價

INVI02 「業務底價」欄全部是 0。Lynn 拍板：底價是敏感資料，鎖定最高權限。  
→ 拆獨立表 `product_base_prices`、RLS 只 manager。**等 Lynn 提供底價檔再 import**。

---

## 6. 接手的人怎麼開始

### 6.1 第一步（Week 3-0.5 收尾）

跟 Lynn 確認 `sql/01_shared_schema.sql` + `sql/02_shared_rls.sql` 設計後，依 `sql/IMPORT_GUIDE.md` 把 6 個 step 跑完：

1. 跑 `01_shared_schema.sql`（建表）
2. 跑 `02_shared_rls.sql`（RLS + RPC）
3. 跑 `03_seed_hospital_systems.sql`（33 體系）
4. Studio Import `hospitals.csv` 到 tmp table → 合併 SQL（含 system_code → system_id lookup）
5. Studio Import `products.csv`（5239 筆，25 MB）
6. 跑 `06_seed_assignments.sql`（423 筆分區）

跑完後**做 RLS 守門測試**（IMPORT_GUIDE.md §3）：用無痕視窗逐角色登入，看分區守門有效。

### 6.2 第二步（Week 3-1 動 medsec_cases）

等 Lynn 拍 §9 的 4 題後動。

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
- ❌ 不要寫 `supa.from('products').select('*')`（5239 筆撈光，要走 `search_products` RPC）
- ❌ 不要在 commit / PR 提到模型名稱（claude-opus-4-7 那種）

### 7.3 產品搜尋（前端範例）

```js
// ✓ 用 RPC（伺服端 trgm 比對，回 10 筆最像的）
const { data } = await supa.rpc('search_products', { q: '內視鏡', max_results: 10 });

// ✗ 不要這樣（5239 筆全撈）
const { data } = await supa.from('products').select('*');
```

### 7.4 醫院查詢（用 view 含體系名）

```js
// hospitals_with_system view 已 join 進 hospital_systems
const { data } = await supa.from('hospitals_with_system')
  .select('id, name, short_name, region, system_name, payment_term')
  .order('name');
// RLS 自動擋住分配外的醫院
```

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
`hospitals.csv` 有 `system_code` 但表是 `system_id` (uuid)。  
→ 解法：先 import 到 tmp table，再 SQL 一支 join 寫進正式表（見 `sql/IMPORT_GUIDE.md` Step 2.2）。

---

## 9. ⏳ 等 Lynn 拍板的 4 題（動 Week 3-1 之前要回）

| # | 問題 | 用途 |
|---|---|---|
| 1 | `medsec_cases` ↔ medteam-app 怎麼關聯？業務在 medteam INSERT 進 `medsec_cases`（共用同表），還是 medteam 有自己的 `medteam_cases`、靠 `medteam_case_id` 外鍵？ | 影響 schema 設計 |
| 2 | 案件編號格式（`YYMMDD-NNN`？`MS-2026-0001`？）| 影響 trigger |
| 3 | `medsec_cases.status` 完整 enum（pending → claimed → packaging → pending_decision → decided → crm_sent → closed？有沒有「退回」「補件」？）| 影響 enum |
| 4 | AI 決策包用什麼引擎（Claude API / OpenAI / SQL aggregate）？影響 `medsec_quote_decisions.reasoning` 是 text 還是 jsonb | 影響 schema |

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

## 11. 最後叮嚀

照順序：

1. ✅ 先把 §6.1 的 6 個 Supabase step 跑完
2. ✅ 做 RLS 守門測試（每個角色用無痕視窗實際登入測一遍）
3. ⏳ 跟 Lynn 拿產品底價檔 → 跑 update script 灌 `product_base_prices`
4. ⏳ 等 Lynn 拍 §9 四題 → 動 `medsec_cases` schema
5. ⏳ Week 3-2 起依路線圖推

碰到沒寫到的情境 → 直接問 Lynn，不要自己猜。

— 接手 · 2026-05-13
