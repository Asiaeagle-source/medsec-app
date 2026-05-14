#!/usr/bin/env python3
"""V2 Sprint 1 seed ETL.

把 V2 zip (medsec_v2_sprint1.sql) 裡的兩段 INSERT 轉成 V1 schema 對齊版：

  medsec_hospital_operation_rules (115 列)
    - (SELECT id FROM medsec_hospitals WHERE dingxin_code='X')  →  'X'
    - drop 兩欄  has_consignment / consignment_notes  (V1 不 ADD,跟 consignment_inventory 重複)
    - rename
        payment_cycle               →  payment_cycle_note
        invoice_product_name_style  →  invoice_product_name
        free_text_notes             →  special_notes
    - 補欄  source_secretary='伶華'  (V2 zip 註解寫「來自伶華 CRM 抽出」)

  medsec_hospital_credentials (18 列)
    - 同上 dingxin_code 替換
    - 欄位直接對齊 V1 (03 schema 已配對好)
    - needs_review 走 schema default = true

雙邊都用 INSERT...SELECT FROM (VALUES) WHERE EXISTS 形式 self-skip;
operation_rules 加 ON CONFLICT (hospital_id) DO NOTHING (有 UNIQUE 限制) 確保可重跑;
credentials 無 UNIQUE,只能跑一次。

輸入:  /tmp/v2_zip/medsec_v2_sprint1.sql
輸出:  sql/v2/etl/01_seed_operation_rules.sql
       sql/v2/etl/02_seed_credentials.sql
       sql/v2/etl/99_verify_skipped.sql  (跑出哪些 dingxin_code 對不到 V1 185 家)
"""
from __future__ import annotations

import pathlib
import re
import sys

V2_SQL_PATH = pathlib.Path('/tmp/v2_zip/medsec_v2_sprint1.sql')
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / 'sql' / 'v2' / 'etl'
OUT_DIR.mkdir(parents=True, exist_ok=True)


# ---------- SQL tokenizer ----------

