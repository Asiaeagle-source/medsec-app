#!/usr/bin/env python3
"""
從 sql/data/*.csv 產出 INSERT SQL（給 Supabase Studio 一鍵套用）

執行：
  python3 tools/generate_seed_sql.py

產出：
  - sql/03_seed_hospital_systems.sql
  - sql/06_seed_assignments.sql
  - sql/data/MOH_REGEX_DEBUG.txt（衛署字號抽取結果說明，方便 review）
"""

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "sql" / "data"
SQL = ROOT / "sql"


def sql_escape(v: str) -> str:
    if v is None or v == "":
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def sql_bool(v: str) -> str:
    return "true" if str(v).lower() in {"true", "1", "y", "yes"} else "false"


# ============================================================
# 03_seed_hospital_systems.sql
# ============================================================
def gen_systems():
    rows = list(csv.DictReader((DATA / "hospital_systems.csv").open(encoding="utf-8")))
    out = ["-- ============================================================"]
    out.append("-- 03_seed_hospital_systems.sql — 從 COPI01 通路別名稱抽出的 33 種體系")
    out.append("-- 套用順序：02_shared_rls.sql 之後")
    out.append("-- ============================================================")
    out.append("")
    out.append("insert into public.hospital_systems (code, name, copi01_name) values")
    lines = []
    for r in rows:
        lines.append(
            f"  ({sql_escape(r['code'])}, {sql_escape(r['name'])}, {sql_escape(r['copi01_name'])})"
        )
    out.append(",\n".join(lines))
    out.append("on conflict (name) do update set")
    out.append("  code = excluded.code,")
    out.append("  copi01_name = excluded.copi01_name;")
    (SQL / "03_seed_hospital_systems.sql").write_text("\n".join(out), encoding="utf-8")
    print(f"  written: sql/03_seed_hospital_systems.sql ({len(rows)} 種體系)")


# ============================================================
# 06_seed_assignments.sql
#   業務 / 業祕分區的 INSERT，靠 hospital.copi01_code + profile.employee_id lookup
# ============================================================

# Lynn 拍板的暱稱 → 員工編號
SALES_NICK_TO_EMP = {
    "婷瑜": "0023", "慧雯": "0071", "莊新力": "0087", "新力": "0087",
    "緯棋": "0098", "婉婷": "0033", "婷方": "0007", "沐柔": "0045",
    "怡安": "0081", "思閔": "0069", "智傑": "0106", "慈芳": "0093",
    "秋涵": "0137", "湘庭": "0149", "紀怡安": "0117",
    "子恩": "0120", "蕙如": "0113", "虹均": "0017", "吟欣": "0019",
    "瀞媛": "0018", "悅筠": "0076", "開開": "0068",
    "奕廷": "0070", "耘旗": "0146", "婉萱": "0089",
    "伊媄": "0099", "祖潤": "0109", "張銘": "0111",
    "李暐": "0039", "劉翊宏": "0134", "靜彤": "0077",
    "ABBY": "0105", "BEN": "0128", "MICHAEL": "0134",
    "vivi": "0071", "viola": "0016",
    "BOB": "0059", "JEFF": "0067",
}
SECRETARY_NICK_TO_EMP = {
    "雅婷": "0168", "小飛": "0011", "映晨": "0150", "伶華": "0020",
}

# 業務全名（CSV `responsible` 欄）→ 員工編號（從員工總表組）
def build_fullname_to_emp():
    emp = {}
    for r in csv.DictReader((DATA / "employees_for_review.csv").open(encoding="utf-8")):
        emp[r["name"]] = r["emp_id"]
    return emp


def gen_assignments():
    fullname_to_emp = build_fullname_to_emp()
    rows = list(csv.DictReader((DATA / "hospital_assignments.csv").open(encoding="utf-8")))

    out = ["-- ============================================================"]
    out.append("-- 06_seed_assignments.sql — 業務 + 業祕 分區")
    out.append("-- 套用順序：hospitals.csv / employees 都 import 完之後")
    out.append("-- 依賴：")
    out.append("--   - public.hospitals 已 import（用 copi01_code lookup）")
    out.append("--   - public.profiles 已 import（用 employee_id lookup）")
    out.append("-- 邏輯：暱稱/全名 lookup 不到的 row 會被 LEFT JOIN 變 NULL → ON CONFLICT 略過")
    out.append("-- ============================================================")
    out.append("")
    out.append("with src(copi01_code, employee_id, role, is_primary, source) as (values")

    lines = []
    skipped = []
    for r in rows:
        emp_id = None
        if r["role"] == "salesperson":
            emp_id = fullname_to_emp.get(r["emp_full_name"])
            if not emp_id:
                skipped.append(("salesperson", r["copi01_code"], r["emp_full_name"]))
                continue
        elif r["role"] == "secretary":
            emp_id = SECRETARY_NICK_TO_EMP.get(r["emp_nick"])
            if not emp_id:
                skipped.append(("secretary", r["copi01_code"], r["emp_nick"]))
                continue
        lines.append(
            f"  ({sql_escape(r['copi01_code'])}, {sql_escape(emp_id)}, "
            f"{sql_escape(r['role'])}, {sql_bool(r['is_primary'])}, {sql_escape(r['source'])})"
        )

    out.append(",\n".join(lines))
    out.append(")")
    out.append("insert into public.hospital_assignments (hospital_id, staff_id, role, is_primary, source)")
    out.append("select h.id, p.id, src.role::public.hospital_assignment_role, src.is_primary, src.source")
    out.append("from src")
    out.append("join public.hospitals h on h.copi01_code = src.copi01_code")
    out.append("join public.profiles  p on p.employee_id = src.employee_id")
    out.append("on conflict (hospital_id, staff_id, role) do nothing;")
    out.append("")
    out.append(f"-- 共 {len(lines)} 筆 assignment 會寫入")
    out.append(f"-- 跳過 {len(skipped)} 筆（lookup 不到員工）")

    (SQL / "06_seed_assignments.sql").write_text("\n".join(out), encoding="utf-8")
    print(f"  written: sql/06_seed_assignments.sql ({len(lines)} rows, skipped {len(skipped)})")
    if skipped:
        print(f"  [warn] 跳過範例: {skipped[:5]}")
        with (DATA / "ASSIGNMENTS_SKIPPED.txt").open("w", encoding="utf-8") as f:
            f.write("以下 row lookup 不到員工，已從 06_seed_assignments.sql 排除：\n\n")
            for role, code, name in skipped:
                f.write(f"  [{role}] {code} ← {name!r}\n")


if __name__ == "__main__":
    gen_systems()
    gen_assignments()
