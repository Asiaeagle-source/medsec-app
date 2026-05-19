# medsec-app 現狀報告 (STATUS.md)

> 產出：2026-05-15 · 整理者：新 session（前 session 被圖塞爆 API 重開）
> 範圍：只整理現狀，不動程式碼。branch = `claude/continue-work-pZToe`，tip = `c5f764c`
> ⚠️ **DB 未驗證**：本環境網路 policy 擋掉 Supabase host
> （`curl … 403 Host not in allowlist`，host `yincuegybnuzgojakkuc.supabase.co` 不在 allowlist）。
> 兩條 `SELECT count` **無法實跑**，凡 DB 數字一律標「未驗證」，下面只列 SQL 檔內的事實 + PR 描述「聲稱」。

---

## Section 1 · PR 歷史（#1–#4）

> ⚠️ GitHub API 對 4 個 PR 都回 `"merged": false` 但同時有 `merged_at` 時間戳，
> 兩者矛盾。實務上 commit 都已落在 branch / base=main，研判**實際已合**，
> 但 merge 方式（squash？close-then-land？）無法從 API 確認。下面 merge 時間照 `merged_at`。

### PR #1 — V3.3: medsec_cases schema 擴充 + product/hospital seed
- **狀態**：closed，`merged_at` 2026-05-14 04:24:56Z（merged 旗標矛盾，見上）
- **主要檔案**：`HANDOVER.md`(+952)、`sql/01_extend_existing_schema.sql`、`sql/02_extend_rls.sql`、
  `sql/03–07_seed_*.sql`、`sql/data/*.csv`（hospitals 185 / products 5240 / assignments）、
  `sql/v33/00–06`、`sql/fix_inventory/step0–7`、`tools/generate_*.py`、`secretary.html`、`medsec-common.{css,js}`
- **DB 動作（DDL，無 DROP TABLE / 無 RENAME）**：
  - `ALTER medsec_cases` ADD `action_type/company/erp_doc_code/sop_ref` + 重設 3 個 CHECK（status 4→9 值）
  - `ALTER medsec_products` ADD 15 欄（cost/supplier/dms/warehouse 類）
  - `CREATE medsec_consignment_inventory`、`CREATE medsec_product_units`（+ warranty view）
  - `CREATE hospital_systems`、`product_base_prices`、`medsec_salesperson_assignments`
  - 函式：`auth_medsec_role / can_see_medsec_hospital / is_global_hospital_viewer /
    calc_erp_doc_code / calc_sop_ref / compute_case_decision_package / search_medsec_products /
    medsec_cases_autofill` + 多個 updated_at trigger
  - seed：hospitals 185、products ~5240、secretary_assignments、salesperson_assignments、hospital_systems 33（皆 `ON CONFLICT DO NOTHING`）

### PR #2 — V2 Sprint 1: schema + ETL + 醫院規則 UI（secretary / hospital）
- **狀態**：closed，`merged_at` 2026-05-15 07:24:53Z
- **主要檔案**：`docs/v1_schema_snapshot_and_v2_conflicts.md`(+326)、`sql/v2/01–06`、
  `sql/v2/etl/01–04 + 99 + SKIPPED.md`、`sql/v2/diag/01`、`hospital.html`(+461 新檔)、
  `secretary.html`、`medsec-common.{css,js}`、`tools/v2_seed_etl{,_phase2}.py`
- **DB 動作（無 DROP TABLE / 無 RENAME）**：
  - `ALTER medsec_hospital_operation_rules` ADD `shipping_method / invoice_track / dual_invoice`
  - `CREATE medsec_rule_suggestions`、`medsec_hospital_credentials`、`medsec_audit_log`
  - `CREATE VIEW medsec_hospital_rule_completeness`（分母 9）
  - 函式 `auth_is_assigned_secretary / auth_is_manager_or_co_reviewer / touch_credentials_updated_at` + RLS policy（drop-then-create 同名 policy，非 table）
  - ETL seed：operation_rules 115 列、credentials 18 列、phase2 +12 規則

### PR #3 — batch D manager.html 全補 + hospital bug fix + 全公司 toggle（含 batch E）
- **狀態**：closed，`merged_at` 2026-05-15 08:40:03Z
- **主要檔案**：`manager.html`(+922)、`rule-chat.html`(+579 新檔)、
  `supabase/functions/claude-chat/index.ts`(+204 新檔)、`docs/PROJECT_OVERVIEW.md`(+475)、
  `hospital.html`、`secretary.html`、`sql/v2/07–09`、`sql/v2/etl/05_*part1-5`(~8878 列)、`tools/v2_copi10_etl.py`
  （此 PR 區間含 commit `80b3447` batch E、`b6d732f` batch D、`ad56823` edge fn rate limit、`a4eba93` 分區換區、`5474ccc` COPI10）
