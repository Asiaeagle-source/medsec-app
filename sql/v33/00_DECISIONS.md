# §9 四題 Lynn 最終拍板 (V3.3)
**對齊版本**: HANDOVER.md V3.2 (commit 19d0b9e)  
**拍板日**: 2026-05-13  
**用途**: 給 Claude Code 動 Week 3-1（medsec_cases 真實接線 + 新增 2 張 schema）

---

## Q1. medsec_cases ↔ medteam-app → 方案 A（共用同表）

業務在 medteam-app 提案件 → 直接 INSERT 一筆到 `medsec_cases`，`source = 'medteam-app'`，業祕在 medsec-app 立即看到。

**RLS 規則**：
- 業務（`medteam_role='sales'`）：只能 INSERT 自己的 + SELECT `requested_by_user_id = auth.uid()` 的
- 業祕（`medsec_role='secretary'` 或 `'manager'`）：全部 SELECT / UPDATE
- bidding_team：看 `action_type IN ('tender_supply','tender_equipment')` 全部

---

## Q2. action_type 設計（13 種打平 + V1 全做一般報價）

### 核心設計原則
- **UI 一層下拉**（業務只選 1 次），不做 case_type→subtype 兩層
- 每個 `action_type` 對應**明確的鼎新單別**（一對一或靠 `company` 切一對二）
- `erp_doc_code` 由系統從 `(company, action_type)` 自動算出，不讓業務手動填

### medsec_cases 補欄位

```sql
ALTER TABLE medsec_cases ADD COLUMN IF NOT EXISTS company       text;
ALTER TABLE medsec_cases ADD COLUMN IF NOT EXISTS action_type   text;
ALTER TABLE medsec_cases ADD COLUMN IF NOT EXISTS erp_doc_code  text;  -- 系統算
ALTER TABLE medsec_cases ADD COLUMN IF NOT EXISTS sop_ref       text;  -- 系統算
```

- `company`: 'AE' (雄鷹) / 'LD' (君華)
- `action_type`: 13 種 enum
- `erp_doc_code`: 鼎新 4 碼，由 trigger 從 (company, action_type) 算出
- `sop_ref`: 'WIS01' ~ 'WIS10' 或 NULL，由 trigger 從 action_type 算出

### 13 種 action_type 對照表

| action_type | UI 顯示 | SOP | AE→鼎新 | LD→鼎新 | V1? |
|---|---|---|---|---|---|
| `coding` | 建碼 | WIS01 | AECC | LDCC | ✅ |
| `quote` | 一般報價 | — | AECO/AEEQ/AEIN | LDCO/LDEQ/LDIN | ✅ |
| `surplus` | 結餘款報價 | WIS02 | AEBA | LDBA | ✅ |
| `budget` | 年度預算 | WIS02 | AEBU | LDBU | ✅ |
| `renewal` | 汰舊換新 | WIS02 | AENE | LDNE | ✅ |
| `urgent` | 臨購案 | WIS02 | AESP | LDSP | ✅ |
| `amortize` | 攤提成交 | WIS02 | AETT | ALTT | ✅ |
| `negotiate` | 議價 | WIS06 | AEYJ | LDYJ | ✅ |
| `tender_supply` | 耗材招標 | WIS04 | AEDB | ALDB | ✅ |
| `tender_equipment` | 設備招標 | WIS04 | AEEB | ALEB | ✅ |
| `borrow` | 暫借/Demo/報刀 | WIS05 | AEOP | LDOP | V2 |
| `repair_quote` | 維修報價 | WIS09 | AERM (NPRM 不計費) | LDRM | V2 |
| `maintenance` | 設備保養 | WIS10 | AEMT | （無）| V2 |

⚠️ **`quote` 一般報價的細分**（耗材/設備/器械）：
- V1 簡化：UI 不再細分，預設拋成 **AECO / LDCO**（耗材報價，最常用）
- 業祕在編輯案件時可改 `erp_doc_code` 為 AEEQ/AEIN（設備/器械）
- V2 再考慮 UI 是否加「一般報價的細分」第二層

### erp_doc_code 計算邏輯（系統 trigger 自動帶）

```
(company='AE', action_type='coding')          → 'AECC'
(company='LD', action_type='coding')          → 'LDCC'
(company='AE', action_type='quote')           → 'AECO'  (預設耗材，業祕可改)
(company='LD', action_type='quote')           → 'LDCO'
(company='AE', action_type='surplus')         → 'AEBA'
(company='LD', action_type='surplus')         → 'LDBA'
(company='AE', action_type='budget')          → 'AEBU'
(company='LD', action_type='budget')          → 'LDBU'
(company='AE', action_type='renewal')         → 'AENE'
(company='LD', action_type='renewal')         → 'LDNE'
(company='AE', action_type='urgent')          → 'AESP'
(company='LD', action_type='urgent')          → 'LDSP'
(company='AE', action_type='amortize')        → 'AETT'
(company='LD', action_type='amortize')        → 'ALTT'
(company='AE', action_type='negotiate')       → 'AEYJ'
(company='LD', action_type='negotiate')       → 'LDYJ'
(company='AE', action_type='tender_supply')   → 'AEDB'
(company='LD', action_type='tender_supply')   → 'ALDB'
(company='AE', action_type='tender_equipment')→ 'AEEB'
(company='LD', action_type='tender_equipment')→ 'ALEB'
(company='AE', action_type='borrow')          → 'AEOP'
(company='LD', action_type='borrow')          → 'LDOP'
(company='AE', action_type='repair_quote')    → 'AERM'
(company='LD', action_type='repair_quote')    → 'LDRM'
(company='AE', action_type='maintenance')     → 'AEMT'
```

