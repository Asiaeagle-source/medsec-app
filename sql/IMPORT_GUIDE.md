# Import 步驟指南（Lynn 套用 Supabase 用）

> **動 production 前，請務必先在 Supabase Studio → Database → Backups 按一次「Create snapshot」**。
> 萬一錯了可以 rollback。

> 套用環境：Supabase project `yincuegybnuzgojakkuc`

---

## 0. 前置確認

- [ ] 已備份 Supabase snapshot
- [ ] `profiles` 表存在且已有 60 員工資料（從員工總表匯入）
- [ ] 所有 60 員工的 `employee_id` 欄位與員工總表一致（`0011`、`0006` 等四位數字）

如果 `profiles` 還沒有 60 員工，先做：

> Studio → Authentication → 對每位員工建一個 supabase auth user（email = `{emp_id}@medteam.internal`、密碼預設 `AE{emp_id}`），  
> 並在 `profiles` 表把對應 row 補齊。  
> 已有員工資料的話 → 略過。

---

## 1. 建表 + RLS（兩支 schema SQL）

### Step 1.1 · 跑 `sql/01_shared_schema.sql`

開啟 Supabase Studio → SQL Editor → New query → 把 `01_shared_schema.sql` 整個貼上 → Run。

**驗證**：
```sql
select tablename from pg_tables
where schemaname = 'public'
  and tablename in ('hospital_systems','hospitals','products','hospital_assignments')
order by tablename;
```

應該看到 4 筆。

### Step 1.2 · 跑 `sql/02_shared_rls.sql`

同樣方式跑 `02_shared_rls.sql`。

**驗證**：
```sql
-- RLS 都開了
select tablename, rowsecurity from pg_tables
where schemaname = 'public'
  and tablename in ('hospital_systems','hospitals','products','hospital_assignments');

-- search_products RPC 存在
select proname from pg_proc where proname = 'search_products';
```

---

## 2. 灌種子資料（共 4 步）

### Step 2.1 · 跑 `sql/03_seed_hospital_systems.sql`

33 種體系。直接 SQL Editor 貼上 Run。

**驗證**：
```sql
select count(*) from public.hospital_systems;        -- 應為 33
select code, name from public.hospital_systems order by name limit 10;
```

### Step 2.2 · 上傳 `sql/data/hospitals.csv`（184 家醫院）

> ⚠️ CSV 有 `system_code` 欄、但 hospitals 表是 `system_id` (uuid)。  
> Studio 直接 import 會失敗 → 用下面這支 SQL 一鍵搞定（CSV 轉成 staging table → join hospital_systems 寫進 hospitals）

```sql
-- 1. 建 staging table 暫存 CSV
create table if not exists tmp_hospitals_import (like public.hospitals including defaults);
alter table tmp_hospitals_import add column system_code text;

-- 2. Studio Table Editor → tmp_hospitals_import → Import data → 選 sql/data/hospitals.csv
--    （勾選 column 對應：system_code 欄要對到 system_code 而不是 system_id）

-- 3. 把 staging 寫進 hospitals，順便 join system_code → system_id
insert into public.hospitals (
  copi01_code, name, short_name, aliases,
  system_id, level, region, region_copi01,
  tax_id, contact_name, phone, phone2, fax, email,
  registered_address, shipping_address, invoice_address,
  payment_term, payment_term_code, invoice_type, delivery_method,
  payment_method, tax_category,
  credit_rating, sales_rating, credit_limit,
  first_dealt_at, last_dealt_at,
  copi01_salesperson_id, copi01_salesperson_name,
  note, raw_copi01_data, is_active
)
select
  t.copi01_code, t.name, t.short_name, t.aliases,
  hs.id, t.level, t.region, t.region_copi01,
  t.tax_id, t.contact_name, t.phone, t.phone2, t.fax, t.email,
  t.registered_address, t.shipping_address, t.invoice_address,
  t.payment_term, t.payment_term_code, t.invoice_type, t.delivery_method,
  t.payment_method, t.tax_category,
  t.credit_rating, t.sales_rating, t.credit_limit,
  t.first_dealt_at, t.last_dealt_at,
  t.copi01_salesperson_id, t.copi01_salesperson_name,
  t.note, t.raw_copi01_data, t.is_active
from tmp_hospitals_import t
left join public.hospital_systems hs on hs.code = t.system_code
on conflict (copi01_code) do nothing;

-- 4. 清掉 staging
drop table tmp_hospitals_import;
```

