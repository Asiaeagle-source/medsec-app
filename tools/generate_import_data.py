#!/usr/bin/env python3
"""
AE Hub · 把 5 份原始檔 (員工總表 / COPI01 / INVI02 / hospitals CSV / 分區歷史)
轉換成 Supabase Studio 可直接上傳的 CSV + INSERT SQL。

執行：
  python3 tools/generate_import_data.py \
    --employees      ~/.claude/uploads/.../員工總表.xlsx \
    --copi01         ~/.claude/uploads/.../COPI01.XLSX \
    --invi02         ~/.claude/uploads/.../INVI02.XLSX \
    --hospitals-csv  ~/.claude/uploads/.../hospitals_template.csv \
    --assignment-xlsx ~/.claude/uploads/.../分區歷史.xlsx

輸出（寫入 sql/data/）：
  - hospital_systems.csv       （hospital_systems 體系主檔）
  - hospitals.csv              （hospitals 醫院主檔）
  - products.csv               （products 產品主檔）
  - hospital_assignments.csv   （業務 + 業祕分區）
  - employees_for_review.csv   （員工 id 對應，供 Lynn 確認 supabase auth user）
"""

import argparse
import csv
import io
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

from xlsx2csv import Xlsx2csv

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "sql" / "data"

# ------------------------------------------------------------
# Lynn 拍板的暱稱 → 員工編號
# ------------------------------------------------------------
SALES_NICK_TO_EMP = {
    # 中文單名（從 mapping_report 對應）
    "婷瑜": "0023", "慧雯": "0071", "莊新力": "0087", "新力": "0087",
    "緯棋": "0098", "婉婷": "0033", "婷方": "0007", "沐柔": "0045",
    "怡安": "0081", "思閔": "0069", "智傑": "0106", "慈芳": "0093",
    "秋涵": "0137", "湘庭": "0149", "紀怡安": "0117",
    "子恩": "0120", "子恩(SPS)": "0120",
    "蕙如": "0113", "虹均": "0017", "吟欣": "0019",
    "瀞媛": "0018", "悅筠": "0076", "開開": "0068",
    "奕廷": "0070", "耘旗": "0146",
    "婉萱": "0089", "婉萱(SCS)": "0089",
    "伊媄": "0099", "祖潤": "0109", "張銘": "0111",
    "李暐": "0039", "劉翊宏": "0134",
    "靜彤": "0077",  # 0077 董靜彤（從 COPI01 補上）
    # 英文名（Lynn 拍板）
    "ABBY": "0105", "BEN": "0128", "MICHAEL": "0134",
    "vivi": "0071", "viola": "0016",
    "BOB": "0059", "JEFF": "0067",
    # 拍板：JOSIE 離職
    # 找不到的：宇容、小駱、欣怡、欣翎 → 略過
}

# ------------------------------------------------------------
# 業祕暱稱 → 員工編號
# ------------------------------------------------------------
SECRETARY_NICK_TO_EMP = {
    "雅婷": "0168",
    "小飛": "0011",
    "映晨": "0150",
    "伶華": "0020",
}

# 醫院 level 篩選（INVI02 型態別名稱）
HOSPITAL_LEVELS = {"醫學中心", "區域醫院", "地區醫院", "大學", "動物醫院", "診所"}

# 商品篩選（INVI02 商品分類一）
PRODUCT_CATEGORY_KEEP = {"商品"}  # 排除「費用」「虛擬」

# 衛署字號 regex（從 INVI02 商品描述抽）
MOH_PATTERN = re.compile(r"衛署[醫器材輸製造販售檢校驗]+字第\s*\d+\s*號")


# ============================================================
# 1. 讀取輔助
# ============================================================
def read_xlsx_sheet(path: Path, sheet_idx: int = 1) -> tuple[list[str], list[list[str]]]:
    """讀 xlsx 的指定 sheet（鼎新匯出常含異常 style，用 xlsx2csv 比 openpyxl 穩）"""
    buf = io.StringIO()
    Xlsx2csv(str(path), outputencoding="utf-8").convert(buf, sheetid=sheet_idx)
    buf.seek(0)
    rows = list(csv.reader(buf))
    return rows[0], rows[1:]  # 第一行 header（呼叫端各自處理）


def read_copi01(path: Path) -> tuple[list[str], list[dict]]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[2]  # 鼎新格式：row 1 標題、row 2 空、row 3 欄位
    data = [dict(zip(header, r)) for r in rows[3:] if r and r[0].strip()]
    return header, data


