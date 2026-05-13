# HANDOVER.md — AE MED Hub · medsec-app

> 給接手的 AI / 工程師：請從頭看完這份文件再動工。
> Lynn 的時間很貴，不要重複踩前人踩過的坑。
> 最後更新：2026-05-13 · 分支 `claude/continue-work-lvZzm`

---

## 1. 專案總覽

### 1.1 我是誰

**AE MED Hub · MedSec 業務祕書平台**（簡稱 `medsec-app`）

亞洲鷹眼醫療儀器股份有限公司內部使用的 SaaS。跟另一個專案 `medteam-app`（業務團隊用）**共用同一個 Supabase Project / 同一套帳號系統**，但兩個 app 各自獨立部署、各自有自己的存取守門。

### 1.2 為什麼要做這個

公司現在的痛點：
- **業務報價** → 業祕 30 分鐘整理決策包 → Lynn 看 → 業祕打鼎新 CRM。整個流程要 1 小時。
- **257 家醫院規則**散在 13 份個人 Excel，請假代理人翻不到。
- **5260 筆 INVI02 產品**的衛署字號 / QSD 文件到期，靠 Cindie 一個人記。
- **Candy 一個人扛全公司標案**，資料散在 30 個資料夾。
- **3 類保證金**（押標金 / 履保金 / 保固金）跨 Candy → 會計 → 業祕，沒有單一視圖。

目標：把上面這些變成單一 web 平台，5 個角色各司其職，但資料共用。

### 1.3 技術棧

- **前端**：純靜態 HTML / CSS / Vanilla JS（不用框架，故意保持簡單）
- **CDN**：`@supabase/supabase-js@2`
- **字體**：Google Fonts `Noto Sans TC`
- **後端**：Supabase（Auth + Postgres + RLS + Storage 預留）
- **部署**：目前在 GitHub repo `asiaeagle-source/medsec-app`，靜態檔托管（推測是 GitHub Pages 或 Cloudflare Pages，請跟 Lynn 確認）

### 1.4 5 個角色清單

| `medsec_role` 值 | 中文角色 | 對應頁面 | 真人 | 角色色（sidebar tag）|
|---|---|---|---|---|
| `manager` | 管理者 | `manager.html` | Lynn（老闆） | 紫 `#7c3aed` |
| `bidding_team` | 標案團隊 | `candy.html` | Candy | 青 `#0891b2` |
| `purchasing` | 採購 | `cindie.html` | Cindie | 橘 `#ea580c` |
| `accounting` | 會計 | `accounting.html` | 陳靖雅 | 綠 `#16a34a` |
| `secretary` | 業務祕書 | `secretary.html` | 雅婷 / 小飛 / 映晨 / 伶華（共 4 人） | 桃紅 `#db2777` |

⚠️ 角色名 **不要改**。`profiles.medsec_role` 欄位用的就是上面那 5 個英文字串（snake_case），全程式碼都對應這些字串（`medsec-common.js` 的 `ROLE_PAGE_MAP`、`guardRole()` 呼叫參數）。

---

## 2. 檔案結構

```
medsec-app/
├── README.md              ← 一行字而已，先不管
├── index.html             ← 入口：meta refresh + JS redirect → login.html
├── login.html             ← 登入頁（員工編號 + 密碼）
├── manager.html           ← Lynn 的後台
├── candy.html             ← Candy 的後台（標案）
├── cindie.html            ← Cindie 的後台（採購）
├── accounting.html        ← 陳靖雅的後台（會計）
├── secretary.html         ← 業祕共用後台
├── medsec-common.css      ← 全站共用樣式
└── medsec-common.js       ← 全站共用 JS（Supabase client、guardRole、登出、nav 切換）
```

### 2.1 各檔案職責

#### `index.html`
- 12 行的 redirect 殼。`<meta http-equiv="refresh">` + `window.location.replace('login.html')` 雙保險。
- 不要在這加任何邏輯。

#### `login.html`
- 員工編號 + 密碼登入。
- 員工編號會被組成 `${emp}@medteam.internal` 假 email 丟給 `supa.auth.signInWithPassword()`（跟 medteam-app 同帳號規則）。
- 預設密碼是 `AE` + 員工編號（例如 `0006` 的預設密碼是 `AE0006`）。
- 登入後做兩道守門：
  1. `has_medsec_access === true`
  2. `medsec_role` 在 `ROLE_PAGE_MAP` 內
