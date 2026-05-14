#!/usr/bin/env python3
"""
從 sql/data/*.csv 產出對齊既有 medsec_* schema 的 INSERT SQL。

執行：
  python3 tools/generate_seed_sql.py

產出：
  - sql/03_seed_hospital_systems.sql           (33 體系)
  - sql/04_seed_medsec_hospitals.sql           (184 醫院 INSERT ON CONFLICT DO NOTHING)
  - sql/05_seed_medsec_products.sql            (5239 產品 INSERT ON CONFLICT DO NOTHING)
  - sql/06_seed_medsec_secretary_assignments.sql  (業祕分區 + lookup profile.id)
  - sql/07_seed_medsec_salesperson_assignments.sql (業務分區 + lookup profile.id)
"""

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "sql" / "data"
SQL = ROOT / "sql"


def q(v: str | None) -> str:
    if v is None or v == "":
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def qbool(v: str) -> str:
    return "true" if str(v).lower() in {"true", "1", "y", "yes"} else "false"


def qnum(v: str) -> str:
    if v is None or v == "":
        return "NULL"
    try:
        float(v)
        return str(v)
    except ValueError:
        return "NULL"


def qint(v: str) -> str:
    if v is None or v == "":
        return "NULL"
    try:
        return str(int(float(v)))
    except ValueError:
        return "NULL"


# ============================================================
# 03 · hospital_systems
# ============================================================
def gen_hospital_systems():
    rows = list(csv.DictReader((DATA / "hospital_systems.csv").open(encoding="utf-8")))
    lines = [f"  ({q(r['code'])}, {q(r['name'])}, {q(r['copi01_name'])})" for r in rows]
    body = ",\n".join(lines)
    sql = (
        "-- ============================================================\n"
        "-- 03_seed_hospital_systems.sql · 33 種體系\n"
        "-- 套用：01_extend_existing_schema.sql + 02_extend_rls.sql 之後\n"
        "-- ============================================================\n\n"
        "insert into public.hospital_systems (code, name, copi01_name) values\n"
        f"{body}\n"
        "on conflict (name) do update set\n"
        "  code = excluded.code,\n"
        "  copi01_name = excluded.copi01_name;\n"
    )
    (SQL / "03_seed_hospital_systems.sql").write_text(sql, encoding="utf-8")
    print(f"  written: 03_seed_hospital_systems.sql ({len(rows)} rows)")


# ============================================================
# 04 · medsec_hospitals
# ============================================================
def gen_medsec_hospitals():
    rows = list(csv.DictReader((DATA / "medsec_hospitals.csv").open(encoding="utf-8")))
    lines = []
    for r in rows:
        vals = [
            q(r["id"]),                              # PK (text) = COPI01 代號
            q(r["name_full"]),
            q(r["name_short"]),
            q(r["tax_id"]),
            q(r["parent_code"]),
            q(r["system_prefix"]),
            qbool(r["is_standalone"]),
            qbool(r["is_distributor"]),
            q(r["customer_type"]),
            q(r["region_code"]),
            q(r["region_name"]),
            qint(r.get("invoice_company", "")),
            qbool(r["is_priority"]),
            q(r["sales_person"]),
            q(r["sales_person_code"]),
            q(r["business_department"]),
            q(r["primary_secretary"]),
            q(r["co_secretary"]),
            q(r["payment_terms"]),
            qint(r["payment_cycle_day"]),
            q(r["shipping_address"]),
            q(r["notes"]),
        ]
        lines.append(f"  ({', '.join(vals)})")

    body = ",\n".join(lines)
    sql = (
        "-- ============================================================\n"
        "-- 04_seed_medsec_hospitals.sql · 184 家醫院（COPI01 → medsec_hospitals）\n"
        "-- 套用：03 之後\n"
        "-- 既有 medsec_hospitals.id = text PK = COPI01 客戶代號 (CACN/TNH/...)\n"
        "-- 衝突保護：id 已存在則略過（既有資料優先）\n"
        "-- ============================================================\n\n"
        "insert into public.medsec_hospitals (\n"
        "  id, name_full, name_short, tax_id, parent_code, system_prefix,\n"
        "  is_standalone, is_distributor, customer_type,\n"
        "  region_code, region_name, invoice_company, is_priority,\n"
        "  sales_person, sales_person_code, business_department,\n"
        "  primary_secretary, co_secretary,\n"
        "  payment_terms, payment_cycle_day, shipping_address, notes\n"
        ") values\n"
        f"{body}\n"
        "on conflict (id) do nothing;\n"
    )
    (SQL / "04_seed_medsec_hospitals.sql").write_text(sql, encoding="utf-8")
    print(f"  written: 04_seed_medsec_hospitals.sql ({len(rows)} rows)")


