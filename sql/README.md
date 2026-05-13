# `sql/` — Supabase Schema + Seed 資料

> 套用步驟請看 **[IMPORT_GUIDE.md](IMPORT_GUIDE.md)**。
> ⚠️ 任何 SQL 套用到 production 前，請 Lynn 先 review。

---

## 檔案結構

```
sql/
├── README.md                       ← 本檔
├── IMPORT_GUIDE.md                 ← Lynn 套用步驟
├── mapping_report.md               ← 5 份原始檔暱稱 mapping 報告
├── sources_inventory.md            ← 5 份原始檔欄位盤點 + 策略決策
│
├── 01_shared_schema.sql            ← 共用底層 schema (hospitals / products / assignments / systems)
├── 02_shared_rls.sql               ← RLS + helper functions + search_products RPC
├── 03_seed_hospital_systems.sql    ← 33 種醫院體系 INSERT
├── 06_seed_assignments.sql         ← 業務 + 業祕分區 INSERT（含 lookup join）
│
└── data/                           ← Studio Import 用的 CSV
    ├── employees_for_review.csv         (60 員工，供 Lynn 比對 profiles 是否齊全)
    ├── hospital_systems.csv             (33 種體系，已用 03_seed SQL 處理)
    ├── hospitals.csv                    (184 家醫院，Studio Import to tmp table)
    ├── products.csv                     (5239 筆產品，Studio Import direct)
    └── hospital_assignments.csv         (423 筆分區，已用 06_seed SQL 處理)
```

## 套用順序速覽

| # | 動作 | 工具 |
|---|---|---|
| 1 | 跑 `01_shared_schema.sql` | SQL Editor |
| 2 | 跑 `02_shared_rls.sql` | SQL Editor |
| 3 | 跑 `03_seed_hospital_systems.sql` | SQL Editor |
| 4 | 上傳 `data/hospitals.csv` 到 tmp table + 跑合併 SQL | Table Editor Import + SQL Editor |
| 5 | 上傳 `data/products.csv` | Table Editor Import |
| 6 | 跑 `06_seed_assignments.sql` | SQL Editor |

## 重新產生資料（原始檔有更新時）

```bash
# 從原始檔產 CSV
python3 tools/generate_import_data.py \
  --employees   ... \
  --copi01      ... \
  --invi02      ... \
  --hospitals-csv  ... \
  --assignment-xlsx ...

# 從 CSV 產 INSERT SQL
python3 tools/generate_seed_sql.py
```