- 通過 → 跳到對應角色頁面，並顯示「歡迎 ${name}，正在進入 ${ROLE_LABEL}」。
- 沒登入也會自動跑 `autoRedirect()`：若已有 session 且權限 OK，直接跳。

#### `manager.html` / `candy.html` / `cindie.html` / `accounting.html` / `secretary.html`
**結構完全一樣**，差別只在：
1. `<title>` 跟 sidebar 的 role-tag class / 文字
2. nav 選單項目（每個角色看到的模組不同）
3. 底部 `guardRole('xxx')` 傳的角色字串
4. `mod-*` placeholder 內容（目前都還是「開發中」骨架）

每個頁面的開頭都是：
```js
(async function init() {
  const profile = await guardRole('manager'); // ← 換成各自角色
  if (!profile) return;
  renderUserInfo(profile);
  hideLoading();
})();
```

#### `medsec-common.css`
- 全站樣式，已用 CSS 變數定義配色（見 §6）。
- 包含 login 樣式、後台 sidebar + main layout、stat-card、placeholder、loading spinner、RWD（768px 以下 sidebar 變上方橫條）。

#### `medsec-common.js`
- `SUPABASE_URL` / `SUPABASE_ANON_KEY`（⚠️ 改了就要全 push）
- `ROLE_PAGE_MAP` / `ROLE_LABEL_MAP` / `ROLE_TAG_CLASS`
- `guardRole(requiredRole)` — 每個角色頁面進來必跑的 4 道守門：
  1. session 存在？
  2. profile 撈得到？
  3. `has_medsec_access === true`？
  4. `medsec_role === requiredRole`？（不符 → 跳回他自己的頁，避免越權）
- `renderUserInfo(profile)` — 渲染 sidebar 底部使用者資訊
- `handleLogout()` — 登出（含 confirm）
- `switchModule(moduleId)` — 單頁 nav 切換 placeholder
- `hideLoading()` — 守門通過後拿掉全屏遮罩

### 2.2 守門邏輯總圖

```
使用者打開任何頁面
    ↓
index.html ───→ login.html
                    ↓
            （已登入？）
              ↓ yes      ↓ no
       autoRedirect    停在登入頁
              ↓
       輸入帳密 → supa.auth.signInWithPassword
              ↓
       查 profiles.has_medsec_access + medsec_role
              ↓
       跳到 ROLE_PAGE_MAP[medsec_role]
              ↓
       該頁面 init() → guardRole('xxx')
              ↓
       不通過 → 跳回 login.html 或他自己的頁
       通過    → renderUserInfo + hideLoading
```

---

## 3. Supabase Schema 現狀

### 3.1 已建好（跟 medteam-app 共用）

**`profiles` table**（重點欄位）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | uuid (PK) | = `auth.users.id` |
| `employee_id` | text | 員工編號，例如 `0006` |
| `name` | text | 真實姓名 |
| `nickname` | text | 暱稱（sidebar 優先顯示） |
| `has_medteam_access` | bool | medteam-app 存取權 |
| `has_medsec_access` | bool | **medsec-app 存取權**（本專案用） |
| `medteam_role` | text | medteam-app 角色 |
| `medsec_role` | text | **本專案角色**（5 個值之一） |

### 3.2 RLS 政策現狀

- `profiles` 表 **已開 RLS**。
- `select` 政策：登入使用者只能讀自己的 row（`auth.uid() = id`）。
- 這對 `guardRole()` 夠用，但**後續加業務表時，RLS 要重新設計**（見 §4）。

### 3.3 5 人權限狀態（請進 Supabase Studio 驗證）

| 員工編號 | 名字 | `has_medsec_access` | `medsec_role` | 狀態 |
|---|---|---|---|---|
| ? | Lynn | true | `manager` | ✅ 已測 |
| ? | Candy | ? | `bidding_team` | ⚠️ 待驗證 |
| ? | Cindie | ? | `purchasing` | ⚠️ 待驗證 |
| ? | 陳靖雅 | ? | `accounting` | ⚠️ 待驗證 |
| ? | 雅婷 / 小飛 / 映晨 / 伶華 | ? | `secretary` | ⚠️ 待驗證 |

