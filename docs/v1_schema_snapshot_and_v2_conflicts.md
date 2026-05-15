# V1 Schema 快照 + V2 Sprint 1 衝突清單

> **用途**：給 Lynn 重寫 V2 Sprint 1 handoff 時對齊 V1 既有命名 / 型別 / auth 模型用。
> **來源**：HANDOVER.md §4（V3.2 schema 現狀）+ `sql/v33/` + `sql/01_extend_existing_schema.sql` + `sql/02_extend_rls.sql`。
> **重要警告**：這份是**文件 derived**，不是 live `information_schema` query。pZToe session 無 DB 連線。如有 drift，Lynn 跑下面 information_schema query 對照後回報，我再修正本檔。
>
> ```sql
> SELECT table_name FROM information_schema.tables
> WHERE table_schema='public' AND (table_name LIKE 'medsec_%' OR table_name IN ('profiles','hospital_systems','product_base_prices'))
> ORDER BY table_name;
> ```

---

## Part 1 · V1 Schema 快照

### 1.1 Auth 模型（V1 確定走這條，V2 必須對齊）

- **身分來源**：Supabase Auth（`auth.users`），每位員工一個 user，登入 email = `{employee_id}@medteam.internal`
- **應用 profile**：`profiles` 表 1:1 對 `auth.users.id`
- **RLS gate**：所有 policy 走 `auth.uid()` + 透過 `profiles.medsec_role` / `profiles.has_medsec_access` / `profiles.has_medteam_access` 判定權限
- **不走 `current_setting('app.current_user_code')` GUC 路徑**（V2 handoff §2 寫的方式跟現有架構不相容）

### 1.2 `profiles`（Week 1-2 建好，60 筆 seed）

| 欄位 | 型別 | 備註 |
|---|---|---|
| `id` | uuid PK | = `auth.users.id` |
| `employee_id` | **text** | 例 `0006`（0 開頭會掉，不能用 integer）|
| `name` / `nickname` | text | |
| `has_medteam_access` | bool | 是否業務（V3.3 sales gate 用）|
| `has_medsec_access` | bool | 是否 medsec-app 可登入 |
| `medsec_role` | text | `manager` / `bidding_team` / `purchasing` / `accounting` / `secretary`（5 值 CHECK）|

**5 個 medsec_role 對應的真人**（HANDOVER §1.2）：

| medsec_role | 員工 | employee_id |
|---|---|---|
| `manager` | 賴瑩（Lynn）| `0006` |
| `bidding_team` | 鄭欣菱（Candy）| `0132` |
| `purchasing` | 周佳蓉（Cindie）| `0003` |
| `accounting` | 陳靖雅 | `0176` |
| `secretary` | 雅婷 `0168` / 小飛 `0011` / 映晨 `0150` / 伶華 `0020` | 4 人主分區優先開通 |

### 1.3 V1 全表清單（24 張 medsec_* + 3 張共用 + profiles）

**`medsec_*` 表（HANDOVER §4.1）**

| # | 表名 | 欄位數 | seed 數 | 用途 |
|---|---|---|---|---|
| 1 | `medsec_hospitals` | 24 | **185** | 醫院主檔（COPI01）|
| 2 | `medsec_products` | 42 | **5260** | 產品主檔（INVI02）|
| 3 | `medsec_secretary_assignments` | 6 | **182** | 業祕分區（主祕 + 副祕，一家一行） |
| 4 | `medsec_salesperson_assignments` | 10 | **236** | 業務共管分區（normalized）|
| 5 | `medsec_cases` | 33 (V3.3) | 0 | 業祕案件（詢價 / 建碼 / 標案）|
| 6 | `medsec_case_items` | 10 | 0 | 案件下的多個產品項 |
| 7 | `medsec_case_documents` | 10 | 0 | 案件附文件 |
| 8 | `medsec_case_timeline` | 7 | 0 | 案件事件流 |
| 9 | `medsec_crm_chunks` | 11 | 0 | CRM 知識庫（含 embedding）|
| 10 | `medsec_discount_rules` | 17 | **3** | 折扣規則 |
| 11 | `medsec_documents` | 13 | 0 | 文件中央庫（含 OCR）|
| 12 | `medsec_approval_products` | 2 | 0 | 衛署證 ↔ 產品 join |
| 13 | `medsec_regulatory_approvals` | 19 | 0 | 衛署證主檔（含到期日 + IFU）|
| 14 | `medsec_qsd_certificates` | 13 | 0 | QSD 證書 |
| 15 | `medsec_qsd_approval_links` | 2 | 0 | QSD ↔ 衛署證 |
| 16 | `medsec_nhi_codes` | 14 | 0 | 健保碼 |
| 17 | `medsec_hospital_doc_templates` | 9 | 0 | 醫院文件模板 |
| 18 | `medsec_hospital_operation_rules` | 15 | 0 | **醫院操作規則（V2 主戰場）** |
| 19 | `medsec_hospital_shipping_addresses` | 13 | 0 | 收貨地址 |
| 20 | `medsec_pending_invoices` | 11 | 0 | 待開發票 |
| 21 | `medsec_sales_history` | 13 | 0 | 歷史成交價 |
| 22 | `medsec_tender_bonds` | 25 | 0 | 標案保證金 |
| 23 | `medsec_consignment_inventory` | 12 | 0 | 寄售品庫存（WIS07，V3.3 新建）|
| 24 | `medsec_product_units` | 11 | 0 | 單台序號保固（WIS09，V3.3 新建）|