- **DB 動作（無 DROP TABLE / 無 RENAME）**：
  - `CREATE medsec_hospital_product_codes`（COPI10 院內碼對照）、`CREATE medsec_chat_log`
  - `ALTER medsec_secretary_assignments ENABLE RLS` + `sa_manager_write` policy（分區換區）
  - RLS policy for hpc / chat_log（drop-then-create policy）
  - ETL seed：hospital_product_codes ~8878 列（part1–5）

### PR #4 — Sprint 2 起手：折讓 ETL + 模組 3 報價系統
- **狀態**：closed，`merged_at` 2026-05-15 09:33:40Z
- **主要檔案**：`sql/v2/10_create_quotes.sql`(+208)、`sql/v2/etl/06_seed_discount_rules.sql`(+428)、
  `secretary.html`、`manager.html`、`hospital.html`、`tools/v2_discount_etl.py`
- **DB 動作（無 DROP TABLE / 無 RENAME）**：
  - `CREATE medsec_quotes`、`CREATE medsec_quote_items`
  - 函式 `compute_quote_suggestion`（純 SQL aggregate）、`touch_quotes_updated_at` + RLS policy
  - ETL：discount_rules 406 列（`source='V2_part3_折讓總表'`，不 TRUNCATE，保留 V1 既有 3 筆）

> 補充：branch tip 還有 PR #4 之後 2 個未進 PR 的 commit
> （`675368e` 報價批次貼上框、`c5f764c` AI 解析 LINE 對話 + manual case bug fix），只動 `secretary.html`。

---

## Section 2 · Sprint 1 batch 實況（逐 batch）

### A. V2 zip ETL（115 規則 + 18 帳密）
- `sql/v2/etl/01_seed_operation_rules.sql`：**存在**，檔頭註明 115 列，`grep` 實數 **115 列** ✓
  （結構含 `shipping_method/invoice_track/dual_invoice`，對齊 V1 真實欄名；有 `ON CONFLICT` 可重跑）
- `sql/v2/etl/02_seed_credentials.sql`：**存在**，**18 列** ✓（⚠️ 檔頭自註「無 ON CONFLICT，重跑會插重複，只跑一次」）
- phase2：`03_seed_operation_rules_phase2.sql` **+12 列**；`04_seed_credentials_phase2.sql` **0 列**（僅註解）
- **「跑成功沒」→ 未驗證**：SQL 檔語法完整且存在，但是否已在 Supabase 執行**無法驗**（網路擋）。
  PR #2 描述「聲稱」Lynn 已套到 production，僅為描述，非實證。
- **「SKIPPED_ANALYSIS.md」→ 檔名不符**：repo 內是 `sql/v2/etl/SKIPPED.md`（無 `_ANALYSIS`）。
- **「54 家分類」→ 不符（是 55，分類維度不同）**：SKIPPED.md 寫的是
  **116 unique dingxin_code → 62 成功 / 55 skip**（不是 54 家）。
  55 skip 分 §A 高信心 12 筆 / §B 中信心 1 筆 / §C 低信心 18 筆 / §D（檔內續列）。
- **DB 實數（兩條 count）→ 未驗證**：
  - `SELECT count(*) FROM medsec_hospital_operation_rules;` → 未驗證（網路擋）。檔內最多可灌 115(+12 phase2)，扣 self-skip 不在 185 家者，實際落地數未知。
  - `SELECT count(*) FROM medsec_hospital_credentials;` → 未驗證。檔內 18(+phase2 0)，扣 self-skip 後未知。

### B. secretary.html「我負責的醫院」+ 完整度卡
- **有動** ✓：commit `5bd48d2`（batch B 初版）→ `6242c50`（重整：搬到「醫院規則查詢」tab + 加搜尋）。PR #2 區間。

### C. hospital.html 詳細頁
- **有動** ✓：commit `124d691`（單一醫院詳細頁 + 模式 A 提醒卡，7 天 localStorage 抑制），後續 `c11d7c4` 修 bug + 客戶代號 + 全公司 toggle。新檔 +461 行。

### D. manager.html 審核中心
- **有動** ✓：commit `b6d732f`（batch D，manager.html +922 行：規則審核中心 + pending badge + 6 模組接 V1/V2 seed）。PR #3 區間。

### E. rule-chat.html + Claude edge function
- **有動** ✓：commit `80b3447`（rule-chat.html +579 新檔，mode B/D）+ `supabase/functions/claude-chat/index.ts` +204 新檔 + 全局 FAB；`ad56823` 再補 edge fn rate limit + 用量 log。PR #3 區間。
- 註：edge function 是否已 deploy 到 Supabase **未驗證**。

---

## Section 3 · Sprint 2 進度（PR #4）

- **`medsec_discount_rules` 表**：V1 既有表（17 欄），**未新建、未改結構**（PR #4 只 INSERT）。
- **17 vs 12 欄怎麼解**：ETL `INSERT` 只填 V1 的 **9 欄**
  `(hospital_id, product_code, product_line, calc_method, fixed_amount, donation_amount, description, source, is_active)`；
  V2 來源多出來的資訊（原單價/折讓/成交/體系/公司別）**塞進 `description` 文字欄**。
  `product_code` 在 `medsec_products` 才填、否則改填 `product_line`（commit `b67cbc1` 修 FK 違反的作法）。
  → 不是「補欄位」解，是「映射進既有 9 欄 + description 編碼」解。
