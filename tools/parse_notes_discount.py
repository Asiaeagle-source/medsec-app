#!/usr/bin/env python3
"""
D-2 notes 議價解析入庫(spec: docs/d2_notes_discount_spec.md)

從 medsec_quote_history.notes(備註一)抽 (報價/成交/折數) 三元組,
upsert 至 medsec_notes_discount。

用法
----
  export SUPABASE_URL=https://yincuegybnuzgojakkuc.supabase.co
  export SUPABASE_SERVICE_KEY=eyJ...   # service_role key (繞 RLS,從 Dashboard → Settings → API 取)
  python3 tools/parse_notes_discount.py [--dry-run] [--limit N] [--batch 500]

選項
----
  --dry-run     只解析、不寫 DB,印產出統計
  --limit N     僅讀前 N 筆 notes(測試用)
  --batch SIZE  upsert 批次大小,預設 500

安全
----
  - SERVICE_KEY 千萬不要 commit / 貼到 chat。
  - 累加式 upsert(ON CONFLICT DO UPDATE),重跑冪等。
  - 絕不 TRUNCATE。
  - 解析規則嚴格(spec §0):寧可少抽不抽錯。

預期(spec §0):輸入 ~5,320 筆含 notes 列 → 輸出 ~2,956 組三元組;
              折數中位 ≈ 0.77,is_old_price ≈ 203。
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


# ---------- 解析邏輯(逐字 = spec §2,已驗證) ----------

def to_num(s):
    """'168,000' / '128萬' / '1.5萬' → int;品號/數量(<500)與異常(>5千萬)→ None"""
    if s is None:
        return None
    s = s.strip().replace(',', '').replace(' ', '')
    m = re.match(r'^([0-9]+\.?[0-9]*)\s*(萬|万)?$', s)
    if not m:
        return None
    val = float(m.group(1))
    if m.group(2):
        val *= 10000
    n = int(val)
    if n < 500 or n > 50_000_000:
        return None
    return n


_PAT_TRIPLE = re.compile(
    r'報價(?:金額|價)?\s*[:：]\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    r'[\s\S]{0,40}?'
    r'成交(?:金額|價)?\s*[:：]\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    r'(?:[\s\S]{0,30}?(?:折數\s*[:：]?\s*|約\s*|\()?([0-9]+\.?[0-9]*)\s*折)?'
)
_PAT_OLD = re.compile(
    r'舊報價\s*[:：]?\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    r'[\s\S]{0,30}?'
    r'舊成交\s*[:：]?\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    r'(?:[\s\S]{0,20}?折數\s*[:：]?\s*([0-9]+\.?[0-9]*)\s*折)?'
)


def parse_notes(notes):
    """抽報價/成交/折數三元組。金額須緊跟冒號(擋品號粘連),折數須落 0.3~1.2"""
    if not notes:
        return []
    results = []
    for m in _PAT_TRIPLE.finditer(notes):
        q = to_num(m.group(1))
        s = to_num(m.group(2))
        if not (q and s):
            continue
        d = float(m.group(3)) / 10 if m.group(3) else round(s / q, 3)
        if 0.3 <= d <= 1.2:
            results.append({'quoted': q, 'sale': s, 'discount': round(d, 3), 'is_old': False})
    for m in _PAT_OLD.finditer(notes):
        q = to_num(m.group(1))
        s = to_num(m.group(2))
        if not (q and s):
            continue
        d = float(m.group(3)) / 10 if m.group(3) else round(s / q, 3)
        if 0.3 <= d <= 1.2:
            results.append({'quoted': q, 'sale': s, 'discount': round(d, 3), 'is_old': True})
    # 去重(同報價+成交只留一筆)
    uniq, seen = [], set()
    for r in results:
        k = (r['quoted'], r['sale'])
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    return uniq


def tx_type(notes):
    """交易類型標籤(可組合)"""
    if not notes:
        return None
    t = []
    if re.search(r'汰舊|汰換|舊換新', notes):
        t.append('汰旧')
    if re.search(r'維修|維護', notes):
        t.append('维修')
    if re.search(r'新購|新购', notes):
        t.append('新购')
    if re.search(r'他院|參考.{0,4}院', notes):
        t.append('参考他院')
    return '/'.join(t) if t else None


# ---------- Supabase REST helpers ----------

def http_request(method, url, *, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'{method} {url} → HTTP {e.code}: {e.read().decode("utf-8", "replace")[:500]}') from e


def fetch_notes_rows(base_url, key, limit=None, page_size=1000):
    """分頁拉 quote_history(notes 非空)。回傳 list[dict]"""
    out = []
    fetched = 0
    headers = {
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Accept': 'application/json',
    }
    select_cols = 'crm_quote_type,crm_quote_no,product_code,hospital_id,notes'
    while True:
        page = page_size
        if limit is not None:
            remaining = limit - fetched
            if remaining <= 0:
                break
            page = min(page_size, remaining)
        url = (
            f'{base_url}/rest/v1/medsec_quote_history'
            f'?select={select_cols}'
            f'&notes=not.is.null'
            f'&order=crm_quote_type.asc,crm_quote_no.asc,product_code.asc'
        )
        h = dict(headers, Range=f'{fetched}-{fetched + page - 1}',
                 **{'Range-Unit': 'items'})
        status, body = http_request('GET', url, headers=h)
        rows = json.loads(body)
        if not rows:
            break
        out.extend(rows)
        fetched += len(rows)
        if len(rows) < page:
            break
        if limit is not None and fetched >= limit:
            break
    return out


def upsert_batch(base_url, key, rows):
    url = (
        f'{base_url}/rest/v1/medsec_notes_discount'
        f'?on_conflict=crm_quote_type,crm_quote_no,product_code,seq'
    )
    headers = {
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates,return=minimal',
    }
    http_request('POST', url, headers=headers, body=rows)


# ---------- main ----------

def build_rows(input_rows):
    """quote_history rows → notes_discount rows(每筆 notes 多組就多列)"""
    out = []
    n_parsed_any = 0
    for q in input_rows:
        notes = q.get('notes') or ''
        triples = parse_notes(notes)
        if not triples:
            continue
        n_parsed_any += 1
        ttype = tx_type(notes)
        # source_notes 截斷防 row 過大
        snippet = notes if len(notes) <= 500 else notes[:500]
        for i, t in enumerate(triples, start=1):
            out.append({
                'crm_quote_type': q['crm_quote_type'],
                'crm_quote_no':   q['crm_quote_no'],
                'product_code':   q['product_code'],
                'seq':            i,
                'hospital_id':    q.get('hospital_id'),
                'quoted_price':   t['quoted'],
                'sale_price':     t['sale'],
                'discount':       t['discount'],
                'is_old_price':   t['is_old'],
                'tx_type':        ttype,
                'source_notes':   snippet,
            })
    return out, n_parsed_any


def main():
    ap = argparse.ArgumentParser(description='D-2 notes 議價解析入庫')
    ap.add_argument('--dry-run', action='store_true', help='只解析、不寫 DB')
    ap.add_argument('--limit', type=int, default=None, help='僅讀前 N 筆 notes(測試)')
    ap.add_argument('--batch', type=int, default=500, help='upsert 批次大小')
    args = ap.parse_args()

    base_url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_KEY', '')
    if not base_url or not key:
        print('錯誤:請設 SUPABASE_URL 與 SUPABASE_SERVICE_KEY 環境變數', file=sys.stderr)
        sys.exit(2)

    t0 = time.time()
    print(f'[1/3] 讀 medsec_quote_history(notes 非空)…', flush=True)
    src = fetch_notes_rows(base_url, key, limit=args.limit)
    print(f'      讀到 {len(src)} 筆(目標 ~5,320,spec §0)')

    print(f'[2/3] 解析 notes …', flush=True)
    rows, n_parsed = build_rows(src)
    n_old = sum(1 for r in rows if r['is_old_price'])
    n_tx = sum(1 for r in rows if r['tx_type'])
    discounts = [r['discount'] for r in rows]
    if discounts:
        mid = sorted(discounts)[len(discounts) // 2]
    else:
        mid = None
    print(f'      抽出 {len(rows)} 組(來自 {n_parsed} 筆 notes,產出率 '
          f'{n_parsed / max(1, len(src)) * 100:.1f}%)')
    print(f'      折數中位 {mid}(spec 目標 ≈ 0.769)')
    print(f'      is_old_price: {n_old}  /  有 tx_type: {n_tx}')

    if args.dry_run:
        print('--dry-run:跳過寫入。範例前 3 列:')
        for r in rows[:3]:
            print(' ', json.dumps(r, ensure_ascii=False))
        return

    print(f'[3/3] upsert → medsec_notes_discount(每批 {args.batch})…', flush=True)
    sent = 0
    for i in range(0, len(rows), args.batch):
        chunk = rows[i:i + args.batch]
        upsert_batch(base_url, key, chunk)
        sent += len(chunk)
        print(f'      {sent}/{len(rows)}', flush=True)
    print(f'完成。耗時 {time.time() - t0:.1f}s。')
    print('SQL Editor 驗證見 sql/v3/15_medsec_notes_discount.sql 檔尾。')


if __name__ == '__main__':
    main()