**3 張共用底層（不在 `medsec_` prefix）**

| 表 | seed 數 | 用途 |
|---|---|---|
| `hospital_systems` | 33 | 體系（榮民 / 長庚 / 署立 / ...）|
| `product_base_prices` | 0 | 產品底價（FK → medsec_products）|
| `medsec_salesperson_assignments` | 已列上表 | — |

### 1.4 `medsec_hospitals` 關鍵欄位（V1 已 seed 185 筆）

```
id                 text  PK    -- 鼎新代號當 PK（不是 BIGSERIAL！）
name / short_name  text
... (24 欄)
```

> ⚠️ V1 `medsec_hospitals.id` 是 **text**，不是 BIGSERIAL。所有 FK 都打 text。

### 1.5 `medsec_secretary_assignments` 結構（V1 已 seed 182 筆）

```
hospital_id            text PK    -- 一家一行（不是 BIGSERIAL）
primary_secretary_id   uuid       -- → profiles.id
co_secretary_id        uuid       -- → profiles.id（可 NULL）
effective_date         date
notes                  text
updated_at             timestamptz
```

主祕 + 副祕**兩個欄位**在同一行，**不是**一行一人 + `is_primary` boolean。

### 1.6 `medsec_hospital_operation_rules`（15 欄，V1 已建表 / 未 seed）

來源 HANDOVER §4.2.4：

> `hospital_id` 是 PK（一家一行）。包含 `order_mode`、`shipping_destination`、`packaging_notes`、`invoice_mode`、`payment_cycle_note`、`invoice_product_name`、`case_close_method`、`contact_person`、`platform_required (ARRAY)`、`special_notes`、`source_secretary` / `source_date` / `confidence`、`updated_at`。

15 欄完整列表：
```
hospital_id            text PK → medsec_hospitals(id)
order_mode             text
shipping_destination   text
packaging_notes        text
invoice_mode           text
payment_cycle_note     text             -- 注意：V1 是 _note 結尾，不是 payment_cycle
invoice_product_name   text             -- 注意：V1 沒 _style 結尾
case_close_method      text
contact_person         text
platform_required      text[]           -- ARRAY，V2 handoff 沒這欄
special_notes          text             -- V1 free text，對應 V2 free_text_notes
source_secretary       text             -- V1 audit 欄，V2 改 updated_by
source_date            date             -- 同上
confidence             numeric          -- V1 AI 抽出來時的信心度
updated_at             timestamptz
```

### 1.7 V3.3 RLS / 函式（Lynn 已套到 DB，V2 不要覆蓋）

**函式**：
- `auth_has_medteam_access() → bool`（V3.3 §13.2）
- `auth_medsec_role() → text`（sql/02_extend_rls.sql）
- `is_global_hospital_viewer() → bool`
- `can_see_medsec_hospital(h_id text) → bool`
- `calc_erp_doc_code(company, action_type) → text`
- `calc_sop_ref(action_type) → text`
- `compute_case_decision_package(case_id) → jsonb`
- `search_medsec_products(q, max) → table`

**Trigger**：
- `medsec_cases_autofill_trg`（BEFORE INSERT/UPDATE on medsec_cases）
- `mci_updated_at` / `mpu_updated_at`

**Week 3-2 step 0 補丁（PR #1 待 merge）**：
- `medsec_cases_read` / `medsec_cases_write` 放寬到 `medsec_role IN ('manager','bidding_team','secretary')`