# ============================================================
# 05 · medsec_products
# ============================================================
def gen_medsec_products():
    rows = list(csv.DictReader((DATA / "medsec_products.csv").open(encoding="utf-8")))

    def build_value_line(r):
        vals = [
            q(r["id"]),                              # PK (text) = INVI02 品號
            q(r["name"]),
            q(r["specification"]),
            q(r["manufacturer_code"]),
            q(r["manufacturer_name"]),
            q(r["product_line"]),
            q(r["product_series"]),
            q(r["dms_category"]),
            q(r["dms_subcategory"]),
            q(r["classification_level"]),
            qbool(r["is_sterile"]),
            q(r["storage_temp_range"]),
            q(r["storage_humidity"]),
            q(r["packaging_standard"]),
            q(r["service_procedure"]),
            q(r["uom"]),
            qint(r["qty_per_uom"]),
            q(r["catalog_number"]),
            q(r["status"]),
            q(r["replaced_by_product"]),
            qnum(r["list_price"]),
            qnum(r["cost_price"]),
            qnum(r["business_floor_price"]),
            qbool(r["has_nhi_code"]),
            q(r["notes"]),
        ]
        return f"  ({', '.join(vals)})"

    insert_head = (
        "insert into public.medsec_products (\n"
        "  id, name, specification, manufacturer_code, manufacturer_name,\n"
        "  product_line, product_series,\n"
        "  dms_category, dms_subcategory, classification_level,\n"
        "  is_sterile, storage_temp_range, storage_humidity,\n"
        "  packaging_standard, service_procedure,\n"
        "  uom, qty_per_uom, catalog_number, status, replaced_by_product,\n"
        "  list_price, cost_price, business_floor_price,\n"
        "  has_nhi_code, notes\n"
        ") values\n"
    )

    # 把 5239 row 拆成多份，每份 1000 row（SQL Editor 安全大小）
    CHUNK_SIZE = 1000
    chunks = [rows[i:i + CHUNK_SIZE] for i in range(0, len(rows), CHUNK_SIZE)]

    # 一支整合版（如果使用者要 connect 直連 DB 用，附在 sql/）
    all_lines = "\n".join(",\n".join(build_value_line(r) for r in c) for c in chunks)
    full_sql = (
        "-- 完整版（5239 row，需 psql 直連 DB；SQL Editor 過大）\n"
        f"{insert_head}"
        f"{all_lines}\n"
        "on conflict (id) do nothing;\n"
    )
    (SQL / "05_seed_medsec_products.sql").write_text(full_sql, encoding="utf-8")

    # 拆檔版（給 Studio SQL Editor 用，6 份）
    for idx, chunk in enumerate(chunks, start=1):
        body = ",\n".join(build_value_line(r) for r in chunk)
        sql_part = (
            "-- ============================================================\n"
            f"-- 05_seed_medsec_products_part{idx}.sql · 產品 part {idx}/{len(chunks)}\n"
            f"-- 本檔 {len(chunk)} 筆\n"
            "-- 套用：04 之後，依 part 順序貼上 SQL Editor 跑\n"
            "-- ============================================================\n\n"
            f"{insert_head}"
            f"{body}\n"
            "on conflict (id) do nothing;\n"
        )
        (SQL / f"05_seed_medsec_products_part{idx}.sql").write_text(sql_part, encoding="utf-8")

    print(f"  written: 05_seed_medsec_products.sql ({len(rows)} rows, full version)")
    print(f"  written: 05_seed_medsec_products_part{{1..{len(chunks)}}}.sql "
          f"({len(chunks)} chunks, ~{CHUNK_SIZE} rows each)")


