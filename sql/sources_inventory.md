# 5 份原始資料盤點

> 截至 2026-05-13，Lynn 提供的 5 份原始檔已全部讀完並分析。
> 這份取代之前 mapping_report.md 的單檔結論，作為 import 前的最終策略文件。

---

## 1. 5 份檔案職責

| 檔名 | 性質 | 重點 |
|---|---|---|
| `_______4.xlsx` 員工總表 | **員工 source of truth** | 60 人在職、含部門/職務類別 |
| `0fc190f9-COPI01_1.XLSX` | **客戶 source of truth**（鼎新匯出） | 301 筆、159 欄、含體系/付款條件/業務人員 |
| `719f7d88-INVI02_1.XLSX` | **產品 source of truth**（鼎新匯出） | 5260 筆、187 欄 |
| `93c2ca1b-hospitals_template_20260505_filled.csv` | Lynn 親自篩選的醫院子集 | 185 筆、含業務分區（全名）|
| `239363ab-_____202605111.xlsx` 分區歷史 | 業祕分區歷史記錄 | 582 row、最新欄 `20260511分區` |

---

## 2. 重大策略轉換

**之前我以為 CSV 是醫院主檔 source of truth，現在不是。**

正確的 source 對應：

| 資料 | source | 備註 |
|---|---|---|
| 員工 | 員工總表 `_______4.xlsx` | 60 筆全帶 |
| 醫院主檔（名稱、地址、體系、付款條件、發票格式…）| **COPI01** | 從 301 筆篩出醫院 |
| 醫院業務分區 | CSV `responsible` 欄 + xlsx 暱稱對照 | CSV 為準 |
| 醫院業祕分區 | xlsx `20260511分區` 欄 | 最新版 |
| 產品主檔 | **INVI02** | 篩 `商品分類一=商品` 5239 筆 |
| 體系（hospital_systems）| COPI01 `通路別名稱` 欄 | 34 種 |

---

## 3. COPI01 重要欄位（給 hospitals + hospital_systems 用）

| COPI01 欄 | medsec 對應 | 備註 |
|---|---|---|
| 客戶代號 | `hospitals.copi01_code` | PK |
| 客戶簡稱 | `hospitals.short_name` | |
| 客戶全名 | `hospitals.name` | |
| 統一編號 | `hospitals.tax_id`（新欄）| 給開發票用 |
| 連絡人 / TEL_NO(一) / E-Mail | `hospitals.contact` / `phone` / `email` | |
| 部門名稱 | （略過）| 鼎新內部資訊 |
| **業務人員 / 業務人員名稱** | 一筆 `hospital_assignments(role=salesperson)` | 但 CSV 是多人，鼎新只能登 1 人 → **以 CSV 為準** |
| **通路別名稱** | `hospital_systems.name` | 「長庚體系」「署立體系」… |
| **型態別名稱** | `hospitals.level` | 醫學中心/區域/地區/大學/動物醫院/診所 |
| **地區別名稱 / 國家別名稱** | `hospitals.region` | 北區/中區/南區/花東… |
| **付款條件名稱** | `hospitals.payment_term`（新欄） | 「60天收款」「90天收款」「120天收款」 |
| **發票聯數** | `hospitals.invoice_type`（新欄）| 1:二聯 / 2:三聯 / 7:電子 |
| **單據發送方式** | `hospitals.delivery_method`（新欄）| E-MAIL / 紙本 |
| 收款方式 | `hospitals.payment_method`（新欄）| 支票 / 匯款 / 現金 |
| 收貨人 / 送貨地址 | `hospitals.shipping_*`（新欄）| |
| 初次交易 / 最近交易 | `hospitals.first_dealt` / `last_dealt` | |
| 信用評等 / 銷售評等 | `hospitals.credit_rating` 等 | |

→ **這幾欄直接就是「CRM 知識庫」的內容**（Lynn 規劃的 Week 6-7 模組）。  
→ Schema 要在 `01_shared_schema.sql` 補充這些欄位。

---

## 4. INVI02 重要欄位（給 products 用）

187 欄太多，**只挑 V1 必要的**：