---

## Part 2 · V1 ↔ V2 Handoff 衝突清單

### 2.1 表 / 欄位命名衝突

| V2 handoff 物件 | V1 既有對應 | 衝突類型 | 建議動作 |
|---|---|---|---|
| `medsec_hospitals.id BIGSERIAL` | `medsec_hospitals.id text` | **型別衝突**（PK） | V2 用 V1 既有 text PK，不要 BIGSERIAL；FK 全打 text |
| `medsec_hospitals.dingxin_code` | V1 的 `id` 本身就是鼎新代號 | 重複欄位 | V2 不要這欄，直接用 `id` |
| `medsec_hospitals.invoice_company CHAR(2)` | V1 有沒有這欄需查 information_schema | 可能新增 | 確認 V1 24 欄裡是否已含；沒有就 ALTER ADD |
| `medsec_employees` 新表 | `profiles`（60 筆已 seed）| **概念衝突** | V2 不建這張，全 reference `profiles` |
| `medsec_employees.id BIGSERIAL` | `profiles.id uuid (=auth.uid)` | 型別衝突 | 用 uuid，全部改 `→ profiles(id)` |
| `medsec_employees.employee_code` | `profiles.employee_id` | 欄名衝突 | 用 V1 名稱 `employee_id` |
| `medsec_employees.role` | `profiles.medsec_role` | 欄名衝突 + 值不同 | V2 寫 `secretary/sales/manager/admin/...`；V1 是 `manager/bidding_team/purchasing/accounting/secretary` |
| `medsec_secretary_assignments.id BIGSERIAL` | `medsec_secretary_assignments.hospital_id text PK` | **結構衝突** | V1 是「一家一行 + 主副祕欄」；V2 是「一行一人 + is_primary」。**V1 已 seed 182 筆，不要 DROP** |
| `medsec_secretary_assignments.secretary_id` | `primary_secretary_id` / `co_secretary_id` | 結構衝突 | V2 sprint 1 改 query 兩欄 union，不重 normalize |
| `medsec_hospital_operation_rules.payment_cycle` | `payment_cycle_note` | 欄名差異 | V2 改 `payment_cycle_note`；§1.3 view 也要改 |
| `medsec_hospital_operation_rules.invoice_product_name_style` | `invoice_product_name` | 欄名差異 | V2 改 `invoice_product_name` |
| `medsec_hospital_operation_rules.invoice_track` | V1 沒這欄 | V2 新需求 | 可 ALTER ADD `invoice_track text` |
| `medsec_hospital_operation_rules.shipping_method` | V1 沒這欄 | V2 新需求 | ALTER ADD `shipping_method text` |
| `medsec_hospital_operation_rules.dual_invoice bool` | V1 沒這欄 | V2 新需求 | ALTER ADD |
| `medsec_hospital_operation_rules.has_consignment` | V1 沒這欄 | V2 新需求；但 V1 有 `medsec_consignment_inventory` 整張表 | 可能不需要這 bool，直接從 inventory 表 exists 判定 |
| `medsec_hospital_operation_rules.free_text_notes` | `special_notes` | 欄名差異 | V2 改用 `special_notes` |
| `medsec_hospital_operation_rules.updated_by` | `source_secretary text` | 概念差異 | V1 是手動記名字 text，V2 想 FK uuid。建議 V2 ALTER ADD `updated_by uuid → profiles(id)`，舊欄 keep |
| `medsec_rule_suggestions` 新表 | V1 沒有 | 純新增 | ✅ V2 sprint 1 加，但 FK 改 → profiles(id) uuid |
| `medsec_hospital_credentials` 新表 | V1 沒有 | 純新增 | ✅ V2 sprint 1 加，FK 改 → medsec_hospitals(id) text + profiles(id) uuid |
| `medsec_audit_log` 新表 | V1 沒有 | 純新增 | ✅ FK 全改型別 |
| `medsec_hospital_rule_completeness` view | V1 沒有 | 純新增 | ✅ JOIN 欄位要對齊 V1 既有欄名（見下方）|

### 2.2 RLS 機制衝突（最致命）

| V2 handoff 寫法 | V1 既有寫法 | 衝突 |
|---|---|---|
| `current_setting('app.current_user_code', TRUE)` | `auth.uid()` | 認證源不同。V2 全部改用 `auth.uid()` |
| `employee_code = current_setting(...)` | `id = auth.uid()` | 同上 |
| `role IN ('admin','manager')` | `medsec_role IN ('manager',...)` | 欄名不同，值集合也不同（V1 沒 admin） |
| Lynn `= '0001'` | Lynn 員工編號 `= '0006'` | **拍板：Lynn = 0006** |
| 伶華 `= '0020'` | 伶華 `= '0020'` | ✅ 一致 |