def read_invi02(path: Path) -> tuple[list[str], list[dict]]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[2]
    data = [dict(zip(header, r)) for r in rows[3:] if r and r[0].strip()]
    return header, data


def read_employees(path: Path) -> list[dict]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    # 員工總表：row 1-6 是 metadata，row 7-8 是 merged header，data 從 row 9 開始
    data = []
    for r in rows[8:]:
        if len(r) < 12 or not r[3]:
            continue
        data.append(
            {
                "emp_id": str(r[3]).strip(),
                "name": (r[4] or "").strip(),
                "dept": (r[8] or "").strip(),
                "category": (r[9] or "").strip(),
                "position": (r[10] or "").strip(),
                "status": (r[11] or "").strip(),
            }
        )
    return data


def read_hospitals_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig") as f:
        return [r for r in csv.DictReader(f) if (r.get("name") or "").strip()]


def read_assignments_xlsx(path: Path) -> list[dict]:
    """讀分區歷史 xlsx，取『20260511分區』欄當業祕最新分區"""
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[0]
    idx_code = header.index("新客戶編號")
    idx_latest = header.index("20260511分區")
    out = []
    for r in rows[1:]:
        code = (r[idx_code] or "").strip() if r[idx_code] else ""
        latest = (r[idx_latest] or "").strip() if len(r) > idx_latest and r[idx_latest] else ""
        if code and latest:
            out.append({"copi01_code": code, "secretaries": latest})
    return out


def _xlsx_to_csv_str(path: Path) -> str:
    buf = io.StringIO()
    Xlsx2csv(str(path), outputencoding="utf-8").convert(buf, sheetid=1)
    return buf.getvalue()


# ============================================================
# 2. 處理邏輯
# ============================================================
def split_names(s: str) -> list[str]:
    """把『王思閔/李泓寬』或『ABBY/BOB』拆陣列；去掉換行 / 括號註記"""
    if not s:
        return []
    s = s.replace("\n", "").replace("\r", "")
    names = [n.strip() for n in re.split(r"[/／、]", s) if n.strip()]
    # 去掉括號內附註（例：「鄒婉萱(SCS)」→「鄒婉萱」、「子恩(SPS)」→「子恩」）
    names = [re.sub(r"[（(][^）)]*[)）]", "", n).strip() for n in names]
    return [n for n in names if n]


def build_systems(copi01_data: list[dict]) -> list[dict]:
    """從 COPI01 通路別名稱抽 unique 體系"""
    systems = {}
    for d in copi01_data:
        n = (d.get("通路別名稱") or "").strip()
        if n and n not in systems:
            systems[n] = {
                "name": n,
                "copi01_name": n,
                "code": _system_code(n),
            }
    return list(systems.values())


def _system_code(name: str) -> str:
    """給體系一個短代碼（沒則 None）"""
    table = {
        "長庚體系": "CGMH",
        "署立體系": "MOH",
        "國軍體系": "AFMS",
        "榮民體系": "VGH",
        "中國體系": "CMU",
        "彰基體系": "CCH",
        "天主教體系": "CATH",
        "慈濟體系": "TZUCHI",
        "秀傳體系": "SHTM",
        "台大體系": "NTU",
        "馬偕體系": "MMH",
        "成大體系": "NCKU",
        "高醫體系": "KMU",
        "義大體系": "EDAH",
        "國泰體系": "CGH",
        "奇美體系": "CMH",
        "光田體系": "KTGH",
        "北醫體系": "TMU",
        "市聯合": "TPECH",
        "高雄市立": "KCG",
        "敏盛體系": "MSCH",
        "澄清體系": "CCH2",
        "新樓體系": "SLH",
        "李綜合體系": "LSH",
        "林新體系": "LSC",
        "童綜合體系": "TTH",
        "長安體系": "CAH",
        "北萬雙體系": "TMC",
        "天成": "TNH",
        "臺安體系": "TAH",
        "博仁": "BJH",
        "基督教": "CHR",
        "大學類": "UNIV",
        "同行": "AGENT",
        "動物醫院": "VET",
        "診所": "CLINIC",
        "宮廟": "TEMPLE",
        "無": "NONE",
        "": "OTHER",
    }
    return table.get(name, "OTHER")


