# sql/v11 · 待辦 v1.1 後端相依

前端變更在 `secretary-todo.js`(MedSec 端,無 schema 變更)。本目錄只放需 Lynn 審的新表,
及對既有欄位的**假設清單**,請確認。

## 1. 新表(需套用)
- `01_secretary_routines.sql` — 業祕個人例行清單模板。**請審核後再跑。**
  前端在此表不存在時會自動隱藏例行相關 UI(preflight `select id limit 1` 失敗即停用),不會報錯。

## 2. 既有欄位假設(不需改,只需確認存在)

### 2a. 期限(item 1)— 不動 schema、不動 view
- 寫入:`schedule_items.activities[0].deadline = 'YYYY-MM-DD'`(jsonb 搭便車)。
- 讀出:前端優先讀 `row.activities[0].deadline`,退回 `row.deadline`。
- **需確認**:`secretary_todos_v` 有把 `activities`(或 `deadline`)欄帶到前端。
  若 view 只投影 `content` 而未帶 `activities`,期限會寫得進、但顯示不出來 —
  屆時再請在 view 尾端補一欄 `activities`(或 `(activities->0->>'deadline') as deadline`)。

### 2b. 月結對帳自動待辦(item 2 每月層)
讀 `medsec_hospital_operation_rules`:
- `monthly_closing_day`(int/text,1–31)
- `monthly_closing_note`(text,要點,顯示於待辦內容)
規則:今天 = 該院月結日 → 長出「⏰ {醫院}月結對帳 — {note}」待辦;
設 31 但當月小月 → 當月最後一天觸發。防重:localStorage 當日旗標(對齊 carry-over)。
- **需確認**:上述兩欄存在於 `medsec_hospital_operation_rules`
  (V1 base 15 欄內或 MedTeam 已加)。缺欄時前端該步驟靜默略過,不影響清單載入。
- 只針對「我負責的醫院」:讀 `medsec_secretary_assignments`
  (`primary_secretary_id` / `co_secretary_id` = 我),join `medsec_hospitals.name_short` 取院名。