V2 sprint 1 §2 整段 RLS 都要重寫。可參考既有 `sql/02_extend_rls.sql` 的寫法模板。

### 2.3 V1 ↔ V2 數字事實衝突

| 事實 | V1 已 seed（HANDOVER）| V2 handoff §1.2 / §9 | 仲裁 |
|---|---|---|---|
| 醫院數 | 185 | 253 | V2 預期 253 是「全部 COPI01」？V1 185 是已過濾。需 Lynn 確認 |
| 業祕分區筆數 | 182 | 186 | 4 筆差異可能是「共管」算法不同（V1 主祕 + 副祕 fixed 2 欄、V2 normalized 多行）|
| 主祕負責家數 | 雅婷 57 / 小飛 53 / 映晨 45 / 伶華 34 | 雅婷 56 / 小飛 54 / 映晨 41 / 伶華 30 / 共管 5 | V2 把「共管」分開算，V1 計入主分區。需 Lynn 確認哪個算法為準 |
| 員工數 | 60（profiles seed）| 不明 | V1 為準 |

---

## Part 3 · V2 Sprint 1 Handoff 重寫建議

不重寫 SQL（等 Lynn 親自定 V2），但列出**改寫骨架**讓 V2 handoff 對齊 V1：

### 3.1 §1.3 完整度 view 重寫

```sql
CREATE OR REPLACE VIEW medsec_hospital_rule_completeness AS
SELECT
  h.id AS hospital_id,
  h.name,                                  -- 取代 short_name (確認 V1 hospitals 有沒有 short_name)
  -- h.invoice_company,                    -- 確認 V1 hospitals 有沒有這欄
  CASE WHEN r.hospital_id IS NULL THEN 0
    ELSE (
      (CASE WHEN r.order_mode IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.shipping_destination IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.packaging_notes IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.invoice_mode IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN r.payment_cycle_note IS NOT NULL THEN 1 ELSE 0 END) +   -- 不是 payment_cycle
      (CASE WHEN r.invoice_product_name IS NOT NULL THEN 1 ELSE 0 END) + -- 不是 _style
      (CASE WHEN r.case_close_method IS NOT NULL THEN 1 ELSE 0 END)
      -- shipping_method / invoice_track 等 V1 沒的欄位先不計
    ) * 100 / 7                                                            -- 分母改 7
  END AS completeness_pct,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN r.order_mode IS NULL THEN 'order_mode' END,
    CASE WHEN r.shipping_destination IS NULL THEN 'shipping_destination' END,
    CASE WHEN r.packaging_notes IS NULL THEN 'packaging_notes' END,
    CASE WHEN r.invoice_mode IS NULL THEN 'invoice_mode' END,
    CASE WHEN r.payment_cycle_note IS NULL THEN 'payment_cycle_note' END,
    CASE WHEN r.invoice_product_name IS NULL THEN 'invoice_product_name' END,
    CASE WHEN r.case_close_method IS NULL THEN 'case_close_method' END
  ], NULL) AS missing_fields
FROM medsec_hospitals h
LEFT JOIN medsec_hospital_operation_rules r ON r.hospital_id = h.id;
```

如果 V2 真的要 9 個維度 → 對 `medsec_hospital_operation_rules` 先 `ALTER TABLE ADD COLUMN`（`shipping_method text`、`invoice_track text`）再算分母 9。

### 3.2 §2 RLS 重寫骨架（auth.uid() 版）