def build_hospitals(
    copi01_data: list[dict],
    hospitals_csv: list[dict],
    systems_by_name: dict,
) -> tuple[list[dict], dict[str, dict]]:
    """從 COPI01 抓出 CSV 白名單內的醫院；附 CSV aliases / area"""

    # CSV 為白名單，建 code → CSV row 對照（CSV 缺 code 用名字 fallback）
    csv_by_code = {}
    csv_by_short_name = {}
    for c in hospitals_csv:
        code = (c.get("customer_code") or "").strip()
        short = (c.get("short_name") or "").strip()
        if code:
            csv_by_code[code] = c
        if short:
            csv_by_short_name[short] = c

    # Lynn 拍板：員榮 = S-YUM、星采 = C02
    csv_by_code.setdefault(
        "S-YUM", csv_by_short_name.get("員榮", {"name": "員榮", "short_name": "員榮", "area": "中", "responsible": "陳虹均"}),
    )
    csv_by_code.setdefault(
        "C02", csv_by_short_name.get("星采", {"name": "星采整形外科診所", "short_name": "星采", "area": "北", "responsible": ""}),
    )
    # 博仁綜合醫院 → Lynn 拍板：跳過

    rows = []
    fallback_used = []
    for d in copi01_data:
        code = d.get("客戶代號", "").strip()
        if code not in csv_by_code:
            continue  # 不在 CSV 白名單，跳過
        level = (d.get("型態別名稱") or "").strip()
        if level not in HOSPITAL_LEVELS:
            # 強制納入 CSV 認可但 level 不在標準集（如「同行」實為診所）
            fallback_used.append((code, level))

        csv_row = csv_by_code[code]
        aliases_str = csv_row.get("aliases", "") or ""
        aliases = [a.strip() for a in re.split(r"[、,]", aliases_str) if a.strip()]

        system_name = (d.get("通路別名稱") or "").strip()
        system_id_placeholder = systems_by_name.get(system_name, {}).get("code", "OTHER")

        rows.append(
            {
                "copi01_code": code,
                "name": d.get("客戶全名", "").strip(),
                "short_name": d.get("客戶簡稱", "").strip() or (csv_row.get("short_name") or "").strip(),
                "aliases_pg_array": _pg_array(aliases),
                "system_code": system_id_placeholder,  # import 時 lookup_id → system_id
                "system_name": system_name,
                "level": level,
                "region": (csv_row.get("area") or "").strip(),
                "region_copi01": d.get("地區別名稱", "").strip(),
                "tax_id": d.get("統一編號", "").strip(),
                "contact_name": d.get("連絡人", "").strip(),
                "phone": d.get("TEL_NO(一)", "").strip(),
                "phone2": d.get("TEL_NO(二)", "").strip(),
                "fax": d.get("FAX NO", "").strip(),
                "email": d.get("E-Mail", "").strip(),
                "registered_address": _join(d.get("郵遞區號", ""), d.get("登記地址", "")),
                "shipping_address": _join(d.get("郵遞區號", ""), d.get("送貨地址", "")),
                "invoice_address": _join(d.get("郵遞區號", ""), d.get("發票地址", "")),
                "payment_term": d.get("付款條件名稱", "").strip(),
                "payment_term_code": d.get("付款條件", "").strip(),
                "invoice_type": d.get("發票聯數", "").strip(),
                "delivery_method": d.get("單據發送方式", "").strip(),
                "payment_method": d.get("收款方式", "").strip(),
                "tax_category": d.get("課稅別", "").strip(),
                "credit_rating": d.get("信用評等", "").strip(),
                "sales_rating": d.get("銷售評等", "").strip(),
                "credit_limit": _num(d.get("信用額度", "")),
                "first_dealt_at": _date(d.get("初次交易", "")),
                "last_dealt_at": _date(d.get("最近交易", "")),
                "copi01_salesperson_id": d.get("業務人員", "").strip(),
                "copi01_salesperson_name": d.get("業務人員名稱", "").strip(),
                "note": d.get("備註", "").strip(),
                "raw_copi01_data": json.dumps(
                    {k: v for k, v in d.items() if v and v.strip()},
                    ensure_ascii=False,
                ),
                "is_active": "true",
                "_csv_responsible": (csv_row.get("responsible") or "").strip(),  # 暫存供 assignments 用
            }
        )
    if fallback_used:
        print(f"  [info] 醫院 level 非標準集 {len(fallback_used)} 家：{fallback_used[:5]}...", file=sys.stderr)
    return rows, csv_by_code


