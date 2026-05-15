# sql/v2/ — Sprint 1「醫院規則中央化 + 規則自學」

## 用途

V2 Sprint 1 對齊 V1 既有架構的 schema + RLS 批次。
原 V2 handoff 走 BIGSERIAL + `current_setting('app.current_user_code')`，
本批次全部改用 V1 既有 text PK + `auth.uid()`。

## Lynn 拍板（2026-05-14）

| # | 題 | 拍板 |
|---|---|---|
| Q1 | `medsec_hospital_operation_rules` 補欄位 | ADD 3 欄：`shipping_method` / `invoice_track` / `dual_invoice`（不 ADD `has_consignment`，跟 `medsec_consignment_inventory` 表重複）|
| Q2 | 完整度分母 | 9（既有 7 + 新 ADD 2 個關鍵：`shipping_method` / `invoice_track`；`dual_invoice` 不計入完整度）|
| Q3 | `medsec_rule_suggestions` FK | `hospital_id text → medsec_hospitals(id)` + `suggested_by/reviewed_by uuid → profiles(id)` |
| Q4 | `medsec_hospital_credentials` FK | 同 Q3 型別 |
| Q5 | `medsec_audit_log` FK | 同 Q3 型別 |
| Q6 | 業祕分區邏輯 | reuse 既有 `can_see_medsec_hospital(h_id text)` |
| Q7 | 副祕看 credentials | 主祕 + 副祕都看（4 業祕互信、副祕為代理人）|
| Q8 | hospitals 數字差異 | Sprint 1 只動 185 已 seed |
| Q9 | `medsec_employees` vs `profiles` | 捨 employees，全用 profiles |
| Q10 | 4 家未對應折讓 | 排除，標 `needs_review` 等補 |

完整推導見 `docs/v1_schema_snapshot_and_v2_conflicts.md` Part 4。

## 套用順序

| Step | 檔 | 動作 | 時間 |
|---|---|---|---|
| 1 | `01_alter_operation_rules.sql` | `medsec_hospital_operation_rules` ALTER ADD 3 欄 | 3 秒 |
| 2 | `02_create_rule_suggestions.sql` | 新建 `medsec_rule_suggestions` + index | 3 秒 |
| 3 | `03_create_hospital_credentials.sql` | 新建 `medsec_hospital_credentials` + index | 3 秒 |
| 4 | `04_create_audit_log.sql` | 新建 `medsec_audit_log` + index | 3 秒 |
| 5 | `05_create_completeness_view.sql` | view `medsec_hospital_rule_completeness` | 3 秒 |
| 6 | `06_rls_v2_sprint1.sql` | helper `auth_is_manager_or_co_reviewer()` + 4 條新 policy | 5 秒 |

> 06 不動既有 `medsec_hospitals` / `medsec_hospital_operation_rules` 的 1 條既存 policy；
> 只在新建的三張表加 policy。如果 V2 sprint 1 §3.1 secretary.html 需要更寬的
> `medsec_hospitals` SELECT，Lynn 再另開 widen 批次。

## 跑完驗證

```sql
-- 1. 表結構
SELECT table_name FROM information_schema.tables
WHERE table_schema='public'
  AND table_name IN (
    'medsec_rule_suggestions',
    'medsec_hospital_credentials',
    'medsec_audit_log',
    'medsec_hospital_rule_completeness')      -- view 也在這個 catalog (table_type='VIEW')
ORDER BY table_name;
-- 預期 4 列（1 view 也在）

-- 2. operation_rules 新增 3 欄
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name='medsec_hospital_operation_rules'
  AND column_name IN ('shipping_method','invoice_track','dual_invoice');
-- 預期 3 列

-- 3. 3 張新表 RLS 開啟
SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN ('medsec_rule_suggestions','medsec_hospital_credentials','medsec_audit_log');
-- 預期全 true

-- 4. policy 數
SELECT tablename, count(*) FROM pg_policies
WHERE schemaname='public' AND tablename IN
  ('medsec_rule_suggestions','medsec_hospital_credentials','medsec_audit_log')
GROUP BY tablename ORDER BY tablename;
-- 預期 suggestions=3 (insert/update/select), credentials=1, audit_log=2

-- 5. 完整度 view 撈 5 筆看
SELECT * FROM medsec_hospital_rule_completeness LIMIT 5;
-- 預期非空（185 筆，但都 completeness_pct=0 因為 operation_rules 全空）
```

## 為什麼不 seed

V2 zip（`medsec_v2_sprint1.sql` + `_part3.sql`）裡的 INSERT 走 `(SELECT id FROM medsec_hospitals WHERE dingxin_code='X')`。V1 `medsec_hospitals.id` 本身就是鼎新代號，所以子查詢的 `dingxin_code` 欄不存在 → 子查詢失敗。需要先做 ETL：

1. 把 `(SELECT id FROM medsec_hospitals WHERE dingxin_code='X')` 替換成 `'X'`
2. operation_rules 欄名 rename：`payment_cycle` → `payment_cycle_note`、`invoice_product_name_style` → `invoice_product_name`
3. operation_rules 拿掉 `has_consignment`、`consignment_notes` 兩欄（V1 不 ADD 這兩個）
4. discount_rules 欄位差異對齊（V1 17 欄 vs V2 12 欄，欄名也不同）— 這部分等 V2 sprint 2 再處理
5. hospitals / hospital_systems / employees / secretary_assignments 全跳過（V1 已 seed）

ETL 之後再交給 Lynn 跑。本批次只動 schema 不動資料。