**驗證**：
```sql
select count(*) from public.hospitals;                          -- 應為 184
select region, count(*) from public.hospitals group by region;  -- 北/中/南/花東/宜蘭/離島 分佈
select hs.name, count(*) from public.hospitals h
  join public.hospital_systems hs on hs.id = h.system_id
  group by hs.name order by count desc limit 10;
```

### Step 2.3 · 上傳 `sql/data/products.csv`（5239 筆產品）

產品沒有 lookup 問題，直接 Studio Import：

> Studio → Table Editor → `products` → Import data → 選 `sql/data/products.csv` → 對應欄位 → Run

**驗證**：
```sql
select count(*) from public.products;                          -- 應為 5239
select count(*) from public.products where moh_license <> '';  -- 應為 768
select * from public.search_products('內視鏡', 5);             -- 試模糊搜尋
```

### Step 2.4 · 跑 `sql/06_seed_assignments.sql`（業務 + 業祕分區）

421 筆 assignment。這支 SQL 內含 lookup 邏輯（用 copi01_code + employee_id join 進 hospital_assignments）。

直接 SQL Editor 貼上 Run。

**驗證**：
```sql
-- 總筆數
select role, count(*) from public.hospital_assignments group by role;
-- salesperson 應為 ~300、secretary 應為 ~180

-- 各業祕負責家數
select p.name as 業祕, count(*) as 家數
from public.hospital_assignments ha
join public.profiles p on p.id = ha.staff_id
where ha.role = 'secretary'
group by p.name
order by count desc;
-- 預期：關雅婷 57 / 楊斯閔 53 / 黃映晨 45 / 魏伶華 34

-- 各業務負責家數（前 10）
select p.name as 業務, count(*) as 家數
from public.hospital_assignments ha
join public.profiles p on p.id = ha.staff_id
where ha.role = 'salesperson'
group by p.name
order by count desc limit 10;
```

---

## 3. RLS 守門測試（最重要）

灌完資料後，用無痕視窗逐角色登入，確認分區守門有效：

```
測試 1：業祕雅婷 (0168) 登入 → 應該只看到 57 家醫院
測試 2：業務莊新力 (0087) 登入 → 應該只看到 ~11 家
測試 3：Lynn 0006 (manager) 登入 → 應該全看 184 家
測試 4：Candy 0132 / Cindie 0003 / 會計 0176 → 應該全看 184 家
```

確認方法（在 Studio 用 SQL Editor → Run as user 模擬，或在前端登入後 console 跑）：
```js
const { data, error } = await supa.from('hospitals').select('id, name').limit(300);
console.log(data?.length, error);  // 期望數字看上面
```

---

## 4. 還沒做的事（後續批次）

- [ ] **產品底價** — 等 Lynn 把底價檔給我，跑 `tools/generate_base_price_update.py`（待寫）
- [ ] **博仁綜合醫院** — Lynn 拍板跳過。若日後在 COPI01 補上，從 step 2.2 增量匯入
- [ ] **天祥醫院 TNTC** — Lynn 確認 = 天成系列。若要納入需另外處理（CSV 沒列 → 暫不匯）
- [ ] **業祕代理人 (`backup_secretary`)** — 暫無資料，請假時 manager 手動在 hospital_assignments 補一筆 `role='backup_secretary'`
- [ ] **衛署字號 regex 抽不到的 2862 筆** — 商品描述含「衛署」但不是標準格式，等後續手動補

---

## 5. 重做時的 reset

如果想全部刷新重來：

```sql
-- ⚠️ 會清掉本批資料；profiles 不動
truncate public.hospital_assignments cascade;
truncate public.hospitals cascade;
truncate public.products cascade;
truncate public.hospital_systems cascade;
```

然後重跑 Step 2.1 ~ 2.4。

---

## 6. 重新產資料（原始檔有更新）

下一次 COPI01 / INVI02 / hospitals CSV / 分區 xlsx 有更新時：

```bash
# 重新從原始檔產 CSV + SQL
python3 tools/generate_import_data.py \
  --employees      <path/to/員工總表.xlsx> \
  --copi01         <path/to/COPI01.XLSX> \
  --invi02         <path/to/INVI02.XLSX> \
  --hospitals-csv  <path/to/hospitals_template.csv> \
  --assignment-xlsx <path/to/分區歷史.xlsx>

python3 tools/generate_seed_sql.py

# 然後重跑 Step 2.1 ~ 2.4
```
