#!/usr/bin/env python3
"""
AE Hub · V3 — 從 5 份原始檔產出對齊「既有 medsec_* schema」的 CSV + SQL

對應的既有表：
  - medsec_hospitals (24 欄)
  - medsec_products  (27 欄)
  - medsec_secretary_assignments (主祕 + 副祕，2 欄)
  - medsec_salesperson_assignments (新建，normalized 多人共管)
  - hospital_systems (新建)

執行：
  python3 tools/generate_import_data.py \
    --employees       <員工總表.xlsx> \
    --copi01          <COPI01.XLSX> \
    --invi02          <INVI02.XLSX> \
    --hospitals-csv   <hospitals_template.csv> \
    --assignment-xlsx <分區歷史.xlsx>

輸出（sql/data/）：
  - employees_for_review.csv
  - hospital_systems.csv          (33 體系)
  - medsec_hospitals.csv          (184 家對齊既有欄位)
  - medsec_products.csv           (5239 對齊既有欄位)
  - medsec_secretary_assignments.csv  (一家 1 row 主+副)
  - medsec_salesperson_assignments.csv (一家多 row 共管)
"""

import argparse
import csv
import io
import re
import sys
from pathlib import Path

from xlsx2csv import Xlsx2csv

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "sql" / "data"

# ============================================================
# Mapping tables (Lynn 拍板)
# ============================================================
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

HOSPITAL_LEVELS = {"醫學中心", "區域醫院", "地區醫院", "大學", "動物醫院", "診所"}
PRODUCT_CATEGORY_KEEP = {"商品"}
MOH_PATTERN = re.compile(r"衛署[醫器材輸製造販售檢校驗]+字第\s*\d+\s*號")


# ============================================================
# 讀取
# ============================================================
def _xlsx_to_csv_str(path: Path, sheet_idx: int = 1) -> str:
    buf = io.StringIO()
    Xlsx2csv(str(path), outputencoding="utf-8").convert(buf, sheetid=sheet_idx)
    return buf.getvalue()


def read_copi01(path: Path) -> list[dict]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[2]
    return [dict(zip(header, r)) for r in rows[3:] if r and r[0].strip()]


def read_invi02(path: Path) -> list[dict]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[2]
    return [dict(zip(header, r)) for r in rows[3:] if r and r[0].strip()]


def read_employees(path: Path) -> list[dict]:
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    out = []
    for r in rows[8:]:
        if len(r) < 12 or not r[3]:
            continue
        out.append({
            "emp_id":   str(r[3]).strip(),
            "name":     (r[4] or "").strip(),
            "dept":     (r[8] or "").strip(),
            "category": (r[9] or "").strip(),
            "position": (r[10] or "").strip(),
        })
    return out


def read_hospitals_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig") as f:
        return [r for r in csv.DictReader(f) if (r.get("name") or "").strip()]


def read_assignments_xlsx(path: Path) -> dict[str, str]:
    """讀分區歷史 → code → 最新分區暱稱字串"""
    rows = list(csv.reader(io.StringIO(_xlsx_to_csv_str(path))))
    header = rows[0]
    idx_code = header.index("新客戶編號")
    idx_latest = header.index("20260511分區")
    out = {}
    for r in rows[1:]:
        code = (r[idx_code] or "").strip() if r[idx_code] else ""
        latest = (r[idx_latest] or "").strip() if len(r) > idx_latest and r[idx_latest] else ""
        if code and latest:
            out[code] = latest
    return out


# ============================================================
# 處理
# ============================================================
def split_names(s: str) -> list[str]:
    if not s:
        return []
    s = s.replace("\n", "").replace("\r", "")
    names = [n.strip() for n in re.split(r"[/／、]", s) if n.strip()]
    names = [re.sub(r"[（(][^）)]*[)）]", "", n).strip() for n in names]
    return [n for n in names if n]


def system_code(name: str) -> str:
    table = {
        "長庚體系": "CGMH", "署立體系": "MOH", "國軍體系": "AFMS", "榮民體系": "VGH",
        "中國體系": "CMU", "彰基體系": "CCH", "天主教體系": "CATH", "慈濟體系": "TZUCHI",
        "秀傳體系": "SHTM", "台大體系": "NTU", "馬偕體系": "MMH", "成大體系": "NCKU",
        "高醫體系": "KMU", "義大體系": "EDAH", "國泰體系": "CGH", "奇美體系": "CMH",
        "光田體系": "KTGH", "北醫體系": "TMU", "市聯合": "TPECH", "高雄市立": "KCG",
        "敏盛體系": "MSCH", "澄清體系": "CCH2", "新樓體系": "SLH", "李綜合體系": "LSH",
        "林新體系": "LSC", "童綜合體系": "TTH", "長安體系": "CAH", "北萬雙體系": "TMC",
        "天成": "TNH", "臺安體系": "TAH", "博仁": "BJH", "基督教": "CHR",
        "大學類": "UNIV", "同行": "AGENT", "動物醫院": "VET", "診所": "CLINIC",
        "宮廟": "TEMPLE", "無": "NONE", "": "OTHER",
    }
    return table.get(name, "OTHER")