**接手第一件事**：去 Supabase Studio 把上表填完整，並確認 4 角色（Candy / Cindie / 會計 / 業祕）的 access flag 已開、role 已填正確。

---

## 4. 下一步要做的事（Week 3-1 ~ 3-5 路線圖）

### Week 3-1：完成 4 角色登入驗證（最優先 · 1~2 天）

**目標**：除了 Lynn 以外的 4 個角色（Candy、Cindie、會計、業祕）都能登入、被正確守門到自己頁面。

**步驟**：
1. 在 Supabase Studio 確認 5 個 profile 的 `has_medsec_access` + `medsec_role` 都填好。
2. 開無痕視窗用每個帳號實際登入跑一遍（重要：用無痕避開 session cache）。
3. 順便測**越權跳轉**：用 Candy 帳號直接打 `manager.html`，應該被踢回 `candy.html`。

### Week 3-2：建立業務資料表（5 天）

照 Lynn 之前畫的 schema 草稿建以下幾張表（**SQL 草稿在 §4.6**）：

- `hospitals` — 301 家醫院主檔（從 COPI01 匯入）
- `products` — 5260 筆產品主檔（從 INVI02 匯入）
- `hospital_systems` — 體系主檔（榮總體系 / 台大體系 …）
- `secretary_assignments` — 業祕 ↔ 醫院 分區
- `hospital_rules` — 257 家醫院的規則（取代散在 Excel）

### Week 3-3：seed data 匯入（2 天）

寫一個 Node script 或直接用 Supabase Studio 的 CSV import：
- COPI01 → `hospitals`
- INVI02 → `products`
- 4 業祕 × 186 醫院 → `secretary_assignments`

### Week 3-4：重設 RLS（2 天）

5 角色對業務表的讀寫權限完全不同，**舊的「只能讀自己」邏輯不夠用**。要按下表重新寫 RLS：

| 表 | manager | bidding_team | purchasing | accounting | secretary |
|---|---|---|---|---|---|
| `hospitals` | RW | R | R | R | R |
| `products` | RW | R | **RW** | R | R |
| `hospital_rules` | RW | R | R | R | RW（只自己分區的）|
| `secretary_assignments` | RW | R | — | — | R（只自己的）|
| `tenders` (Week 10) | R | **RW** | — | R | R |
| `bonds` (Week 13) | R | RW（押標金）| — | RW（傳票回填）| R |

RLS 邏輯要靠一個 helper function：
```sql
create or replace function auth_medsec_role() returns text
language sql stable as $$
  select medsec_role from profiles where id = auth.uid()
$$;
```

然後每個表的 policy 寫成 `auth_medsec_role() = 'manager' OR ...`。

### Week 3-5：報價決策 V1 核心模組（10 天）

把 manager.html 的「報價決策」placeholder 換成實際畫面：
1. 業祕在 secretary.html 提交決策包 → insert 到 `quote_decisions` 表
2. Lynn 在 manager.html 看 list（依 created_at desc + status='pending'）
3. Lynn 點開看 → 顯示 CRM 規則、歷史成交、體系報價、產品底價（auto-join）
4. Lynn 按「採納 / 調整」→ update status
5. 業祕看到狀態變化 → 打鼎新 CRM

### 4.6 Week 3-2 SQL 草稿（給接手直接貼）

