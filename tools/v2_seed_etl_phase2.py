#!/usr/bin/env python3
"""V2 Sprint 1 Seed ETL Phase-2.

Phase-1 (tools/v2_seed_etl.py) 把 V2 zip 對得到 V1 medsec_hospitals 的 62 筆灌進去,
55 筆對不到的記在 sql/v2/etl/SKIPPED.md。

業祕 approve §A 12 筆 mapping (舊 ERP 代號 → COPI01 新代號) 後,
本腳本把這 12 筆對應的 V2 zip 規則 / 帳密 row 用 新 hospital_id 重 emit:

  03_seed_operation_rules_phase2.sql
  04_seed_credentials_phase2.sql

ON CONFLICT (hospital_id) DO NOTHING 處理:
  - rules 表有 UNIQUE(hospital_id);多個舊代號 map 到同一新代號 (例 BT09/BT10-1/BT16 → CMUM)
    只會留第一筆;phase-1 已有 CMUM 規則的話也會被 skip
  - credentials 無 UNIQUE → 全 INSERT (多筆同 hospital 不衝突)
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / 'sql' / 'v2' / 'etl'
V2_SQL_PATH = pathlib.Path('/tmp/v2_zip/medsec_v2_sprint1.sql')

# §A approved mapping (Lynn 2026-05-15)
MAPPING_A = {
    'AM09':     'VGTN',     # 同北榮合約 → 北榮
    'AP46':     'UCGN',     # 和長庚同體系 → 長庚
    'AP47':     'MSSN',     # 盛弘 → 盛弘
    'BT09':     'CMUM',     # 同中國本院 → 中國
    'BT10-1':   'CMUM',     # 同中國本院 → 中國
    'BT16':     'CMUM',     # 同中國本院 → 中國
    'CC02':     'S-NMS',    # 南門
    'CC04':     'KMMS',     # 同市民生
    'CP44':     'EDHS',     # 同義大
    'CP50':     'EDHS',     # 同義大
    'CP52':     'S-NNA',    # 南門綜合醫院
    '盛弘 AP69': 'MSSN',     # 盛弘
}


# ---------- SQL tokenizer (copy from phase-1) ----------

def find_insert_values_section(sql: str, table_name: str) -> str:
    m = re.search(
        rf'INSERT INTO {re.escape(table_name)}\s*\([^)]*\)\s*VALUES\s*',
        sql,
    )
    if not m:
        raise ValueError(f'INSERT not found for {table_name}')
    start = m.end()
    depth = 0
    in_str = False
    i = start
    while i < len(sql):
        c = sql[i]
        if in_str:
            if c == "'":
                if i + 1 < len(sql) and sql[i + 1] == "'":
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if c == "'":
            in_str = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif c == ';' and depth == 0:
            return sql[start:i]
        i += 1
    raise ValueError('no terminator')


def parse_tuple(s: str, start: int):
    assert s[start] == '('
    i = start + 1
    depth = 1
    in_str = False
    fields: list[str] = []
    current: list[str] = []
    while i < len(s):
        c = s[i]
        if in_str:
            current.append(c)
            if c == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    current.append(s[i + 1])
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if c == "'":
            current.append(c)
            in_str = True
            i += 1
            continue
        if c == '(':
            depth += 1
            current.append(c)
            i += 1
            continue
        if c == ')':
            depth -= 1
            if depth == 0:
                fields.append(''.join(current).strip())
                return fields, i + 1
            current.append(c)
            i += 1
            continue
        if c == ',' and depth == 1:
            fields.append(''.join(current).strip())
            current = []
            i += 1
            continue
        current.append(c)
        i += 1
    raise ValueError('unclosed tuple')


def parse_all_tuples(values_section: str) -> list[list[str]]:
    tuples: list[list[str]] = []
    i = 0
    n = len(values_section)
    while i < n:
        while i < n and values_section[i] in ' \t\n\r,':
            i += 1
        if i >= n:
            break
        if values_section[i] != '(':
            break
        fields, i = parse_tuple(values_section, i)
        tuples.append(fields)
    return tuples


def extract_dingxin_code(subselect: str) -> str:
    m = re.match(
        r"\(SELECT id FROM medsec_hospitals WHERE dingxin_code='([^']*)'\)\s*$",
        subselect,
    )
    if not m:
        raise ValueError(f"can't parse subselect: {subselect!r}")
    return m.group(1)


# ---------- main ----------

def main() -> None:
    sql = V2_SQL_PATH.read_text(encoding='utf-8')

    # === operation_rules ===
    rules_section = find_insert_values_section(sql, 'medsec_hospital_operation_rules')
    rules_tuples = parse_all_tuples(rules_section)
    print(f'V2 zip operation_rules: {len(rules_tuples)} 列', file=sys.stderr)

    # filter only mapped codes; rewrite hospital_id
    rules_out: list[list[str]] = []
    rules_origin: list[tuple[str, str]] = []   # (old_code, new_code)
    for tup in rules_tuples:
        if len(tup) != 14:
            sys.exit(f'expected 14 fields, got {len(tup)}: {tup}')
        old_code = extract_dingxin_code(tup[0])
        if old_code not in MAPPING_A:
            continue
        new_code = MAPPING_A[old_code]
        rules_origin.append((old_code, new_code))
        rules_out.append([
            f"'{new_code}'",   # hospital_id (rewritten)
            tup[1],            # order_mode
            tup[2],            # shipping_destination
            tup[3],            # shipping_method
            tup[4],            # packaging_notes
            tup[5],            # invoice_mode
            tup[6],            # invoice_track
            tup[7],            # dual_invoice
            tup[8],            # payment_cycle → payment_cycle_note
            tup[9],            # invoice_product_name_style → invoice_product_name
            tup[10],           # case_close_method
            # tup[11] has_consignment — DROP
            # tup[12] consignment_notes — DROP
            tup[13],           # free_text_notes → special_notes
            f"'伶華 (phase-2: {old_code}→{new_code})'",   # source_secretary 含 mapping trace
        ])

    print(f'phase-2 rules to emit: {len(rules_out)} (matched §A 舊代號)', file=sys.stderr)

    rules_cols_typed = [
        ('hospital_id',          'text'),
        ('order_mode',           'text'),
        ('shipping_destination', 'text'),
        ('shipping_method',      'text'),
        ('packaging_notes',      'text'),
        ('invoice_mode',         'text'),
        ('invoice_track',        'text'),
        ('dual_invoice',         'bool'),
        ('payment_cycle_note',   'text'),
        ('invoice_product_name', 'text'),
        ('case_close_method',    'text'),
        ('special_notes',        'text'),
        ('source_secretary',     'text'),
    ]
    write_etl_sql(
        OUT_DIR / '03_seed_operation_rules_phase2.sql',
        table='public.medsec_hospital_operation_rules',
        rows=rules_out,
        cols_typed=rules_cols_typed,
        on_conflict='ON CONFLICT (hospital_id) DO NOTHING',
        header=(
            '-- 03_seed_operation_rules_phase2.sql — V2 Sprint 1 ETL Phase-2\n'
            f'-- §A approved mapping ({len(MAPPING_A)} 舊代號 → {len(set(MAPPING_A.values()))} 新代號)\n'
            '-- ON CONFLICT DO NOTHING: 多舊→同新 / phase-1 已灌 → 留第一筆\n'
            f'-- Mapping trace:\n'
            + ''.join(f'--   {o} → {n}\n' for o, n in MAPPING_A.items())
        ),
    )

    # === credentials ===
    creds_section = find_insert_values_section(sql, 'medsec_hospital_credentials')
    creds_tuples = parse_all_tuples(creds_section)
    print(f'V2 zip credentials: {len(creds_tuples)} 列', file=sys.stderr)

    creds_out: list[list[str]] = []
    creds_origin: list[tuple[str, str]] = []
    for tup in creds_tuples:
        if len(tup) != 7:
            sys.exit(f'expected 7 fields, got {len(tup)}: {tup}')
        old_code = extract_dingxin_code(tup[0])
        if old_code not in MAPPING_A:
            continue
        new_code = MAPPING_A[old_code]
        creds_origin.append((old_code, new_code))
        notes_val = tup[6]
        # 在 notes 加 mapping trace (僅當 notes 原為 NULL)
        if notes_val == 'NULL':
            notes_val = f"'phase-2: {old_code}→{new_code}'"
        creds_out.append([
            f"'{new_code}'",
            tup[1],     # platform
            tup[2],     # url
            tup[3],     # account
            tup[4],     # password
            tup[5],     # tax_id
            notes_val,
        ])

    print(f'phase-2 credentials to emit: {len(creds_out)}', file=sys.stderr)

    creds_cols_typed = [
        ('hospital_id', 'text'),
        ('platform',    'text'),
        ('url',         'text'),
        ('account',     'text'),
        ('password',    'text'),
        ('tax_id',      'text'),
        ('notes',       'text'),
    ]
    write_etl_sql(
        OUT_DIR / '04_seed_credentials_phase2.sql',
        table='public.medsec_hospital_credentials',
        rows=creds_out,
        cols_typed=creds_cols_typed,
        on_conflict='',
        header=(
            '-- 04_seed_credentials_phase2.sql — V2 Sprint 1 ETL Phase-2\n'
            f'-- §A approved mapping ({len(MAPPING_A)} 舊代號 → {len(set(MAPPING_A.values()))} 新代號)\n'
            '-- 無 UNIQUE → 不 ON CONFLICT,所有 row 都 INSERT\n'
            '-- 重跑會插重複,Lynn 只跑一次\n'
        ),
    )

    if not rules_out and not creds_out:
        print('⚠️  WARNING: 0 row emitted! §A 的舊代號可能不存在於 V2 zip 對應 INSERT 中', file=sys.stderr)


def write_etl_sql(
    path: pathlib.Path,
    *,
    table: str,
    rows: list[list[str]],
    cols_typed: list[tuple[str, str]],
    on_conflict: str,
    header: str,
) -> None:
    if not rows:
        out = (
            f'{header}\n'
            f'-- (no rows to emit — §A 在 V2 zip 對應 INSERT 內沒找到)\n'
            f'SELECT 1 WHERE FALSE;\n'
        )
        path.write_text(out, encoding='utf-8')
        print(f'Wrote {path} (0 rows — empty)', file=sys.stderr)
        return

    col_list = ', '.join(c for c, _ in cols_typed)
    col_alias_list = col_list

    body_lines = []
    n = len(rows)
    for idx, row in enumerate(rows):
        suffix = ',' if idx < n - 1 else ''
        if idx == 0:
            cast_vals = [f'{v}::{t}' for v, (_, t) in zip(row, cols_typed)]
            body_lines.append(f"  ({', '.join(cast_vals)}){suffix}")
        else:
            body_lines.append(f"  ({', '.join(row)}){suffix}")
    body = '\n'.join(body_lines)

    out = (
        f'{header}\n'
        f'INSERT INTO {table}\n'
        f'  ({col_list})\n'
        f'SELECT v.* FROM (\n'
        f'VALUES\n'
        f'{body}\n'
        f') AS v ({col_alias_list})\n'
        f'WHERE EXISTS (\n'
        f"  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id\n"
        f')\n'
        f'{on_conflict};\n'
    )
    path.write_text(out, encoding='utf-8')
    print(f'Wrote {path} ({n} rows)', file=sys.stderr)


if __name__ == '__main__':
    main()
