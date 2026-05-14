# Import 步驟指南（V3 — 對齊既有 39 張表）

> **動 production 前，先做一個 backup snapshot**：
> 🔗 [Supabase Database Backups](https://supabase.com/dashboard/project/yincuegybnuzgojakkuc/database/backups)

> 套用環境：Supabase project `yincuegybnuzgojakkuc`
> 既有 39 張表完全不動。本批只新增 3 張表 + 灌資料到既有 `medsec_*` 表。

---

## 套用順序總覽

| Step | 檔 | 動作 | 預計時間 |
|---|---|---|---|
| 1 | `01_extend_existing_schema.sql` | SQL Editor 貼整份 → Run | 5 秒 |
| 2 | `02_extend_rls.sql` | SQL Editor 貼整份 → Run | 5 秒 |
| 3 | `03_seed_hospital_systems.sql` | SQL Editor 貼整份 → Run（33 體系）| 5 秒 |
| 4 | `04_seed_medsec_hospitals.sql` | SQL Editor 貼整份 → Run（184 醫院）| 10 秒 |
| 5 | `05_seed_medsec_products.sql` | SQL Editor 貼整份 → Run（5239 產品，1.4 MB SQL）| 30-60 秒 |
| 6 | `06_seed_medsec_secretary_assignments.sql` | SQL Editor 貼整份 → Run（182 業祕分區）| 5 秒 |
| 7 | `07_seed_medsec_salesperson_assignments.sql` | SQL Editor 貼整份 → Run（236 業務分區）| 5 秒 |
| 8 | RLS 守門驗證 | 用無痕視窗逐角色登入 | 5 分鐘 |

---

## Step 1 · 建 3 張新表

> 不動既有 39 張表，只 ADD：
> - `hospital_systems`（33 種體系主檔）
> - `product_base_prices`（產品底價，鎖 manager）
> - `medsec_salesperson_assignments`（業務 ↔ 醫院 共管）

🔗 [打開 SQL Editor](https://supabase.com/dashboard/project/yincuegybnuzgojakkuc/sql) → 點 `+ New query` → 把下面整份檔案內容貼上 → Run

📄 [01_extend_existing_schema.sql](./01_extend_existing_schema.sql)

**驗證**（在 SQL Editor 跑）：
```sql
select tablename from pg_tables
where schemaname = 'public'
  and tablename in ('hospital_systems','product_base_prices','medsec_salesperson_assignments');
-- 應該回 3 筆
```

## Step 2 · 開 RLS + 補 trigram index + search RPC

📄 [02_extend_rls.sql](./02_extend_rls.sql)

**驗證**：
```sql
-- RLS 都開了
select tablename, rowsecurity from pg_tables
where schemaname = 'public'
  and tablename in ('hospital_systems','product_base_prices','medsec_salesperson_assignments');

-- 模糊搜尋 RPC 存在
select proname from pg_proc where proname = 'search_medsec_products';
```

## Step 3 · 灌 33 種體系

📄 [03_seed_hospital_systems.sql](./03_seed_hospital_systems.sql)

**驗證**：
```sql
select count(*) from public.hospital_systems;       -- 應為 33
select code, name from public.hospital_systems order by name limit 5;
```

## Step 4 · 灌 184 家醫院（COPI01 → `medsec_hospitals`）

> ⚠️ 已 `ON CONFLICT (parent_code) DO NOTHING` — 既有 `parent_code` 重複的會略過。

📄 [04_seed_medsec_hospitals.sql](./04_seed_medsec_hospitals.sql)

**驗證**：
```sql
select count(*) from public.medsec_hospitals;
-- 若你本來就有醫院資料 → 原本筆數 + 新增（沒衝突的）
-- 若本來是空 → 應為 184

select region_name, count(*) from public.medsec_hospitals group by region_name;
-- 北/中/南/花東/宜蘭/離島 分佈
```

## Step 5 · 灌 5239 筆產品（INVI02 → `medsec_products`，最慢）

> ⚠️ SQL 檔約 1.4 MB。Studio SQL Editor 應能吃。若慢就等。
> 已 `ON CONFLICT (catalog_number) DO NOTHING`。

📄 [05_seed_medsec_products.sql](./05_seed_medsec_products.sql)

> **如果 SQL Editor 吃不下**（極少數情況），改用備援方案：
> Table Editor → `medsec_products` → Import data → 上傳 `sql/data/medsec_products.csv`
> 📦 [medsec_products.csv (1 MB)](./data/medsec_products.csv)

**驗證**：
```sql
select count(*) from public.medsec_products;
select count(*) from public.medsec_products where notes like '%衛署%';   -- 約 768 筆
select * from public.search_medsec_products('內視鏡', 5);                -- 試模糊搜尋
```

## Step 6 · 灌 182 筆業祕分區

> 一家 1 row：`primary_secretary_id` + `co_secretary_id`（既有結構）
> 已 `ON CONFLICT (hospital_id) DO UPDATE` — 已存在的會更新

📄 [06_seed_medsec_secretary_assignments.sql](./06_seed_medsec_secretary_assignments.sql)

**驗證**：
```sql
select p.name as 業祕, count(*) as 家數
from public.medsec_secretary_assignments msa
join public.profiles p on p.id = msa.primary_secretary_id
group by p.name
order by count desc;
-- 預期：關雅婷 ≈57 / 楊斯閔 ≈53 / 黃映晨 ≈45 / 魏伶華 ≈34
```

## Step 7 · 灌 236 筆業務分區（共管）

> Normalized：一家可多 row，display_order=0 主負責、1+ 共管

📄 [07_seed_medsec_salesperson_assignments.sql](./07_seed_medsec_salesperson_assignments.sql)

**驗證**：
```sql
select p.name as 業務, count(*) as 家數
from public.medsec_salesperson_assignments msa
join public.profiles p on p.id = msa.salesperson_id
group by p.name
order by count desc limit 10;

-- 看共管前 5 家
select h.name_short, count(*) as 業務數
from public.medsec_salesperson_assignments msa
join public.medsec_hospitals h on h.id = msa.hospital_id
group by h.name_short
having count(*) >= 2
order by count(*) desc limit 5;
```

## Step 8 · RLS 守門測試（最重要）

用無痕視窗逐角色登入 `login.html`：

| 帳號 | 期望結果 |
|---|---|
| 雅婷 0168（雅婷@medteam.internal）| 看到約 57 家醫院 |
| 莊新力 0087 | 看到約 11 家 |
| Lynn 0006（manager）| 看到全部 184 家 |
| Candy 0132 / Cindie 0003 / 會計 0176 | 看到全部 184 家 |

確認方法（前端 console）：
```js
const { data } = await supa.from('medsec_hospitals').select('id, name_short');
console.log(data?.length);
```

---

## 還沒做的事（後續批次）

- **產品底價** — 等 Lynn 把底價檔給我，跑 update script 灌 `product_base_prices`
- **博仁綜合醫院** — 跳過（Lynn 拍板）
- **天祥醫院 TNTC** — 已對應到天成（CSV 未列、暫不匯）
- **衛署字號 regex 抽不到的 2862 筆** — 商品描述含「衛署」但格式不一致，後續優化

---

## 重做時的 reset

```sql
-- ⚠️ 會清掉本批新增的 3 張表 + 從 medsec_hospitals/products 移除 parent_code 來自 COPI01 的資料
truncate public.hospital_systems cascade;
truncate public.product_base_prices cascade;
truncate public.medsec_salesperson_assignments cascade;
-- medsec_hospitals / medsec_products / medsec_secretary_assignments 既有的不動
-- 若你要連帶清掉本批匯入的醫院/產品，要先 select 看 parent_code / catalog_number 來源
```

---

## 重新產資料（原始檔有更新時）

```bash
python3 tools/generate_import_data.py \
  --employees       <員工總表.xlsx> \
  --copi01          <COPI01.XLSX> \
  --invi02          <INVI02.XLSX> \
  --hospitals-csv   <hospitals_template.csv> \
  --assignment-xlsx <分區歷史.xlsx>

python3 tools/generate_seed_sql.py

# 然後重跑 Step 3 ~ Step 7
```