```sql
-- hospitals
create table public.hospitals (
  id           uuid primary key default gen_random_uuid(),
  copi01_code  text unique not null,        -- COPI01 系統代碼
  name         text not null,
  short_name   text,
  system_id    uuid references public.hospital_systems(id),
  region       text,                         -- 北/中/南/東
  level        text,                         -- 醫學中心/區域/地區
  address      text,
  phone        text,
  is_active    bool default true,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);
create index on public.hospitals(system_id);
create index on public.hospitals(region);

-- hospital_systems
create table public.hospital_systems (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,         -- 'VGH', 'NTU', ...
  name        text not null,                -- '榮總體系'
  note        text,
  created_at  timestamptz default now()
);

-- products
create table public.products (
  id              uuid primary key default gen_random_uuid(),
  invi02_code     text unique not null,     -- 鼎新 INVI02 品號
  name            text not null,
  spec            text,
  product_line    text,                     -- 產品線
  vendor          text,                     -- 原廠
  health_code     text,                     -- 健保碼
  moh_license     text,                     -- 衛署字號
  moh_expiry      date,                     -- 衛署到期日
  qsd_version     text,
  qsd_expiry      date,
  base_price      numeric(12,2),
  is_active       bool default true,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
create index on public.products(moh_expiry);
create index on public.products(qsd_expiry);

-- secretary_assignments
create table public.secretary_assignments (
  id             uuid primary key default gen_random_uuid(),
  secretary_id   uuid not null references public.profiles(id),
  hospital_id    uuid not null references public.hospitals(id),
  is_primary     bool default true,
  backup_for     uuid references public.profiles(id), -- 代理人關係
  created_at     timestamptz default now(),
  unique (secretary_id, hospital_id)
);

-- hospital_rules
create table public.hospital_rules (
  id             uuid primary key default gen_random_uuid(),
  hospital_id    uuid not null references public.hospitals(id),
  category       text not null,             -- 'payment' | 'invoice' | 'logistics' | 'other'
  title          text not null,             -- 例：「付款條件」
  content        text not null,             -- 例：「月結 60 天」
  updated_by     uuid references public.profiles(id),
  updated_at     timestamptz default now()
);
create index on public.hospital_rules(hospital_id, category);

-- 全部開 RLS（policy 在 Week 3-4 再寫）
alter table public.hospitals             enable row level security;
alter table public.hospital_systems      enable row level security;
alter table public.products              enable row level security;
alter table public.secretary_assignments enable row level security;
alter table public.hospital_rules        enable row level security;
```

---

## 5. 踩過的坑（不要再踩）

### 5.1 anon key 單引號的奇葩 bug
之前 `SUPABASE_ANON_KEY` 從 Supabase Studio 複製時，貼進 `medsec-common.js` 後**頭尾各多了一個看不見的 zero-width space**，導致 Auth API 401。
- 修法：用編輯器選取整段 key 看長度（JWT 應該長到 220 字左右），不對就重複製。
- 補刀：每次更新 key 後**強制刷新瀏覽器**（Ctrl+Shift+R / Cmd+Shift+R），瀏覽器會 cache 舊的 JS。

### 5.2 Legacy anon key 還沒換 JWT-based key
Supabase 在 2026 初開始推新版「publishable key」，舊的 anon key 仍有效但建議遷移。**先不要急著換**，等業務表 / RLS 都 stable 再一次性升級。

### 5.3 強制刷新 ≠ 清 cache
改完 JS 後即使 Ctrl+Shift+R，有時 service worker 還是吃舊版。
- 修法：DevTools → Application → Service Workers → Unregister；或直接無痕視窗開。

### 5.4 一定要用無痕視窗測角色守門
非無痕視窗會記住上一個 session，測「Candy 越權打 manager.html」這種場景**一定要無痕**，否則永遠看到自己 cache 的 profile。

### 5.5 員工編號 0 開頭被當數字
員工編號 `0006` 是 text，不是 number。如果哪天有人在 Supabase Studio 把欄位改成 integer，0006 會變 6，登入就掛了。**永遠保持 `employee_id text`**。

### 5.6 `meta refresh` + `window.location.replace` 雙保險
某些瀏覽器（特別是企業 GPO 鎖過的 Edge）會擋 meta refresh，所以 `index.html` 同時用 JS。**不要拿掉其中任何一個。**

---

## 6. 設計風格規範

### 6.1 配色（CSS 變數已定）

```css
--primary: #1e3a8a;          /* 深靛主色 */
--primary-light: #3b82f6;    /* 互動 hover */
--primary-dark: #1e293b;     /* sidebar 底色 */
--accent: #6366f1;           /* 強調 */

/* 角色色（sidebar 頂部 tag 用） */
--role-manager: #7c3aed;     /* 紫 */
--role-bidding: #0891b2;     /* 青 */
--role-purchasing: #ea580c;  /* 橘 */
--role-accounting: #16a34a;  /* 綠 */
--role-secretary: #db2777;   /* 桃紅 */

/* 中性 */
--bg: #f8fafc;
--surface: #ffffff;
--border: #e2e8f0;
--text: #1e293b;
```

### 6.2 字體

- 中文：`Noto Sans TC`（已從 Google Fonts 載入）
- 數字 / 英文：fallback 到 `-apple-system, BlinkMacSystemFont, 'Segoe UI'`
- **不要引入新字體**，會破壞品牌一致性。