def build_systems(copi01: list[dict]) -> list[dict]:
    seen = {}
    for d in copi01:
        n = (d.get("通路別名稱") or "").strip()
        if n and n not in seen:
            seen[n] = {"name": n, "copi01_name": n, "code": system_code(n)}
    return list(seen.values())


def build_medsec_hospitals(
    copi01: list[dict],
    hospitals_csv: list[dict],
    sec_by_code: dict[str, str],
) -> list[dict]:
    """從 COPI01 + CSV 產出對齊 medsec_hospitals 欄位的 row"""
    # CSV 為白名單
    csv_by_code: dict = {}
    csv_by_short: dict = {}
    for c in hospitals_csv:
        code = (c.get("customer_code") or "").strip()
        short = (c.get("short_name") or "").strip()
        if code:
            csv_by_code[code] = c
        if short:
            csv_by_short[short] = c
    # Lynn 拍板補
    csv_by_code.setdefault("S-YUM", csv_by_short.get("員榮", {
        "name": "員榮", "short_name": "員榮", "area": "中", "responsible": "陳虹均"}))
    csv_by_code.setdefault("C02", csv_by_short.get("星采", {
        "name": "星采", "short_name": "星采", "area": "北", "responsible": ""}))

    out = []
    for d in copi01:
        code = (d.get("客戶代號") or "").strip()
        if code not in csv_by_code:
            continue
        csv_row = csv_by_code[code]
        system_name = (d.get("通路別名稱") or "").strip()
        latest_secs = sec_by_code.get(code, "")
        sec_list = [SECRETARY_NICK_TO_EMP.get(n) for n in split_names(latest_secs)]
        sec_list = [s for s in sec_list if s]

        # 對應 medsec_hospitals 24 欄
        out.append({
            # id 自動產生
            "name_full":          d.get("客戶全名", "").strip(),
            "name_short":         d.get("客戶簡稱", "").strip() or (csv_row.get("short_name") or "").strip(),
            "tax_id":             d.get("統一編號", "").strip(),
            "parent_code":        code,                                              # COPI01 客戶代號 = parent_code
            "system_prefix":      system_code(system_name),                          # 對應 hospital_systems.code
            "is_standalone":      "true",
            "is_distributor":     "false",
            "customer_type":      d.get("型態別名稱", "").strip(),                   # 醫學中心/區域/地區/...
            "region_code":        _region_code((csv_row.get("area") or "").strip()),
            "region_name":        (csv_row.get("area") or "").strip(),
            "invoice_company":    "",                                                 # ⚠️ 不確定意義，留空
            "is_priority":        "false",
            "sales_person":       (csv_row.get("responsible") or "").strip(),        # 全名字串（顯示用）
            "sales_person_code":  d.get("業務人員", "").strip(),                     # 鼎新登記業務的編號
            "business_department":d.get("部門名稱", "").strip(),
            "primary_secretary":  _emp_name(sec_list[0]) if len(sec_list) >= 1 else "",
            "co_secretary":       _emp_name(sec_list[1]) if len(sec_list) >= 2 else "",
            "payment_terms":      d.get("付款條件名稱", "").strip(),
            "payment_cycle_day":  _int(d.get("結帳日期  每月", "")),
            "shipping_address":   _join(d.get("郵遞區號", ""), d.get("送貨地址", "")),
            "notes":              d.get("備註", "").strip(),
            # 隱藏欄位（不寫 CSV，下面腳本 join 用）
            "_csv_responsible":   (csv_row.get("responsible") or "").strip(),
            "_latest_secs":       latest_secs,
        })
    return out


def build_medsec_products(invi02: list[dict]) -> list[dict]:
    out = []
    moh_count = 0
    for d in invi02:
        if (d.get("商品分類一名稱") or "").strip() not in PRODUCT_CATEGORY_KEEP:
            continue
        desc = d.get("商品描述", "") or ""
        moh = MOH_PATTERN.search(desc)
        if moh:
            moh_count += 1
        out.append({
            # 對應 medsec_products 27 欄
            "name":                 d.get("品名", "").strip(),
            "specification":        d.get("規格", "").strip(),
            "manufacturer_code":    d.get("原廠", "").strip(),
            "manufacturer_name":    d.get("主供應商名稱", "").strip(),
            "product_line":         d.get("產品系列", "").strip(),
            "product_series":       d.get("商品分類二名稱", "").strip(),
            "dms_category":         d.get("DMS-美敦力類別", "").strip(),
            "dms_subcategory":      d.get("DMS-美敦力細項", "").strip(),
            "classification_level": d.get("商品分類五名稱", "").strip(),
            "is_sterile":           "false",                                # ⚠️ INVI02 沒明確欄位
            "storage_temp_range":   d.get("庫別名稱", "").strip(),          # 例「主銷售倉(常溫倉)」
            "storage_humidity":     "",                                     # ⚠️
            "packaging_standard":   "",                                     # ⚠️
            "service_procedure":    "",                                     # ⚠️
            "uom":                  d.get("單位", "").strip(),
            "qty_per_uom":          _int(d.get("包裝數量", "")),
            "catalog_number":       d.get("品號", "").strip(),              # INVI02 品號（unique）
            "status":               "active",
            "replaced_by_product":  "",
            "list_price":           _num(d.get("標準售價", "")),
            "cost_price":           _num(d.get("單位成本", "")),
            "business_floor_price": "",                                     # 等 Lynn 底價檔
            "has_nhi_code":         "true" if (d.get("健保碼") or "").strip() else "false",
            "notes":                f"[衛署字號] {moh.group(0)}" if moh else "",
        })
    print(f"  [info] 產品衛署字號 regex 抽出：{moh_count}/{len(out)} 筆", file=sys.stderr)
    return out