### case_no 編號格式

`{erp_doc_code}-{YYMMDD}-{NNN}`

範例：
- `AECC-260513-001` 雄鷹建碼報價，2026-05-13 第 1 筆
- `LDYJ-260601-007` 君華議價，2026-06-01 第 7 筆
- `AECO-260513-024` 雄鷹一般耗材報價，2026-05-13 第 24 筆

每天每個 erp_doc_code 自己歸零、3 位流水（999/天 已超出單一單別業務量）。

---

## Q3. status 完整 enum + 提醒規則

### enum 值

```sql
ALTER TABLE medsec_cases DROP CONSTRAINT IF EXISTS medsec_cases_status_check;
ALTER TABLE medsec_cases ADD CONSTRAINT medsec_cases_status_check
  CHECK (status IN (
    'pending',              -- 業務剛提交，沒人認領
    'claimed',              -- 業祕認領了
    'packaging',            -- 業祕整理決策包中
    'pending_decision',     -- 包好等 Lynn 決策
    'decided',              -- Lynn 拍板
    'crm_sent',             -- 業祕已打鼎新 CRM
    'closed',               -- 結案
    'returned',             -- Lynn 退回業祕重整理
    'pending_supplement'    -- 業務補件中
  ));
```

### 提醒規則（V1 dashboard 紅點 / V2 推播）

| status | 超時門檻 | 推播對象 | 提醒文字 |
|---|---|---|---|
| `pending` | 24 小時 | 業祕（依分區）| 「這家醫院的案件還沒人認領」|
| `pending_decision` | 24 小時 | Lynn (0006) | 「決策包準備好了，等你看」|
| `returned` | 12 小時 | 業祕（該案件原處理人）| 「Lynn 退回了，要重整理」|
| `pending_supplement` | 24 小時 | 業務（該案件提交人）| 「Lynn 要求補件，請處理」|

---

## Q4. AI 決策包邏輯 — V1 純 SQL

### 不調 Claude API，全靠 aggregate

**決策包資料源**（給 manager.html 看）：

1. `medsec_sales_history` → 同醫院同產品最近 5 筆成交（avg / median / min / max）
2. `medsec_hospital_operation_rules` → 醫院規則（含付款方式、開立發票方式）
3. `medsec_discount_rules` → 折扣規則（fixed / percentage / **donation** ← WIS01 的捐贈方式對應這個）
4. `product_base_prices` → 底價（manager 才看得到，secretary 看不到）
5. `medsec_crm_chunks` → 同體系 CRM 規則 / 過往溝通紀錄

**寫入 medsec_cases**:
- `ai_suggested_price` (numeric)
- `ai_confidence` (numeric 0-1)

**reasoning 模板**（V1 用字串組）：

```
近 5 筆同產品同醫院成交平均 12.5 萬，中位數 13 萬，建議報價 13 萬。
體系折扣率 92%，本案毛利 18%（高於體系平均 15%）。
注意：本醫院 CRM 規則指出付款週期較長（90 天），議價時可考慮折讓方式。
```

V2 再加 Claude API 寫人話 reasoning。

---

## Q5. SOP 流程提示（Lynn 新需求）

**Lynn 補充**：「SOP 不要讓業祕主動查（沒人會點），要做成『該做什麼時系統自動提示』」

### 實作方式

1. `medsec_cases.sop_ref` 欄位 trigger 自動帶（從 action_type 算）
2. 每個 `(action_type, status)` 對應 SOP 的某個步驟
3. **manager.html / candy.html / secretary.html / sales 端**的案件詳細頁，根據 (action_type, status) 顯示「下一步該做什麼」提示卡

### 範例硬編碼（V1 不做動態 SOP 步驟表）

```
action_type='tender_supply' AND status='pending_decision':
  📋 WIS04 招標 SOP 提醒：
  ✓ 押標金已支付？金額多少？
  ✓ 開標日期？
  ✓ 三間廠商到齊？

action_type='coding' AND status='claimed':
  📋 WIS01 建碼 SOP 提醒：
  ✓ 與醫院確認是否需試用？（連 WIS05）
  ✓ 提供報價單前先了解醫院折扣率

action_type='repair_quote' AND status='claimed':
  📋 WIS09 維修報價 SOP 提醒：
  ✓ 查 medsec_product_units 序號保固
  ✓ 若保固內 → 填「保內換新申請單」（0 元）
  ✓ 若保固外 → 確認醫院維修意願
```