# ============================================================
# 06 · medsec_secretary_assignments
# ============================================================
def gen_secretary_assignments():
    rows = list(csv.DictReader(
        (DATA / "medsec_secretary_assignments.csv").open(encoding="utf-8")))
    lines = []
    for r in rows:
        lines.append(
            f"  ({q(r['hospital_id'])}, {q(r['primary_secretary_emp'])}, "
            f"{q(r.get('co_secretary_emp') or '')})"
        )

    body = ",\n".join(lines)
    sql = (
        "-- ============================================================\n"
        "-- 06_seed_medsec_secretary_assignments.sql · 業祕分區\n"
        "-- 套用：04 之後（要 medsec_hospitals 已灌 + profiles 已有員工）\n"
        "-- hospital_id 直接是 medsec_hospitals.id（COPI01 代號）— 不需要 join lookup\n"
        "-- ============================================================\n\n"
        "with src(hospital_id, primary_emp, co_emp) as (values\n"
        f"{body}\n"
        ")\n"
        "insert into public.medsec_secretary_assignments (\n"
        "  hospital_id, primary_secretary_id, co_secretary_id, effective_date\n"
        ")\n"
        "select\n"
        "  src.hospital_id,\n"
        "  p1.id,\n"
        "  p2.id,\n"
        "  current_date\n"
        "from src\n"
        "join public.profiles      p1 on p1.employee_id = src.primary_emp\n"
        "left join public.profiles p2 on p2.employee_id = nullif(src.co_emp, '')\n"
        "on conflict (hospital_id) do update set\n"
        "  primary_secretary_id = excluded.primary_secretary_id,\n"
        "  co_secretary_id      = excluded.co_secretary_id,\n"
        "  effective_date       = excluded.effective_date,\n"
        "  updated_at           = now();\n\n"
        f"-- 共 {len(rows)} 筆業祕分區\n"
    )
    (SQL / "06_seed_medsec_secretary_assignments.sql").write_text(sql, encoding="utf-8")
    print(f"  written: 06_seed_medsec_secretary_assignments.sql ({len(rows)} rows)")


# ============================================================
# 07 · medsec_salesperson_assignments
# ============================================================
def gen_salesperson_assignments():
    rows = list(csv.DictReader(
        (DATA / "medsec_salesperson_assignments.csv").open(encoding="utf-8")))
    # 用員工總表全名 → emp_id
    name_to_emp = {}
    for r in csv.DictReader((DATA / "employees_for_review.csv").open(encoding="utf-8")):
        name_to_emp[r["name"]] = r["emp_id"]

    lines = []
    skipped = []
    for r in rows:
        emp = name_to_emp.get(r["emp_full_name"])
        if not emp:
            skipped.append((r["hospital_id"], r["emp_full_name"]))
            continue
        lines.append(
            f"  ({q(r['hospital_id'])}, {q(emp)}, {qint(r['display_order'])}, "
            f"{qbool(r['is_primary'])}, {q(r['source'])})"
        )

    body = ",\n".join(lines)
    sql = (
        "-- ============================================================\n"
        "-- 07_seed_medsec_salesperson_assignments.sql · 業務分區（normalized 共管）\n"
        "-- 套用：04 之後\n"
        "-- hospital_id 直接是 medsec_hospitals.id（COPI01 代號）— 不需要 join lookup\n"
        "-- lookup 失敗（員工總表查無）的 row 已從本檔排除\n"
        "-- ============================================================\n\n"
        "with src(hospital_id, emp_id, display_order, is_primary, source) as (values\n"
        f"{body}\n"
        ")\n"
        "insert into public.medsec_salesperson_assignments (\n"
        "  hospital_id, salesperson_id, display_order, is_primary, source\n"
        ")\n"
        "select\n"
        "  src.hospital_id, p.id, src.display_order, src.is_primary, src.source\n"
        "from src\n"
        "join public.profiles p on p.employee_id = src.emp_id\n"
        "on conflict (hospital_id, salesperson_id) do nothing;\n\n"
        f"-- 共 {len(lines)} 筆業務分區會寫入\n"
        f"-- 跳過 {len(skipped)} 筆 lookup 失敗\n"
    )
    (SQL / "07_seed_medsec_salesperson_assignments.sql").write_text(sql, encoding="utf-8")
    print(f"  written: 07_seed_medsec_salesperson_assignments.sql "
          f"({len(lines)} rows, skipped {len(skipped)})")
    if skipped:
        with (DATA / "SALESPERSON_SKIPPED.txt").open("w", encoding="utf-8") as f:
            f.write("以下業務 row lookup 不到員工，已排除：\n\n")
            for code, name in skipped:
                f.write(f"  {code} ← {name!r}\n")


if __name__ == "__main__":
    gen_hospital_systems()
    gen_medsec_hospitals()
    gen_medsec_products()
    gen_secretary_assignments()
    gen_salesperson_assignments()
