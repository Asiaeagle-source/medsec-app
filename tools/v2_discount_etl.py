#!/usr/bin/env python3
"""V2 part3 折讓總表 ETL → V1 medsec_discount_rules (17 欄).

V2 part3 7 欄: hospital_id(子查詢 dingxin_code), product_code, discount_type,
  unit_price, discount_amount, final_price, notes  (406 列)

V1 medsec_discount_rules 17 欄 (Lynn 2026-05-15 dump):
  id uuid PK, hospital_id text, parent_code, product_code, product_line,
  calc_method text NOT NULL, fixed_amount, percentage_rate, donation_amount,
  description, applicable_period, source, is_active bool, effective_date,
  expiry_date, created_at, updated_at

Mapping (只用 V1 既有 calc_method 觀察值 donation/fixed_amount,避免踩 CHECK):
  discount_slip   → calc_method=fixed_amount, fixed_amount=discount_amount
  donation        → calc_method=donation,     donation_amount=discount_amount
  donation_check  → calc_method=donation,     donation_amount=discount_amount (desc 標 _check)
  unit_price/final_price/原type/V2 notes → 全塞 description
  source = 'V2_part3_折讓總表'

不 TRUNCATE (V2 原本要清,改保留 V1 既有 3 筆)。
無自然 unique key → 不 ON CONFLICT;要重跑先 DELETE WHERE source='V2_part3_折讓總表'。
self-skip dingxin_code 不在 V1 185。

輸入: /tmp/v2_zip/medsec_v2_sprint1_part3.sql
輸出: sql/v2/etl/06_seed_discount_rules.sql (406 列單檔)
"""
from __future__ import annotations
import pathlib
import re
import sys

SRC = pathlib.Path('/tmp/v2_zip/medsec_v2_sprint1_part3.sql')
OUT = pathlib.Path(__file__).resolve().parent.parent / 'sql' / 'v2' / 'etl' / '06_seed_discount_rules.sql'

ROW_RE = re.compile(
    r"\(\(SELECT id FROM medsec_hospitals WHERE dingxin_code='([^']*)'\),\s*"
    r"'((?:[^']|'')*)',\s*"          # product_code
    r"'((?:[^']|'')*)',\s*"          # discount_type
    r"([0-9.]+|NULL),\s*"            # unit_price
    r"([0-9.]+|NULL),\s*"            # discount_amount
    r"([0-9.]+|NULL),\s*"            # final_price
    r"'((?:[^']|'')*)'\)"            # notes
)


def num(v):
    if v is None or v == 'NULL' or v == '':
        return 'NULL'
    try:
        f = float(v)
        return str(int(f)) if f == int(f) else str(f)
    except ValueError:
        return 'NULL'


def q(s):
    if s is None or s == '':
        return 'NULL'
    return "'" + str(s).replace("'", "''") + "'"


def main() -> None:
    sql = SRC.read_text(encoding='utf-8')
    # 只取 B 段 (折讓 INSERT)
    seg = sql[sql.index('INSERT INTO medsec_discount_rules'):]
    rows = ROW_RE.findall(seg)
    print(f'parsed {len(rows)} discount rows', file=sys.stderr)
    if len(rows) != 406:
        print(f'WARNING: expected 406, got {len(rows)}', file=sys.stderr)

    out_rows = []
    for code, prod, dtype, unit, disc, final, notes in rows:
        if dtype == 'discount_slip':
            calc = 'fixed_amount'
            fixed_amt = num(disc)
            donation_amt = 'NULL'
        else:  # donation / donation_check
            calc = 'donation'
            fixed_amt = 'NULL'
            donation_amt = num(disc)
        desc_parts = []
        if dtype == 'donation_check':
            desc_parts.append('捐贈支票(donation_check)')
        desc_parts.append(f'原單價={num(unit)}')
        desc_parts.append(f'折讓={num(disc)}')
        desc_parts.append(f'成交={num(final)}')
        if notes:
            desc_parts.append(notes.replace("''", "'"))
        description = ' | '.join(desc_parts)
        out_rows.append((
            q(code), q(prod), q(calc), fixed_amt, donation_amt, q(description),
        ))

    cols = 'hospital_id, product_code, calc_method, fixed_amount, donation_amount, description, source, is_active'
    lines = []
    n = len(out_rows)
    for i, (hid, prod, calc, fx, dn, desc) in enumerate(out_rows):
        suffix = ',' if i < n - 1 else ''
        if i == 0:
            lines.append(
                f"  ({hid}::text, {prod}::text, {calc}::text, {fx}::numeric, "
                f"{dn}::numeric, {desc}::text, 'V2_part3_折讓總表'::text, true::boolean){suffix}"
            )
        else:
            lines.append(
                f"  ({hid}, {prod}, {calc}, {fx}, {dn}, {desc}, "
                f"'V2_part3_折讓總表', true){suffix}"
            )
    body = '\n'.join(lines)
    out = (
        '-- 06_seed_discount_rules.sql — V2 part3 折讓總表 ETL (406 列)\n'
        '-- 不 TRUNCATE (保留 V1 既有 3 筆)。重跑前先:\n'
        "--   DELETE FROM medsec_discount_rules WHERE source='V2_part3_折讓總表';\n"
        '-- self-skip dingxin_code 不在 V1 185 的列\n\n'
        'INSERT INTO public.medsec_discount_rules\n'
        f'  ({cols})\n'
        'SELECT v.* FROM (\nVALUES\n'
        f'{body}\n'
        f') AS v ({cols})\n'
        'WHERE EXISTS (\n'
        '  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id\n'
        ');\n'
    )
    OUT.write_text(out, encoding='utf-8')
    print(f'Wrote {OUT} ({n} rows)', file=sys.stderr)


if __name__ == '__main__':
    main()