def build_products(invi02_data: list[dict]) -> list[dict]:
    rows = []
    moh_extracted = 0
    for d in invi02_data:
        if (d.get("商品分類一名稱") or "").strip() not in PRODUCT_CATEGORY_KEEP:
            continue
        desc = d.get("商品描述", "") or ""
        moh_match = MOH_PATTERN.search(desc)
        moh = moh_match.group(0) if moh_match else None
        if moh:
            moh_extracted += 1

        rows.append(
            {
                "invi02_code": d.get("品號", "").strip(),
                "name": d.get("品名", "").strip(),
                "spec": d.get("規格", "").strip(),
                "size": d.get("SIZE", "").strip(),
                "unit": d.get("單位", "").strip(),
                "category_2": d.get("商品分類二名稱", "").strip(),
                "category_3": d.get("商品分類三名稱", "").strip(),
                "category_5": d.get("商品分類五名稱", "").strip(),
                "category_7": d.get("商品分類七名稱", "").strip(),
                "product_line": d.get("產品系列", "").strip(),
                "vendor": d.get("原廠", "").strip(),
                "supplier_code": d.get("主供應商", "").strip(),
                "supplier_name": d.get("主供應商名稱", "").strip(),
                "description": desc,
                "moh_license": moh or "",
                "moh_expiry": "",  # 待手動填
                "qsd_version": "",
                "qsd_expiry": "",
                "purchaser_id": d.get("採購人員", "").strip(),
                "purchaser_name": d.get("採購人員名稱", "").strip(),
                "std_price": _num(d.get("標準售價", "")),
                "base_price": _num(d.get("業務底價", "")),  # 大多 0，等 Lynn 底價檔
                "cost_unit": _num(d.get("單位成本", "")),
                "stock_qty": _int(d.get("庫存數量", "")),
                "stock_value": _num(d.get("庫存金額", "")),
                "warehouse_code": d.get("主要庫別", "").strip(),
                "warehouse_name": d.get("庫別名稱", "").strip(),
                "barcode": d.get("條碼編號", "").strip(),
                "shelf_life_days": _int(d.get("有效天(月\\年)數", "")),
                "shelf_life_unit": d.get("有效日期依據", "").strip(),
                "raw_invi02_data": json.dumps(
                    {k: v for k, v in d.items() if v and v.strip()},
                    ensure_ascii=False,
                ),
                "is_active": "true",
            }
        )
    print(f"  [info] 產品衛署字號 regex 抽出：{moh_extracted}/{len(rows)} 筆", file=sys.stderr)
    return rows


def build_assignments(
    hospitals: list[dict],
    assignments_xlsx: list[dict],
) -> list[dict]:
    """產業務 + 業祕分區 row（從 CSV 業務全名 + xlsx 業祕暱稱）"""
    emp_by_name = {}  # 全名 → emp_id
    # 我們手動建一份「業務全名 → emp_id」（從前面 mapping_report 結論）
    # 因為員工總表的「姓名」就是全名，可以再讀員工總表來建
    # 這裡用簡化：所有出現過的全名都直接查 employee dict by 姓名
    sec_by_code = {a["copi01_code"]: a["secretaries"] for a in assignments_xlsx}

    rows = []
    for h in hospitals:
        code = h["copi01_code"]
        # 業務（CSV responsible 全名）
        for full_name in split_names(h.get("_csv_responsible", "")):
            emp_id = emp_by_name.get(full_name)
            if not emp_id:
                # 第一次看到，記下來 (這裡用 placeholder，下面回填)
                emp_by_name[full_name] = None
            rows.append(
                {
                    "copi01_code": code,
                    "emp_full_name": full_name,
                    "emp_nick": "",
                    "role": "salesperson",
                    "is_primary": "true",
                    "source": "csv",
                }
            )
        # 業祕（xlsx 最新暱稱）
        secs = sec_by_code.get(code, "")
        for nick in split_names(secs):
            emp_id = SECRETARY_NICK_TO_EMP.get(nick)
            rows.append(
                {
                    "copi01_code": code,
                    "emp_full_name": "",
                    "emp_nick": nick,
                    "role": "secretary",
                    "is_primary": "true",
                    "source": "xlsx_20260511",
                }
            )
    return rows


