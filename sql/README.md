# `sql/` — Supabase Schema 草稿

> ⚠️ **任何 SQL 套用到 production 前，請 Lynn 先 review**。
> 套用順序就是檔名順序（01 → 02 → 03 …）。

---

## 套用方式（Supabase Studio）

1. 打開 https://supabase.com/dashboard/project/yincuegybnuzgojakkuc/sql/new
2. 依檔名順序，把整個檔案內容貼上 → Run
3. 跑完看「Results」分頁有沒有錯誤訊息
4. 第一次 Run 之前，建議在 Studio → Database → Backups 先按一下「Create snapshot」

---

## 檔案清單

| 檔名 | 階段 | 內容 | 套用狀態 |
|---|---|---|---|
| `01_shared_schema.sql` | Week 3-0.5（共用底層） | hospital_systems / hospitals / products / hospital_assignments + index + updated_at trigger | ⏳ 待 Lynn review |
| `02_shared_rls.sql` | Week 3-0.5 | RLS helper functions + 4 表 policy + `search_products` RPC | ⏳ 待 Lynn review |
| `03_seed_systems.sql` | Week 3-0.5 | 體系主檔種子（榮總/台大/長庚/…）| ⏳ 待寫 |
| `04_medsec_cases.sql` | Week 3-1 | medsec_cases / case_items / quote_decisions | ⏳ 待寫 |
| `05_medsec_cases_rls.sql` | Week 3-1 | medsec_cases 系列 RLS | ⏳ 待寫 |
| `06_medsec_bonds.sql` | Week 13-14 | medsec_bonds（保證金）| ⏳ 待 |

---

## 套用後的驗證指令

每跑完一個 SQL 檔，到 Studio SQL Editor 跑這幾條確認沒爛掉：

```sql
-- 1. 看表都建好了
select table_name from information_schema.tables
where table_schema = 'public' order by table_name;

-- 2. 看 RLS 都開了
select tablename, rowsecurity from pg_tables
where schemaname = 'public' order by tablename;

-- 3. 看 policy
select tablename, policyname, cmd from pg_policies
where schemaname = 'public' order by tablename, policyname;

-- 4. 測 search_products（要先有資料才有結果）
select * from public.search_products('內視鏡', 5);
```
