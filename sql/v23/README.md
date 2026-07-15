# V2.3 DMS「寄賣對帳」SQL(交 Lynn 審後執行)

> ⚠️ 這些 SQL **只產出、不由 CC 執行**。請 Lynn 審核後,依序在 Supabase SQL editor 跑。

## 執行順序
1. `01_dms_schema.sql` — `profiles.has_dms_access` 欄(pre-flight `ADD COLUMN IF NOT EXISTS`)+ `auth_can_dms()` helper + 4 張表。
2. `02_dms_rls.sql` — 4 張表 RLS,一律 `auth_can_dms()`(`has_dms_access` 或 `medsec_role IN ('manager','accounting')`)。
3. `03_dms_storage.sql` — 私有 bucket `dms-files` + `storage.objects` 政策(比照 ticket-files,收斂為 DMS 權限)。
4. `04_seed_material_code_map_r886.sql` — 向生 R886 料號對照 4 筆種子。

## 表
| 表 | 用途 |
|---|---|
| `consignment_sales` | 刀表(寄賣銷貨明細,xlsx 上傳落地) |
| `recon_statements` | 對帳單抬頭(status: draft/matched/confirmed) |
| `recon_statement_items` | 對帳單行項 + 媒合結果(match_status: ok/diff/pending) |
| `material_code_map` | 廠商料號↔品號對照 / 媒合規則(pattern[] + exclude[]) |

## 開通業祕
跑完 01~03 後,對要用 DMS 的業祕(或帳務)設旗標:
```sql
UPDATE public.profiles SET has_dms_access = true WHERE employee_id = '____';
```
(manager / accounting 角色自動有權,不必設旗標。)

## 前端相依
- 前端 `#mod-dms` 會 **pre-flight** 讀 `profiles.has_dms_access`;欄位不存在 / 無權 → 入口自動隱藏。**跑完 01 + 開通旗標後**,preview 上該業祕才會看到「寄賣對帳」入口。
- 上傳走 `dms-files` bucket signed URL(需 03)。

## R886 對照(§3)
| material_code | pattern | exclude | label |
|---|---|---|---|
| 1825226 | `T43102INT` | — | T43102INT |
| 1826395 | `2968%` | — | Olif/Clydesdale |
| 18263951 | `777%` | — | Elevate |
| 1826433 | `757%` | `7570955` | 757 系列 |