# ============================================================
# 3. 寫檔工具
# ============================================================
def write_csv(rows: list[dict], path: Path, exclude: set = None):
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    exclude = exclude or set()
    fieldnames = [k for k in rows[0].keys() if k not in exclude]
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_MINIMAL)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})
    print(f"  written: {path.relative_to(path.parent.parent.parent)} ({len(rows)} rows)")


def _pg_array(lst: list[str]) -> str:
    """變成 Postgres array 字串：{a,b,c}（CSV 直接吃）"""
    if not lst:
        return ""
    escaped = [n.replace('"', '""') for n in lst]
    return "{" + ",".join(f'"{n}"' for n in escaped) + "}"


def _num(s) -> str:
    s = (s or "").strip().replace(",", "")
    if not s:
        return ""
    try:
        return str(float(s))
    except ValueError:
        return ""


def _int(s) -> str:
    s = (s or "").strip().replace(",", "")
    if not s:
        return ""
    try:
        return str(int(float(s)))
    except ValueError:
        return ""


def _date(s) -> str:
    s = (s or "").strip()
    if not s:
        return ""
    # 鼎新：'2023/04/13'
    m = re.match(r"(\d{4})/(\d{1,2})/(\d{1,2})", s)
    if m:
        y, mo, d = m.groups()
        return f"{y}-{int(mo):02d}-{int(d):02d}"
    return ""


def _join(*parts) -> str:
    return " ".join(p.strip() for p in parts if p and p.strip())


# ============================================================
# 4. 主程序
# ============================================================
def main():
    p = argparse.ArgumentParser()
    p.add_argument("--employees", required=True)
    p.add_argument("--copi01", required=True)
    p.add_argument("--invi02", required=True)
    p.add_argument("--hospitals-csv", required=True)
    p.add_argument("--assignment-xlsx", required=True)
    args = p.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("[1/5] 讀員工總表...")
    employees = read_employees(Path(args.employees))
    print(f"  {len(employees)} 員工在職")
    write_csv(
        [
            {
                "emp_id": e["emp_id"],
                "name": e["name"],
                "dept": e["dept"],
                "category": e["category"],
                "position": e["position"],
            }
            for e in employees
        ],
        OUTPUT_DIR / "employees_for_review.csv",
    )

    print("[2/5] 讀 COPI01 + 醫院 CSV...")
    _, copi01 = read_copi01(Path(args.copi01))
    hospitals_csv = read_hospitals_csv(Path(args.hospitals_csv))
    print(f"  COPI01: {len(copi01)} 筆 / CSV: {len(hospitals_csv)} 筆")

    systems = build_systems(copi01)
    print(f"  體系：{len(systems)} 種")
    write_csv(systems, OUTPUT_DIR / "hospital_systems.csv")
    systems_by_name = {s["name"]: s for s in systems}

    hospitals, _ = build_hospitals(copi01, hospitals_csv, systems_by_name)
    print(f"  醫院（在 CSV 白名單）：{len(hospitals)} 家")
    write_csv(hospitals, OUTPUT_DIR / "hospitals.csv", exclude={"_csv_responsible"})

    print("[3/5] 讀 INVI02...")
    _, invi02 = read_invi02(Path(args.invi02))
    print(f"  INVI02: {len(invi02)} 筆")
    products = build_products(invi02)
    print(f"  產品（商品分類一=商品）：{len(products)} 筆")
    write_csv(products, OUTPUT_DIR / "products.csv")

    print("[4/5] 讀分區歷史 + 產 assignments...")
    assignments_xlsx = read_assignments_xlsx(Path(args.assignment_xlsx))
    print(f"  分區 xlsx：{len(assignments_xlsx)} 筆有最新分區")
    assignments = build_assignments(hospitals, assignments_xlsx)
    print(f"  業務+業祕 分區 row：{len(assignments)}")
    write_csv(assignments, OUTPUT_DIR / "hospital_assignments.csv")

    print("[5/5] 完成。CSV 在 sql/data/")
    print()
    print("接下來：")
    print("  1. Lynn 在 Supabase Studio 跑 sql/01_shared_schema.sql")
    print("  2. Lynn 跑 sql/02_shared_rls.sql")
    print("  3. Lynn 跑 sql/03_seed_hospital_systems.sql（從 hospital_systems.csv 產生）")
    print("  4. Lynn 從 Studio Table Editor → Import data → hospitals.csv")
    print("  5. 同上 products.csv")
    print("  6. 跑 sql/06_seed_assignments.sql（lookup 業務/業祕 employee_id）")


if __name__ == "__main__":
    main()