```sql
-- 共用 helper（如果還沒建）
CREATE OR REPLACE FUNCTION public.auth_is_manager_or_co_reviewer()
RETURNS bool LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND has_medsec_access = true
      AND (medsec_role = 'manager' OR employee_id = '0020')   -- Lynn(manager) + 伶華(0020)
  )
$$;

-- 業祕只看自己分區的醫院
CREATE POLICY secretary_view_own_hospitals ON medsec_hospitals FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM medsec_secretary_assignments sa
    WHERE sa.hospital_id = medsec_hospitals.id
      AND (sa.primary_secretary_id = auth.uid() OR sa.co_secretary_id = auth.uid())
  )
  OR public.is_global_hospital_viewer()      -- 既有函式 (manager / bidding_team / purchasing / accounting)
);

-- suggestions：自己分區可 INSERT
CREATE POLICY secretary_create_suggestion ON medsec_rule_suggestions FOR INSERT TO authenticated WITH CHECK (
  EXISTS (
    SELECT 1 FROM medsec_secretary_assignments sa
    WHERE sa.hospital_id = medsec_rule_suggestions.hospital_id
      AND (sa.primary_secretary_id = auth.uid() OR sa.co_secretary_id = auth.uid())
  )
);

-- Lynn (manager) + 伶華 (0020) 可審
CREATE POLICY manager_approve_suggestion ON medsec_rule_suggestions FOR UPDATE TO authenticated
  USING (public.auth_is_manager_or_co_reviewer())
  WITH CHECK (public.auth_is_manager_or_co_reviewer());

-- credentials：只主祕 + manager / Lynn / 伶華
CREATE POLICY credentials_restricted ON medsec_hospital_credentials FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM medsec_secretary_assignments sa
    WHERE sa.hospital_id = medsec_hospital_credentials.hospital_id
      AND sa.primary_secretary_id = auth.uid()     -- 只主祕，不含副祕
  )
  OR public.auth_is_manager_or_co_reviewer()
);
```

### 3.3 §3.5 「全局問問題」如何融入 V1 5 角色頁面

V1 已有 5 角色頁面（manager / candy / cindie / accounting / secretary），V2 sprint 1 §3 又寫了 4 個新頁面（secretary / manager / hospital / rule-chat）。**page 命名衝突**：

| V2 寫的頁面 | V1 既有頁面 | 衝突動作 |
|---|---|---|
| `secretary.html` | `secretary.html`（剛 Week 3-2 接上 medsec_cases）| **合併** — 在既有 mod-rules / mod-crm 模組裡加「規則完整度」+「補規則」入口，不要砍掉案件流 |
| `manager.html` | `manager.html`（Lynn 後台，Week 3-5 才寫）| **合併** — 加 suggestion 審核 tab |
| `hospital.html` | 新檔 | ✅ 直接新增 |
| `rule-chat.html` | 新檔 | ✅ 直接新增 |
| FAB「💬 問問題」| 新元件 | 加在 medsec-common.css + 5 角色頁面 footer |

---

## Part 4 · V2 Sprint 1 開工前 Lynn 要拍板的事

1. **`medsec_hospital_operation_rules` 補欄位**：V2 要的 `shipping_method` / `invoice_track` / `dual_invoice` / `has_consignment` 是要 ALTER ADD 上去，還是用 V1 既有 15 欄就好？
2. **完整度分母**：9 還是 7（取決於上題）？
3. **`medsec_rule_suggestions` FK 型別**：`hospital_id BIGINT → medsec_hospitals(id)` 改 `text`，`suggested_by/reviewed_by BIGINT → medsec_employees(id)` 改 `uuid → profiles(id)`。確認可？
4. **`medsec_hospital_credentials` FK 型別**：同上改 text + uuid。確認可？
5. **`medsec_audit_log` FK 型別**：同上。確認可？
6. **「業祕只能讀自己分區」**：V1 既有 `can_see_medsec_hospital(h_id)` 已涵蓋此邏輯，V2 sprint 1 §2 可直接 reuse 還是要重寫？
7. **共管副祕**：V2 §2 寫「主責業祕」才能看 credentials，V1 副祕（`co_secretary_id`）算不算？我寫法是「只主祕」，需確認
8. **183 hospitals 數字差異**：V2 預期 253，V1 已 seed 185。是要先 seed 補 68 家，還是 V2 sprint 1 只動已 seed 的 185？
9. **`medsec_employees` 60 人 vs V1 profiles 60 人**：是同一群人嗎？V1 60 筆已含 Cindie/Candy/Lynn/4 業祕等。V2 不需要再建 employees 表
10. **V2 §5「需業祕審核的 4 家醫院」**：這 4 家不在 V1 已 seed 的 185 裡，要等補建 COPI01 還是 V2 sprint 1 範圍排除？

---

## Part 5 · 下一步

1. Lynn 跑 §0 開頭那個 information_schema query，把實際 V1 schema dump 給我，我比對本檔有沒有 drift
2. Lynn 拍板 Part 4 的 10 題
3. Lynn 重寫 V2 sprint 1 handoff（或讓我依拍板結果寫 V2 sprint 1 對齊版 SQL）
4. 我再開工 V2 sprint 1
