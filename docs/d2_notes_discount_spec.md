# D-2:notes 議價解析 — 入庫規格(交 CC)

> 從 medsec_quote_history.notes(備註一)解析業務手寫的「報價/成交/折數」三元組 + 交易類型,結構化入庫,作為 **Card B 的折數真相來源**(比 fuzzy 配對可信)。
> CC 無 DB 連線 → 把下方 Python 解析邏輯做成入庫腳本,Lynn 執行。

---

## 0. 試抽結論(全量 5320 筆已驗證)

- 含議價資訊的 notes 約 5320 筆,**抽出 2956 組乾淨三元組**(產出率 26.7%,1420 筆有值)。
- **折數中位 0.769 / 平均 0.773** — 比 fuzzy 配對的 0.87 更低更真實(無錯配/複製改價污染,這是業務手寫的成交結果)。
- 交易類型標籤:2956 組中 1296 組(44%)有標(參考他院356/新購312/汰舊289/維修221 + 組合)。
- 其中 203 組是「舊報價/舊成交」格式(多為 2023/04 前的歷史價,正是 ERP 涵蓋不到的段)。

**準確度 vs 涵蓋率取捨**:用嚴格規則(金額需緊跟冒號、折數須落 0.3~1.2)→ 抽到的幾乎都對,代價是漏掉格式鬆散的(產出率較低)。**對 Card B「拿歷史折數建議報價」,寧可少抽不可抽錯**,故採嚴格版。涵蓋率之後可加格式規則慢慢補。

---

## 1. 入庫表 schema:`medsec_notes_discount`

```sql
CREATE TABLE IF NOT EXISTS medsec_notes_discount (
  crm_quote_type   text NOT NULL,
  crm_quote_no     text NOT NULL,
  product_code     text NOT NULL,
  seq              int  NOT NULL,        -- 同一筆 notes 多組時的序號(1,2,3..)
  hospital_id      text,
  quoted_price     numeric,             -- 解析出的報價
  sale_price       numeric,             -- 解析出的成交
  discount         numeric,             -- 折數(成交/報價,0.3~1.2)
  is_old_price     boolean DEFAULT false,-- 是否「舊報價/舊成交」格式(歷史價)
  tx_type          text,                -- 交易類型標籤(汰旧/维修/新购/参考他院,可組合)
  source_notes     text,                -- 原始 notes(備查,可選)
  parsed_at        timestamptz DEFAULT now(),
  PRIMARY KEY (crm_quote_type, crm_quote_no, product_code, seq)
);
```

**唯一鍵 = (crm_quote_type, crm_quote_no, product_code, seq)** — 同報價單同品號可有多組(seq 區分,如參考多家醫院)。
**守門**:此表含議價資訊,RLS 比照 medsec_quote_history(機密,業祕不可見折數)。

入庫機制:**累加式 upsert**(ON CONFLICT DO UPDATE),重跑冪等。每次重解析覆蓋同鍵。**絕不 truncate。**

---

## 2. 解析邏輯(Python,已驗證,CC 照此實作)