**V1 範圍**：4 個 action_type × 2-3 個 status = 8-12 個硬編碼提示卡。
**V2 範圍**：把 10 份 SOP 結構化拆步驟存 DB，自動帶提示。

---

## Q6. 兩張新 schema（V1 動）

### (A) medsec_consignment_inventory — 寄售品庫存（對應 WIS07）

```sql
CREATE TABLE medsec_consignment_inventory (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id         text REFERENCES medsec_hospitals(id) NOT NULL,
  product_code        text REFERENCES medsec_products(id) NOT NULL,
  
  stock_qty           int NOT NULL DEFAULT 0,
  monthly_avg_usage   numeric,           -- 月均使用量（盤點時填）
  earliest_expiry     date,              -- 最早效期（觸發換貨用）
  
  last_inventory_date date,              -- 上次盤點日
  last_inventory_by   uuid REFERENCES profiles(id),  -- 上次盤點業務
  
  status              text DEFAULT 'active' CHECK (status IN ('active','expiring','returned')),
  notes               text,
  
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  
  UNIQUE (hospital_id, product_code)
);

-- RLS:
-- - manager: 全部
-- - secretary: 全部（業祕負責盤點調撥）
-- - sales: 只看自己分區醫院（透過 medsec_salesperson_assignments）
ALTER TABLE medsec_consignment_inventory ENABLE ROW LEVEL SECURITY;
```

**業務在 secretary.html 看的視圖**：
- 我區寄售品列表
- 效期 < 1.5 年的標紅（觸發 WIS07 換效期流程）
- 月均使用量低的提示「可減量寄放」

### (B) medsec_product_units — 單台序號保固（對應 WIS09）

```sql
CREATE TABLE medsec_product_units (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_code        text REFERENCES medsec_products(id) NOT NULL,
  serial_no           text NOT NULL UNIQUE,  -- 製造商序號（單機）
  hospital_id         text REFERENCES medsec_hospitals(id),  -- 目前在哪家醫院
  
  warranty_start      date,                  -- 保固起日（出貨/驗收日）
  warranty_end        date,                  -- 保固迄日
  warranty_alert_days int DEFAULT 30,        -- 幾天前提醒
  
  status              text DEFAULT 'in_use' CHECK (status IN ('in_use','returned','replaced','scrapped')),
  install_case_id     uuid REFERENCES medsec_cases(id),  -- 首次安裝那個案件（從交貨 WIS08 來）
  
  notes               text,
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

-- RLS:
-- - manager: 全部
-- - secretary: 全部（業祕負責查保固）
-- - sales: 只看自己分區醫院的設備
ALTER TABLE medsec_product_units ENABLE ROW LEVEL SECURITY;
```

**WIS09「查保固」原本人工 → 系統自動**：

```sql
SELECT 
  warranty_end, 
  (warranty_end - CURRENT_DATE) AS days_left,
  CASE 
    WHEN warranty_end >= CURRENT_DATE THEN 'in_warranty'
    ELSE 'out_of_warranty'
  END AS warranty_status
FROM medsec_product_units
WHERE serial_no = ?;
```

→ 自動分流：
- `in_warranty` → 觸發 WIS09 保內換新申請單流程（0 元）
- `out_of_warranty` → 進維修報價流程

---

## 動工順序（請照此推進）

1. **建 erp_doc_code 對映函數**（不需要 lookup 表，13 種規則直接寫 PL/pgSQL function）
2. **`medsec_cases` ALTER**：補 `company` / `action_type` / `erp_doc_code` / `sop_ref` 欄位
3. **`medsec_cases.case_no` trigger**：依 `{erp_doc_code}-{YYMMDD}-{NNN}` 自動編號
4. **`medsec_cases.status` CHECK constraint**：補 `returned` / `pending_supplement`
5. **建 `medsec_consignment_inventory`**（含 RLS）
6. **建 `medsec_product_units`**（含 RLS）
7. **寫 V1 AI 決策包 SQL function**（純 aggregate，回傳 ai_suggested_price + reasoning）
8. **medteam-app 端做「提詢價」按鈕** — 這個之後 Lynn 另外規劃，先把 medsec 接口準備好

---

## 開工前先回 Lynn：

1. 上面有不清楚或要調整的地方嗎？
2. erp_doc_code 對映用 SQL function 還是直接寫 generated column？建議是？
3. `medsec_consignment_inventory` 和 `medsec_product_units` 的 RLS 規則，需要再對齊 `medsec_salesperson_assignments` 的分區邏輯，有疑問請提出。
4. 不要動既有 22 張表已 enabled 的 RLS。

— Lynn / 2026-05-13 V3.3 拍板版
