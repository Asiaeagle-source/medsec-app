# `sql/v33/` — Lynn V3.3 拍板批次

> Lynn 拍板於 2026-05-13。對齊 HANDOVER.md V3.2（commit `19d0b9e`）。
> 目的：把 §9 四題答完 + 加 2 張新表，準備動 Week 3-1。

## 對應動工順序（00_DECISIONS.md）

| Step | 檔 | 動作 |
|---|---|---|
| 1 | `01_alter_medsec_cases.sql` | 補 4 欄（company / action_type / erp_doc_code / sop_ref）+ company / action_type CHECK + status CHECK 9 種 + `calc_erp_doc_code()` + `calc_sop_ref()` + `medsec_cases_autofill()` trigger（自動帶 case_no / erp_doc_code / sop_ref） |
| 2 | `02_medsec_cases_sales_insert_policy.sql` | `auth_medteam_role()` helper + 新增 2 個 policy：`medsec_cases_sales_insert`、`medsec_cases_sales_select`（**不動既有 2 個 policy**） |
| 3 | `03_consignment_inventory.sql` | 新建 `medsec_consignment_inventory`（寄售品庫存 WIS07）+ RLS 2 policy |
| 4 | `04_product_units.sql` | 新建 `medsec_product_units`（單台序號保固 WIS09）+ RLS 2 policy + `medsec_product_units_warranty` view |
| 5 | `05_decision_package_function.sql` | `compute_case_decision_package(case_id)` V1 純 aggregate（寫回 case + items） |

## 套用順序

照 01 → 02 → 03 → 04 → 05 依序貼 SQL Editor 跑。每支 5-10 秒。

## 驗證

```sql
-- (1) medsec_cases 從 29 → 33 欄
select column_name from information_schema.columns
where table_schema='public' and table_name='medsec_cases'
order by ordinal_position;

-- (2) erp_doc_code 函數
select public.calc_erp_doc_code('AE','coding');           -- AECC
select public.calc_erp_doc_code('LD','tender_supply');    -- ALDB

-- (3) medsec_cases policy 從 2 → 4
select policyname from pg_policies
where schemaname='public' and tablename='medsec_cases';

-- (4) 2 張新表
select table_name from information_schema.tables
where table_schema='public'
  and table_name in ('medsec_consignment_inventory','medsec_product_units');
-- → 2 列

-- (5) view + 函數
select viewname  from pg_views where viewname='medsec_product_units_warranty';
select proname   from pg_proc  where proname='compute_case_decision_package';
```

## 沒做的事（要 Lynn 後續處理）

1. **case_no race condition** — 同 (erp_doc_code, 日期) 同毫秒兩筆 INSERT 會產相同流水。V1 業務量極低不致命；V2 可改 advisory lock 或 day-stamped sequence。
2. **`compute_case_decision_package` 跑不出有意義數據** — `medsec_sales_history` 還 0 筆。Lynn 提供匯出來源後，函數立刻可用。
3. **SOP 提示卡硬編碼**（V3.3 Q5）— 前端 (action_type, status) 對 8-12 個提示卡是 HTML 端工作，不在這批 SQL 內。
4. **medteam-app 端「提詢價」按鈕**（動工順序 Step 8）— Lynn 另外規劃。SQL 端已準備好（policy + schema 都到位）。

## 不做的事

- ❌ 不 DROP / 不 ALTER 既有 22 張表的 policy（Lynn V3.3 Q4 守則）
- ❌ 不動既有 `medsec_cases` 兩個 policy（只新增 2 個）
- ❌ V1 不調 Claude API（V3.3 Q4 拍板）