def build_secretary_assignments(hospitals: list[dict]) -> list[dict]:
    """產 medsec_secretary_assignments：每家 1 row（primary + co_secretary 二欄）"""
    out = []
    for h in hospitals:
        secs = split_names(h.get("_latest_secs", ""))
        emp_ids = [SECRETARY_NICK_TO_EMP.get(n) for n in secs]
        emp_ids = [e for e in emp_ids if e]
        if not emp_ids:
            continue
        out.append({
            "parent_code":           h["parent_code"],
            "primary_secretary_emp": emp_ids[0],
            "co_secretary_emp":      emp_ids[1] if len(emp_ids) >= 2 else "",
        })
    return out


def build_salesperson_assignments(hospitals: list[dict]) -> list[dict]:
    """產 medsec_salesperson_assignments：normalized，每醫院 ↔ 每業務 1 row"""
    fullname_to_emp = {}
    # 從員工總表已建好（在 main() 內注入）
    out = []
    for h in hospitals:
        full_names = split_names(h.get("_csv_responsible", ""))
        for i, name in enumerate(full_names):
            out.append({
                "parent_code":   h["parent_code"],
                "emp_full_name": name,
                "display_order": i,
                "is_primary":    "true" if i == 0 else "false",
                "source":        "csv",
            })
    return out


# ============================================================
# 工具
# ============================================================
_EMP_NAME_CACHE: dict[str, str] = {}


def _emp_name(emp_id: str) -> str:
    """用員工總表 cache 找全名（給 medsec_hospitals.primary_secretary 用，既有結構是 text）"""
    return _EMP_NAME_CACHE.get(emp_id, "")


def _region_code(area: str) -> str:
    return {"北": "N", "中": "M", "南": "S", "花東": "E", "宜蘭": "I", "離島": "X"}.get(area, "")


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


def _join(*parts) -> str:
    return " ".join(p.strip() for p in parts if p and p.strip())


def write_csv(rows: list[dict], path: Path, exclude: set | None = None):
    exclude = exclude or set()
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = [k for k in rows[0].keys() if k not in exclude and not k.startswith("_")]
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_MINIMAL)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})
    print(f"  written: {path.relative_to(path.parent.parent.parent)} ({len(rows)} rows)")


# ============================================================
# 主程序
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
    for e in employees:
        _EMP_NAME_CACHE[e["emp_id"]] = e["name"]
    print(f"  {len(employees)} 員工")
    write_csv(employees, OUTPUT_DIR / "employees_for_review.csv")

    print("[2/5] 讀 COPI01 + 醫院 CSV + 分區 xlsx...")
    copi01 = read_copi01(Path(args.copi01))
    hospitals_csv = read_hospitals_csv(Path(args.hospitals_csv))
    sec_by_code = read_assignments_xlsx(Path(args.assignment_xlsx))
    print(f"  COPI01: {len(copi01)} / CSV: {len(hospitals_csv)} / 分區: {len(sec_by_code)}")

    systems = build_systems(copi01)
    print(f"  體系：{len(systems)}")
    write_csv(systems, OUTPUT_DIR / "hospital_systems.csv")

    hospitals = build_medsec_hospitals(copi01, hospitals_csv, sec_by_code)
    print(f"  醫院（對齊 medsec_hospitals 24 欄）：{len(hospitals)}")
    write_csv(hospitals, OUTPUT_DIR / "medsec_hospitals.csv")

    print("[3/5] 讀 INVI02...")
    invi02 = read_invi02(Path(args.invi02))
    products = build_medsec_products(invi02)
    print(f"  產品（對齊 medsec_products 27 欄）：{len(products)}")
    write_csv(products, OUTPUT_DIR / "medsec_products.csv")

    print("[4/5] 產業祕 + 業務分區...")
    sec_assignments = build_secretary_assignments(hospitals)
    print(f"  業祕分區（一家 1 row 主+副）：{len(sec_assignments)}")
    write_csv(sec_assignments, OUTPUT_DIR / "medsec_secretary_assignments.csv")

    sales_assignments = build_salesperson_assignments(hospitals)
    print(f"  業務分區（normalized 共管）：{len(sales_assignments)}")
    write_csv(sales_assignments, OUTPUT_DIR / "medsec_salesperson_assignments.csv")

    print("[5/5] 完成。CSV 在 sql/data/")


if __name__ == "__main__":
    main()
