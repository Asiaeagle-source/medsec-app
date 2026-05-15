#!/usr/bin/env python3
"""COPI10 院內碼對照 ETL.

鼎新 COPI10「客戶品號資料建立作業」匯出 8878 列 → medsec_hospital_product_codes。

COPI10 欄位 (12):
  0 客戶代號  1 客戶簡稱  2 品號  3 品名  4 規格  5 客戶品號(院內碼)
  6 客戶品名  7 客戶規格  8 客戶商品描述  9 保固佔售價比率
  10 保固期數(月數)  11 生效日

→ V1 medsec_hospital_product_codes:
  hospital_id = 客戶代號 (對齊 V1 medsec_hospitals.id,COPI10 185 家全對得到)
  product_code/name/spec = 我方品號/品名/規格
  hospital_item_code/name/spec/desc = 客戶品號/品名/規格/商品描述
  warranty_ratio/months, effective_date

8878 列太大 (Lynn HANDOVER §8.8: SQL Editor 1.4MB 上限) → chunk 每 2000 列一檔。
INSERT...SELECT FROM (VALUES) WHERE EXISTS + ON CONFLICT DO NOTHING (idempotent)。

輸入:  /root/.claude/uploads/.../5c89d751-COPI10_1.XLSX (Lynn 本機 zip 解出)
輸出:  sql/v2/etl/05_seed_hospital_product_codes_partN.sql
"""
from __future__ import annotations

import pathlib
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

XLSX = pathlib.Path('/root/.claude/uploads/b4c97742-8ebe-4f83-81c6-8764ec58dff1/5c89d751-COPI10_1.XLSX')
OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / 'sql' / 'v2' / 'etl'
NS = {'x': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
CHUNK = 2000


def sql_str(v):
    """Format a python value as a SQL literal (text)."""
    if v is None or v == '':
        return 'NULL'
    s = str(v).replace("'", "''")
    return f"'{s}'"


def sql_int(v):
    if v is None or v == '':
        return 'NULL'
    try:
        return str(int(float(v)))
    except (ValueError, TypeError):
        return 'NULL'


def sql_date(v):
    """COPI10 生效日格式 '2024/09/19' → DATE。"""
    if not v:
        return 'NULL'
    m = re.match(r'(\d{4})[/-](\d{1,2})[/-](\d{1,2})', str(v))
    if not m:
        return 'NULL'
    y, mo, d = m.groups()
    return f"'{y}-{int(mo):02d}-{int(d):02d}'::date"


def main() -> None:
    with zipfile.ZipFile(XLSX) as z:
        with z.open('xl/sharedStrings.xml') as f:
            ss = [t.text or '' for t in ET.parse(f).getroot().findall('.//x:t', NS)]
        sheets = sorted(n for n in z.namelist()
                        if n.startswith('xl/worksheets/sheet') and n.endswith('.xml'))
        with z.open(sheets[0]) as f:
            rows = ET.parse(f).getroot().findall('.//x:sheetData/x:row', NS)

    def cv(c):
        t = c.get('t', 'n')
        v = c.find('x:v', NS)
        if v is None or v.text is None:
            return None
        return ss[int(v.text)] if t == 's' else v.text

    # row 0 = 標題, row 1 = header, data 從 row 2
    data = []
    for r in rows[2:]:
        vals = [cv(c) for c in r.findall('x:c', NS)]
        while len(vals) < 12:
            vals.append(None)
        if vals[0] and vals[5]:   # 需有客戶代號 + 客戶品號(院內碼)
            data.append(vals)

    print(f'COPI10 data rows (有代號+院內碼): {len(data)}', file=sys.stderr)

    cols = (
        'hospital_id, product_code, product_name, product_spec, '
        'hospital_item_code, hospital_item_name, hospital_item_spec, '
        'hospital_item_desc, warranty_ratio, warranty_months, effective_date'
    )
    col_types = (
        'hospital_id text, product_code text, product_name text, product_spec text, '
        'hospital_item_code text, hospital_item_name text, hospital_item_spec text, '
        'hospital_item_desc text, warranty_ratio text, warranty_months int, '
        'effective_date date'
    )

    n_chunks = (len(data) + CHUNK - 1) // CHUNK
    for ci in range(n_chunks):
        chunk = data[ci * CHUNK:(ci + 1) * CHUNK]
        part = ci + 1
        lines = []
        for i, r in enumerate(chunk):
            vals = [
                sql_str(r[0]),               # hospital_id (客戶代號)
                sql_str(r[2]),               # product_code (品號)
                sql_str(r[3]),               # product_name (品名)
                sql_str(r[4]),               # product_spec (規格)
                sql_str(r[5]),               # hospital_item_code (客戶品號=院內碼)
                sql_str(r[6]),               # hospital_item_name (客戶品名)
                sql_str(r[7]),               # hospital_item_spec (客戶規格)
                sql_str(r[8]),               # hospital_item_desc (客戶商品描述)
                sql_str(r[9]),               # warranty_ratio (保固佔售價比率)
                sql_int(r[10]),              # warranty_months (保固期數)
                sql_date(r[11]),             # effective_date (生效日)
            ]
            suffix = ',' if i < len(chunk) - 1 else ''
            if i == 0:
                # 首列 cast 讓 PG 推型別
                typed = [
                    f'{vals[0]}::text', f'{vals[1]}::text', f'{vals[2]}::text',
                    f'{vals[3]}::text', f'{vals[4]}::text', f'{vals[5]}::text',
                    f'{vals[6]}::text', f'{vals[7]}::text', f'{vals[8]}::text',
                    f'{vals[9]}::int', vals[10] if vals[10] != 'NULL' else 'NULL::date',
                ]
                # effective_date 首列若 NULL 需顯式 cast
                if vals[10] == 'NULL':
                    typed[10] = 'NULL::date'
                else:
                    typed[10] = vals[10]
                lines.append(f"  ({', '.join(typed)}){suffix}")
            else:
                lines.append(f"  ({', '.join(vals)}){suffix}")
        body = '\n'.join(lines)
        # PG VALUES 的 AS alias 不接 type — 只列欄名,型別靠首列 ::cast 推
        out = (
            f'-- 05_seed_hospital_product_codes_part{part}.sql '
            f'(part {part}/{n_chunks}, {len(chunk)} 列) — COPI10 ETL\n'
            f'-- self-skip dingxin_code 不在 V1 185 的列;ON CONFLICT 可重跑\n\n'
            f'INSERT INTO public.medsec_hospital_product_codes\n'
            f'  ({cols})\n'
            f'SELECT v.* FROM (\nVALUES\n{body}\n) AS v ({cols})\n'
            f'WHERE EXISTS (\n'
            f'  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id\n'
            f')\n'
            f'ON CONFLICT (hospital_id, product_code, hospital_item_code) DO NOTHING;\n'
        )
        path = OUT_DIR / f'05_seed_hospital_product_codes_part{part}.sql'
        path.write_text(out, encoding='utf-8')
        print(f'Wrote {path} ({len(chunk)} rows)', file=sys.stderr)

    print(f'Done: {n_chunks} chunks, {len(data)} rows total', file=sys.stderr)


if __name__ == '__main__':
    main()