def find_insert_values_section(sql: str, table_name: str) -> str:
    """Return text between VALUES and the terminating ; for the named INSERT."""
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
    """Parse one (...) tuple. Returns (fields, end_idx-after-closing-paren)."""
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

    # --- operation_rules ---
    rules_section = find_insert_values_section(sql, 'medsec_hospital_operation_rules')
    rules_tuples = parse_all_tuples(rules_section)
    print(f'Parsed {len(rules_tuples)} operation_rules', file=sys.stderr)
    if len(rules_tuples) != 115:
        sys.exit(f'expected 115 rules, got {len(rules_tuples)}')

    # V2 columns (positions 0-13):
    #   0 hospital_id  1 order_mode  2 shipping_destination  3 shipping_method
    #   4 packaging_notes  5 invoice_mode  6 invoice_track  7 dual_invoice
    #   8 payment_cycle  9 invoice_product_name_style  10 case_close_method
    #   11 has_consignment  12 consignment_notes  13 free_text_notes
    rules_rows: list[list[str]] = []
    rules_codes: list[str] = []
    for tup in rules_tuples:
        if len(tup) != 14:
            sys.exit(f'expected 14 fields, got {len(tup)}: {tup}')
        code = extract_dingxin_code(tup[0])
        rules_codes.append(code)
        rules_rows.append([
            f"'{code}'",   # hospital_id
            tup[1],        # order_mode
            tup[2],        # shipping_destination
            tup[3],        # shipping_method
            tup[4],        # packaging_notes
            tup[5],        # invoice_mode
            tup[6],        # invoice_track
            tup[7],        # dual_invoice
            tup[8],        # payment_cycle  →  payment_cycle_note
            tup[9],        # invoice_product_name_style  →  invoice_product_name
            tup[10],       # case_close_method
            # tup[11] has_consignment  — DROP
            # tup[12] consignment_notes — DROP
            tup[13],       # free_text_notes  →  special_notes
            "'伶華'",       # source_secretary (provenance)
        ])

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
        OUT_DIR / '01_seed_operation_rules.sql',
        table='public.medsec_hospital_operation_rules',
        rows=rules_rows,
        cols_typed=rules_cols_typed,
        on_conflict='ON CONFLICT (hospital_id) DO NOTHING',
        header=(
            '-- 01_seed_operation_rules.sql — V2 Sprint 1 ETL\n'
            '-- 115 列(來自伶華 CRM,V2 zip 註解寫 124 是過時)\n'
            '-- self-skip dingxin_code 不在 V1 185 家的列;ON CONFLICT 可重跑\n'
            '-- 跑完看哪些被 skip 請接著跑 99_verify_skipped.sql\n'
        ),
    )

    # --- credentials ---
    creds_section = find_insert_values_section(sql, 'medsec_hospital_credentials')
    creds_tuples = parse_all_tuples(creds_section)
    print(f'Parsed {len(creds_tuples)} credentials', file=sys.stderr)
    if len(creds_tuples) != 18:
        sys.exit(f'expected 18 credentials, got {len(creds_tuples)}')

    creds_rows: list[list[str]] = []
    creds_codes: list[str] = []
    for tup in creds_tuples:
        if len(tup) != 7:
            sys.exit(f'expected 7 fields, got {len(tup)}: {tup}')
        code = extract_dingxin_code(tup[0])
        creds_codes.append(code)
        creds_rows.append([
            f"'{code}'",  # hospital_id
            tup[1],       # platform
            tup[2],       # url
            tup[3],       # account
            tup[4],       # password
            tup[5],       # tax_id
            tup[6],       # notes
        ])

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
        OUT_DIR / '02_seed_credentials.sql',
        table='public.medsec_hospital_credentials',
        rows=creds_rows,
        cols_typed=creds_cols_typed,
        on_conflict='',   # no UNIQUE -> can't ON CONFLICT
        header=(
            '-- 02_seed_credentials.sql — V2 Sprint 1 ETL\n'
            '-- 18 列(伶華 CRM 抽出帳密,V2.0 明文 / V2.1 加密)\n'
            '-- self-skip dingxin_code 不在 V1 185 家的列\n'
            '-- ⚠️ 沒 ON CONFLICT — 重跑會插重複!Lynn 只跑一次\n'
            '-- needs_review 走 03 schema default = true,業祕審完手動改 false\n'
        ),
    )

    # --- verify_skipped query ---
    all_codes = sorted(set(rules_codes + creds_codes))
    verify_lines = [
        '-- 99_verify_skipped.sql — 列出 V2 ETL 想 insert 但 dingxin_code 對不到 V1 185 家的醫院',
        '-- 跑完 01 + 02 之後跑這支,把回的 dingxin_code 列表貼給 Claude 補 SKIPPED.md',
        '',
        'WITH wanted (dingxin_code) AS (VALUES',
    ]
    for i, code in enumerate(all_codes):
        suffix = ',' if i < len(all_codes) - 1 else ''
        verify_lines.append(f"  ('{code}'){suffix}")
    verify_lines += [
        ')',
        'SELECT w.dingxin_code',
        'FROM wanted w',
        'LEFT JOIN public.medsec_hospitals h ON h.id = w.dingxin_code',
        'WHERE h.id IS NULL',
        'ORDER BY w.dingxin_code;',
    ]
    (OUT_DIR / '99_verify_skipped.sql').write_text(
        '\n'.join(verify_lines) + '\n',
        encoding='utf-8',
    )
    print(f'Wrote {OUT_DIR / "99_verify_skipped.sql"}', file=sys.stderr)


def write_etl_sql(
    path: pathlib.Path,
    *,
    table: str,
    rows: list[list[str]],
    cols_typed: list[tuple[str, str]],
    on_conflict: str,
    header: str,
) -> None:
    col_list = ', '.join(c for c, _ in cols_typed)
    col_typed_list = ', '.join(f'{c} {t}' for c, t in cols_typed)

    body_lines = []
    n = len(rows)
    for idx, row in enumerate(rows):
        suffix = ',' if idx < n - 1 else ''
        body_lines.append(f"  ({', '.join(row)}){suffix}")
    body = '\n'.join(body_lines)

    out = (
        f'{header}\n'
        f'INSERT INTO {table}\n'
        f'  ({col_list})\n'
        f'SELECT v.* FROM (\n'
        f'VALUES\n'
        f'{body}\n'
        f') AS v ({col_typed_list})\n'
        f'WHERE EXISTS (\n'
        f"  SELECT 1 FROM public.medsec_hospitals h WHERE h.id = v.hospital_id\n"
        f')\n'
        f'{on_conflict};\n'
    )
    path.write_text(out, encoding='utf-8')
    print(f'Wrote {path} ({n} rows)', file=sys.stderr)


if __name__ == '__main__':
    main()