- **406 筆灌了沒**：`06_seed_discount_rules.sql` 檔內實數 **406 列** ✓；**是否灌進 DB → 未驗證**（網路擋）。
  檔頭：不 TRUNCATE、保留 V1 既有 3 筆、`source='V2_part3_折讓總表'` 可重灌。
- **`medsec_quotes` 表**：**有新建** ✓（`sql/v2/10_create_quotes.sql`），medsec_cases 子表（`case_id NOT NULL ON DELETE CASCADE`）。
- **quote_type enum**：**有 7 種值，但不是 PG enum type**，是 `text NOT NULL CHECK (quote_type IN (...))`：
  `shipment / registration / new_product / replacement / repair / consumable / budget`。
  另有 `status` CHECK：`draft / pending_decision / decided / sent / closed`。
- **UI（quotes.html 之類）**：**無 quotes.html 新檔**。報價 UI 是**併進** `secretary.html`（報價優化：新增→品項→算 AI→送決策）+ `manager.html`（報價決策：採納/調整/退回），commit `764c67b`。
- **AI 建議價是否動了**：**有動，但非「真 AI / 3 年歷史」版**。
  `compute_quote_suggestion()` 是 **V1 純 SQL aggregate**，吃剛灌的 `medsec_discount_rules`；
  `medsec_sales_history` 檔頭自註 **0 筆**（graceful fallback），`product_base_prices` 也 0 筆。
  → 等同「折讓規則推價」，**不是** 3 年歷史成交均價（那個仍缺資料）。Claude 版註明 V2.1 才做。

---

## Section 4 · 下一步建議（依優先序）

> 前提：所有 DB 落地數字目前都「未驗證」，環境網路擋 Supabase。

1. **【最優先】補 DB 實證**：請 Lynn（或在能連 Supabase 的環境）跑下列確認 Sprint 1/2 ETL 是否真的進去：
   ```sql
   SELECT count(*) FROM medsec_hospital_operation_rules;   -- 期望 ≈115(+12)−self_skip
   SELECT count(*) FROM medsec_hospital_credentials;        -- 期望 ≈18−self_skip
   SELECT count(*) FROM medsec_discount_rules;              -- 期望 ≈406+3
   SELECT count(*) FROM medsec_quotes;                      -- 期望 0（UI 尚未產生）
   ```
   驗完才知道「PR 描述聲稱已套用」是否屬實，否則後面 UI / AI 建議價全是空殼。

2. **收 Sprint 1 尾**：SKIPPED.md 的 55 個舊代號 mapping，§A 12 筆等業祕 `approve §A` 後跑 phase-2；
   §B/§C/§D 共 43 筆等業祕手填新代號。這批不補，55 家規則/帳密永遠進不來。
   （`04_seed_credentials_phase2.sql` 目前 0 列 = 帳密 phase2 還沒寫，待確認是否需要。）

3. **推進 Sprint 2 模組 3**：報價 schema + UI 已就位但 `compute_quote_suggestion` 只靠折讓規則。
   選項：(a) 先讓業祕用現有「折讓推價」版上線收回饋；(b) 等 `medsec_sales_history` 有 3 年成交資料再做歷史均價；
   (c) V2.1 接 Claude（已有 `claude-chat` edge fn 基礎）。建議 (a) 先上、平行準備 sales_history ETL。

⚠️ 本報告全程未改任何程式碼 / 未動 DB / 未碰 sql/v2 已 merged 檔。

---

## Section 5 · Sprint 2.5 收尾觀察(hint,Sprint 2.5 ship 後再評估,本批不動 code)

### 觀察 1:Lynn manager.html 缺「代理視角」入口(UX,非功能缺陷)

- 現況:Lynn 因全域職代,**可直接打網址**進 `cindie.html` / `secretary.html`
  操作,功能無阻;但 `manager.html` nav **沒有明確入口**,不直觀。
- 既有 nav:`⚙️ 系統設定`(季節月曆設定 ✅、業祕分區 ✅、季節月曆 ✅)。
- 建議(擇一,Sprint 2.5 ship 後再做,非現在):
  - 方案 A:`系統設定` 下加 `🔄 代理工具` →
    代 Cindie 維護(`cindie.html`)/ 代業祕報價(`secretary.html`)/
    代 Andrew 同意 quote(報價頁本就有)。
  - 方案 B(更輕):右上角個人 dropdown 加「切換視角」selector。
- 風險/影響:純導覽捷徑,不改權限邏輯(Lynn 本就可進);低風險、低工時。
- 狀態:**待辦觀察,未實作**;Lynn 確認 Sprint 2.5 ship 後再排。
