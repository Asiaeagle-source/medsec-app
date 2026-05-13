# `sql/` — Supabase Schema 擴充 + Seed 資料（V3）

> Lynn 拍板「不動既有 39 張表，對齊 medsec_* 灌資料」。
> 套用步驟看 **[IMPORT_GUIDE.md](IMPORT_GUIDE.md)**。

---

## 檔案結構

```
sql/
├── README.md
├── IMPORT_GUIDE.md                      ← 套用步驟（Lynn 看這個）
├── mapping_report.md                    ← 暱稱 ↔ 員工編號 mapping
├── sources_inventory.md                 ← 5 份原始檔欄位盤點
│
├── 01_extend_existing_schema.sql        ← 只 ADD 3 張新表
├── 02_extend_rls.sql                    ← 新表 RLS + trgm index + search RPC
├── 03_seed_hospital_systems.sql         ← 33 種體系
├── 04_seed_medsec_hospitals.sql         ← 184 醫院 → medsec_hospitals
├── 05_seed_medsec_products.sql          ← 5239 產品 → medsec_products (~1.4 MB)
├── 06_seed_medsec_secretary_assignments.sql  ← 182 業祕分區
├── 07_seed_medsec_salesperson_assignments.sql ← 236 業務分區（共管）
│
└── data/                                ← Studio Import 備援用
    ├── employees_for_review.csv         (60 員工對照)
    ├── hospital_systems.csv             (33 體系)
    ├── medsec_hospitals.csv             (184 醫院)
    ├── medsec_products.csv              (5239 產品)
    ├── medsec_secretary_assignments.csv (182 業祕)
    └── medsec_salesperson_assignments.csv (236 業務)
```

## 套用順序

只要 7 步：

1. **01** 建 3 張新表
2. **02** 開 RLS + 補 trgm index + search RPC
3. **03** 灌 33 體系
4. **04** 灌 184 醫院（`ON CONFLICT (parent_code) DO NOTHING`）
5. **05** 灌 5239 產品（`ON CONFLICT (catalog_number) DO NOTHING`）
6. **06** 灌 182 業祕分區（`ON CONFLICT (hospital_id) DO UPDATE`）
7. **07** 灌 236 業務分區（`ON CONFLICT (hospital_id, salesperson_id) DO NOTHING`）

## 重產資料

```bash
python3 tools/generate_import_data.py \
  --employees ... --copi01 ... --invi02 ... \
  --hospitals-csv ... --assignment-xlsx ...
python3 tools/generate_seed_sql.py
```

## 衝突保護

所有 INSERT 都有 `ON CONFLICT`：
- 既有資料優先（不會覆蓋）
- 重跑同一支 SQL 安全（idempotent）