| INVI02 欄 | medsec 對應 |
|---|---|
| 品號 | `products.invi02_code` |
| 品名 | `products.name` |
| 規格 | `products.spec` |
| SIZE / 單位 | `products.size` / `unit` |
| 商品分類二名稱 / 三名稱 / 五名稱 / 七名稱 | `products.category_*` 或 jsonb `products.categories` |
| 原廠 + 主供應商名稱 | `products.vendor` |
| 產品系列 | `products.product_line` |
| **商品描述**（含衛署字號）| `products.description` + **regex 抽 `moh_license`** |
| 採購人員名稱 | `products.purchaser_name` |
| 主供應商 / 主供應商名稱 | `products.supplier` |
| 業務底價 / 業務底價含稅 | `products.base_price` |
| 標準售價 / 售價定價一~六 | `products.std_price`、 `prices_jsonb` |
| 有效天(月\年)數 | `products.shelf_life_days` |
| 庫存數量 / 庫存金額 / 單位成本 | `products.stock_*` |
| 主要庫別 / 庫別名稱 | `products.warehouse` |
| 條碼編號 | `products.barcode` |

### 4.1 衛署字號特殊處理

**INVI02 沒有獨立的衛署字號欄位**，但「商品描述」3630 筆含「衛署醫器輸字第 020434 號」等樣式。

→ Import 時用 regex 抽出 → 塞 `products.moh_license`。

```python
import re
pattern = re.compile(r'衛署[醫器材輸製造販售]+字第\s*\d+\s*號')
```

### 4.2 QSD 完全沒有

INVI02 內**沒有任何 QSD 文件相關欄位**。要：
- 加 `products.qsd_version` / `products.qsd_expiry` 欄
- 但這兩欄初始全空，等 Cindie 之後人工填或上傳 QSD PDF 後系統抽

### 4.3 業務底價 = 0

INVI02 的「業務底價」/「業務底價含稅」5260 筆**全部是 0**。鼎新沒填這個欄位。

→ Lynn 規劃的「報價決策包」需要的「產品底價」**不能從 INVI02 拿**。要另外問 Lynn 哪裡有底價資料。

---

## 5. CSV 缺 code 3 家解答

| CSV 名稱 | 在 COPI01 找到嗎 | COPI01 代碼 |
|---|---|---|
| 員榮 | ✓ | **S-YUM**（員榮醫療社團法人員榮醫院）|
| 星采 | ✓ | **C02**（星采整形外科診所）|
| 博仁綜合醫院 | ✗ | **不在 COPI01** ← Lynn 確認是否要新增？|

---

## 6. 員工 mapping 再補

從 COPI01 的「業務人員」欄看出歷史業務分配，**多了一個新名字**：
- **0077 董靜彤** → 對應 xlsx 的「靜彤」暱稱（之前 mapping report 標未知）

剩 `宇容 / 小駱 / 欣怡 / 欣翎` 4 個暱稱在所有 source 都找不到，**確認是離職員工**。

---

## 7. 待 Lynn 拍板（最終 5 題）

| # | 問題 | 我的建議 |
|---|---|---|
| 1 | **博仁綜合醫院** COPI01 沒、CSV 有 → 怎麼辦？ | 暫時跳過、註記「pending COPI01」|
| 2 | **產品底價**從哪裡來？INVI02 是 0 | 需要 Lynn 給另一份檔，或先用「標準售價」當 placeholder |
| 3 | **INVI02 187 欄位**全 import 還是只挑 V1 必要的 22 欄？ | **只挑 V1 必要欄**（§4 列的），其他存 jsonb `raw_data` |
| 4 | **業務分區**最終確認以 CSV 為準（多人共管）？ | ✓ CSV 為準 |
| 5 | **體系 source**：CSV 的 xlsx 體系 vs COPI01 通路別名稱，差異不大 — 以 COPI01 為準？ | ✓ COPI01 為準（鼎新登記的最權威）|

---

## 8. 同時要 Lynn 再回的（上輪沒回的）

- BOB = 0059 李泓寬？JEFF = 0067 吳柏寬？（兩個推測）
- 業祕只先開 4 主分區（雅婷/小飛/映晨/伶華）OK 嗎？
- 5 個離職暱稱（**宇容 / 小駱 / 欣怡 / 欣翎**）import 略過 → ✓ 因為都找不到對應員工
- 靜彤 = 0077 董靜彤（這個我已 mapping 上）
- xlsx 獨有「天祥醫院 TNTC」要不要納入？

---

## 9. 接下來的工作流（拍完上面就動）

1. 改 `01_shared_schema.sql` 補上 COPI01 / INVI02 欄位
2. 改 `02_shared_rls.sql` 對應
3. 寫 `03_seed_hospital_systems.sql`（34 種體系）
4. 寫 `04_seed_hospitals.sql`（從 COPI01 抓篩過的醫院 + 用 CSV 補業務分區）
5. 寫 `05_seed_products.sql`（從 INVI02 抓 V1 22 欄 + regex 抽衛署字號）
6. 寫 `06_seed_assignments.sql`（業務 + 業祕分區）
7. 全部 SQL 整理進 README、Lynn 一鍵套用
8. 更新 `HANDOVER.md`