```python
import re

def to_num(s):
    """'168,000' / '128萬' / '1.5萬' → 數字;排除品號/數量(<500)與異常(>5千萬)"""
    if s is None: return None
    s = s.strip().replace(',', '').replace(' ', '')
    m = re.match(r'^([0-9]+\.?[0-9]*)\s*(萬|万)?$', s)
    if not m: return None
    val = float(m.group(1))
    if m.group(2): val *= 10000
    n = int(val)
    if n < 500 or n > 50000000: return None   # 擋品號/數量誤抓
    return n

def parse_notes(notes):
    """抽報價/成交/折數三元組。金額須緊跟冒號(擋品號粘連),折數須落 0.3~1.2"""
    if not notes: return []
    results = []
    pat_q = r'報價(?:金額|價)?\s*[:：]\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    pat_s = r'成交(?:金額|價)?\s*[:：]\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
    # 三件式就近配對(報價→成交→折數,中間允許換行)
    for m in re.finditer(
        pat_q + r'[\s\S]{0,40}?' + pat_s +
        r'(?:[\s\S]{0,30}?(?:折數\s*[:：]?\s*|約\s*|\()?([0-9]+\.?[0-9]*)\s*折)?', notes):
        q = to_num(m.group(1)); s = to_num(m.group(2))
        if not (q and s): continue
        d = float(m.group(3))/10 if m.group(3) else round(s/q, 3)
        if 0.3 <= d <= 1.2:
            results.append({'quoted': q, 'sale': s, 'discount': round(d,3), 'is_old': False})
    # 舊報價/舊成交格式(歷史價)
    for m in re.finditer(
        r'舊報價\s*[:：]?\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
        r'[\s\S]{0,30}?舊成交\s*[:：]?\s*([0-9][0-9,]{2,}\.?[0-9]*\s*[萬万]?)'
        r'(?:[\s\S]{0,20}?折數\s*[:：]?\s*([0-9]+\.?[0-9]*)\s*折)?', notes):
        q = to_num(m.group(1)); s = to_num(m.group(2))
        if not (q and s): continue
        d = float(m.group(3))/10 if m.group(3) else round(s/q, 3)
        if 0.3 <= d <= 1.2:
            results.append({'quoted': q, 'sale': s, 'discount': round(d,3), 'is_old': True})
    # 去重(同報價+成交只留一筆)
    uniq, seen = [], set()
    for r in results:
        k = (r['quoted'], r['sale'])
        if k not in seen: seen.add(k); uniq.append(r)
    return uniq

def tx_type(notes):
    """交易類型標籤(可組合)"""
    if not notes: return None
    t = []
    if re.search(r'汰舊|汰換|舊換新', notes): t.append('汰旧')
    if re.search(r'維修|維護', notes): t.append('维修')
    if re.search(r'新購|新购', notes): t.append('新购')
    if re.search(r'他院|參考.{0,4}院', notes): t.append('参考他院')
    return '/'.join(t) if t else None
```

入庫流程:讀 medsec_quote_history(notes 非空)→ 每筆 parse_notes() → 每組三元組一列(帶 seq)→ upsert 進 medsec_notes_discount。

---

## 3. 已知限制(寫進 TODO,別當 bug)

1. **產出率 26.7%** — 其餘多為「純報價單無議價資訊」或格式太鬆散。可後續加格式規則補涵蓋率。
2. **折數方向假設**:預設「成交 < 報價」。少數 notes 把報價/成交寫反或語意特殊的可能誤判,靠 0.3~1.2 護欄擋掉大部分。
3. **多組歸屬**:一筆 notes 多組(參考多家醫院)時,seq 區分但不標明「哪組是本院、哪組是他院參考」。tx_type 有「參考他院」標籤可輔助,但精細歸屬需人工或進一步解析。
4. **交易類型是關鍵字標籤**,非結構化分類;組合標籤(汰旧/新购)代表 notes 同時提到多種。

---

## 4. 入庫後驗證

```sql
-- 總組數,預期約 2956
SELECT count(*) FROM medsec_notes_discount;

-- 折數分布,預期中位約 0.77(比 fuzzy 0.87 低、更真實)
SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY discount)::numeric,3) AS 中位,
       min(discount), max(discount) FROM medsec_notes_discount;

-- 交易類型分布
SELECT tx_type, count(*) FROM medsec_notes_discount
WHERE tx_type IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

-- 歷史舊價(2023/04前的金礦)
SELECT count(*) FROM medsec_notes_discount WHERE is_old_price;  -- 預期約 203
```

---

## 5. 對 Card B 的用法(後續)

- Card B 報價建議時,優先查 `medsec_notes_discount` 取「本院該品項的歷史折數 + 交易類型」。
- 報維修單 → 篩 tx_type 含「维修」的折數;報新購 → 篩「新购」。**這就解決了「成交端分不出交易類型」的硬傷** — notes 補上了類型標籤。
- 折數可信度:notes 解析(0.77,業務手寫) > fuzzy 配對(0.87,有雜訊)。Card B 以 notes 為主、fuzzy 為輔。