### 6.3 元件用法

- 頁面開頭固定有 `<div id="loading-mask">`，守門通過後才 `hideLoading()`，避免閃一下未授權的內容。
- 大塊未實作功能 → 用 `.placeholder` 元件（dashed border + emoji icon + 「V1 · Week X 開發」黃標）。
- 統計數字 → 用 `.stat-grid` + `.stat-card`，accent 樣式留給「最重要的那一格」。
- 一般容器 → `.card`。

### 6.4 不要做的事

- ❌ **不要引入框架**（React / Vue / Svelte）。保持 vanilla 是刻意決定。
- ❌ **不要引入 build step**（webpack / vite）。直接 HTML 就能跑。
- ❌ **不要用 inline `<style>`**。樣式統一寫進 `medsec-common.css`。
- ❌ **不要在頁面內 hardcode Supabase URL/key**。共用變數在 `medsec-common.js`。
- ❌ **不要動 sidebar 寬度**（240px 是排版基準）。
- ❌ **不要加任何 emoji 到 commit message / 文件以外的地方**（除非 Lynn 明確要求）。

---

## 7. Lynn 的偏好

- **講話直接**。不要寫「您好我是 AI 助理，很高興為您服務」這種開場。直接回答。
- **不過度問**。能從上下文推出來的不要問。真的需要選擇時，給 2~3 個選項 + 你的推薦。
- **繁中、台灣用語**。不要「软件」、「服务器」、「项目」、「视频」——用「軟體」、「伺服器」、「專案」、「影片」。
- **不要用 emoji**（產出檔案內部除外，像 `medsec-common.css` 已有的 emoji icon 留著）。
- **不要過度抽象**。三段相似的程式碼比一個過早的抽象好。
- **commit message 要說「為什麼」**，不要只描述「改了什麼」。
- **不要在 commit / PR 中提到 model 名稱**（claude-opus-4-7 那種 ID 不要寫進去）。

---

## 8. 立刻可以動工的第一步

**Week 3-1 — 完成 4 角色登入驗證**

```
1. 開 Supabase Studio
   → Authentication > Users：確認 5 個帳號都存在
   → Table Editor > profiles：5 個 row 的
     - has_medsec_access = true
     - medsec_role ∈ {manager, bidding_team, purchasing, accounting, secretary}

2. 開 5 個無痕視窗，分別用 5 個帳號登入：
   - Lynn   → 應跳到 manager.html
   - Candy  → 應跳到 candy.html
   - Cindie → 應跳到 cindie.html
   - 陳靖雅 → 應跳到 accounting.html
   - 業祕   → 應跳到 secretary.html

3. 測越權：用 Candy 登入後手動改 URL 到 /manager.html
   → 應被 guardRole('manager') 踢回 /candy.html

4. 測登出：每個帳號按登出 → 應跳回 login.html，session 清空

5. 全部 PASS 後，到 GitHub 開 issue「Week 3-1 完成」並列出測試結果。
   PASS 才能動 Week 3-2 schema。
```

如果某個帳號登不進去，常見原因排序：
1. profile.has_medsec_access 是 false（最常見）
2. medsec_role 拼錯（例如 `Manager` 而不是 `manager`）
3. 密碼錯（重設用 Supabase Studio 的 Reset password）

---

## 9. 最後叮嚀

**先幫 Lynn 做完 4 角色登入驗證。**

骨架已經寫好了，剩下的是資料層的事。不要急著開新模組、不要急著重構、不要急著「順手優化」guardRole — 它已經夠用了。

接到任務的順序：
1. ✅ 跑 §8 把 4 角色登入驗完
2. ✅ 把 §3.3 的表格填完整、推給 Lynn 確認
3. ✅ 開始 §4.6 的 schema（**先 review SQL，等 Lynn 點頭再 apply**，schema 一旦動了 RLS 也要跟著動）
4. ✅ Week 3-3 seed data 之前，先用 5~10 筆假資料測 RLS
5. ✅ 任何疑問 → 直接問 Lynn，**不要自己猜**

Good luck. 把這個平台做出來，4 個業祕扛 186 家醫院的日子會輕鬆很多。

— 前一棒交接 · 2026-05-13
