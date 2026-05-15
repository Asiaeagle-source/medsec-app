# medsec-app 完整業務藍圖(V2+ 全貌)

> 給 CC(Claude Code)用的全景文件。
> Sprint 1 只做一小塊(主檔治理 + 規則中央化)。
> 但 CC 必須看完整版才知道**現在做的 schema 是為了承接未來什麼**,別把基礎建窄了。

---

## 第一部分:公司業務全貌

### 1.1 公司基本

- **Asia Eagle / 雄鷹**(主)+ **君華**(子)
- 醫療器材代理:**Medtronic**(主力,5103 / 5260 品號)+ 君華代理線
- 主要產品線:神經外科 / 骨科動力 / ENT / 手術系統 / SPS / TiMesh / MR8
- 規模:**60 員工** / **301 客戶**(其中 253 家醫院)/ **5260 個品號**
- 月營收體量:標案級單筆動輒數十萬到數百萬

### 1.2 員工角色(6 種)

| 代號 | 角色 | 人 | 主要動作 |
|---|---|---|---|
| `manager` | 總經理 | Lynn(0006 賴瑩)| 看全部含成本,審核規則建議與決策 |
| `secretary` | 業祕(4 位)| 關雅婷、魏伶華(協審)、楊斯閔、第 4 位 | 中央化規則維護、報價、建碼、出貨、結帳 |
| `bidding_team` | 標案組(跨職能)| Candy 為主 | **標案 + 維修 + 壞品 + 保證金 + 知識庫** |
| `accounting` | 會計 | 多人 | 保證金、傳票、月結對帳(看不到成本明細) |
| `sales` | 業務 | 多人 | 自己分區的案件、跟刀、客戶溝通 |
| `customer_service` | 客服 | 待釐清 | **跟原廠(Medtronic)對接**:壞品通報、維修送修、TiMesh 製作 |

### 1.3 跟現有系統的關係

| 系統 | 用途 | medsec-app 立場 |
|---|---|---|
| **COPI01** | 鼎新匯出客戶主檔 | dingxin_code 唯一 source of truth,V2 zip 對不到的一律 skip |
| **INVI02** | 鼎新匯出產品主檔(5260 筆)| 進 V2 `products` 表(Sprint 2+),價格欄目前是 0 需另來源 |
| **鼎新 ERP** | 傳票/帳務/採購單據 | 不取代,medsec 只記錄關聯;ETL `erp_vouchers` |
| **EF**(內部簽核)| 押標金/履保金/保固金申請 | **不取代**,medsec 補上「追蹤 + 提醒」價值 |
| **政府電子採購網** | 標案領標、開標 | medsec 抓 g0v API 自動監控 |
| **Super Helper** | 跟刀紀錄 `61.220.112.67` | V2 不整合,屬於 medteam(業務端) |
| **LINE 群組** | 維修群組通報、業務協作 | V2.1+ 做「一鍵通報自動發訊息」 |

---

## 第二部分:業務場景全景(嘉榮 11 分類)

從嘉榮樣本(315 檔)抽出的**標準業祕工作骨架**,**這 11 個分類就是 medsec-app 必須支援的 11 個業務場景**。

| # | 場景 | 範例文件數 | 對應 SOP | 主要角色 |
|---|---|---|---|---|
| 1 | **報價** | 115 檔 | WIB02/03/04/05, WIS02/03 | 業祕 + Lynn |
| 2 | **建碼** | 77 檔(6 品項 + SPS)| WIB01, WIS01 | 業祕 |
| 3 | **院內碼對照** | 2 檔 | (附屬建碼)| 業祕 |
| 4 | **標案** | 71 檔(3 完整案)| WIB06, WIS04 | **Candy** + Lynn + 會計 |
| 5 | **合約**(保養/耗材/設備)| 15 檔 | (新)| 業祕 + Lynn |
| 6 | **交機驗收** | 6 檔 | WIB14, WIS08 | 業祕 + 業務 |
| 7 | **履約保固** | 2 檔 | WIS10 | 業祕 + Candy |
| 8 | **單據**(壞品/申請)| - | WIB16, WIS09 | **Candy** + 客服 |
| 9 | **院內表格** | 1 檔 | (新)| 業祕 |
| 10 | **函文**(健保變更/缺貨/廠牌)| 24 檔 | (新)| 業祕 + Lynn |
| 11 | **其他** | - | - | - |

### 2.1 業務場景 vs SOP 對照(WIS + WIB 全清單)

**WIS 系列(業務部)**:
- WIS01 新品建碼、WIS02 預算、WIS03 維修報價、WIS04 招標、WIS05 試用品(DEMO)
- WIS06 議價、WIS07 寄售放品、WIS08 設備交貨、WIS09 維修品送修、WIS10 設備保養
- WIS11 TiMesh 送件製作、WIS12 醫學會、WIS13 研討會、WIS14 CADAVER 模擬手術
- WIS15 公司開會、WIS16 每日預計行程回報、WIS17 跟刀、WIS18 Expense 申請

**WIB 系列(業務秘書部)**:
- WIB01 新品建碼、WIB02 預算、WIB03 專案報價、WIB04 器械報價、WIB05 維修報價
- WIB06 招標、WIB07 試用品(DEMO)、WIB08 議價、WIB09 寄.暫放品、WIB10 出貨
- WIB11 包貨、WIB12 欠貨、WIB13 訂貨、WIB14 設備交貨、WIB15 維修品
- WIB16 壞品(問題品)、WIB17 TiMesh 送件製作、WIB18 醫學會、WIB19 CADAVER
- WIB20 公司開會 / 溫濕度計校正、WIB21 應收帳款、WIB22 溫濕度計校正

---

## 第三部分:跨 SOP 通用工作流(5 步驟模式)

從 4 份高介入 SOP(WIB09/10/11/WIS09)抽出,所有業祕案件其實長一樣:

```
┌─ Step 1:觸發 ────────────────────────┐
│ 業務群組通報 / 業務寄件回公司 /       │
│ 醫院通知 / LINE 訊息                  │
└────────────────┬──────────────────────┘
                 ↓
┌─ Step 2:收件登記 ────────────────────┐
│ 收貨 → 群組回覆「已收到」             │
│ 檢核業務填寫的表單                    │
│ (壞品單/確認單/申請單)                │
└────────────────┬──────────────────────┘
                 ↓
┌─ Step 3:內部處理 ────────────────────┐
│ key 正航(鼎新)單據:                  │
│ 調撥 / 借單 / 銷單 / 暫借單           │
│ 交客服 / 通知業祕 / 登雲端表單        │
└────────────────┬──────────────────────┘
                 ↓
┌─ Step 4:對外動作 ────────────────────┐
│ 配貨包裝 → 寄業務(中南)/業務親取(北)  │
│ 或 寄美敦力 / 寄工廠 / 寄醫院         │
└────────────────┬──────────────────────┘
                 ↓
┌─ Step 5:完成/結案 ───────────────────┐
│ 系統還回 / 沖銷                       │
│ 借轉銷 → 開發票                       │
│ 文件歸檔(盤點明細表、調撥單存底)      │
└───────────────────────────────────────┘
```

**這 5 步驟模式就是 `medsec_cases` 表的標準狀態機**(V3.3 已 merged)。

---

## 第四部分:medsec-app 是「工作平台」,不是「查詢工具」

⚠️ **重要思維轉換** — 不是 form-based 的 CRUD,而是「**業祕把材料丟進去,AI 幫忙處理**」:

```
業祕的輸入 → AI 處理 → 業祕審核 → 給總經理決策 → 業祕去鼎新打單
```

### 4.1 每個業務場景需要的輸入介面

```
═══════════════════════════════════════════════════════════
medsec-app 的 11 個輸入介面(Sprint 2+ 主力)
═══════════════════════════════════════════════════════════

📋 報價輸入(quotes)
  ├─ 上傳:業務 LINE 截圖 / 醫院詢價單 PDF
  ├─ 選擇:醫院 + 品項 + 數量
  └─ AI 產出:報價建議 + 給 Lynn 看的決策畫面

📋 建碼輸入(product_registrations)
  ├─ 選擇:醫院 + 要建碼的品號
  ├─ 上傳:醫師同意書(若有)
  └─ AI 產出:建碼文件包(衛署PDF+QSD+健保碼+授權書)+ 鼎新 CRM 報價單範本

📋 標案輸入(tenders)⭐ Candy 主用
  ├─ 上傳:整包標書 PDF(政府採購網下載)
  ├─ 補充:標案編號、開標日、押標金金額
  └─ AI 產出:規格對照 + 文件清單 + 報價建議 + 保證金生命週期追蹤

📋 維修輸入(repairs)
  ├─ 上傳:醫院維修通知 / 業務拍的設備照片
  ├─ 選擇:設備序號(從 deliveries 帶出)
  └─ AI 產出:保固判斷(保內 0 元換新 / 保外維修 / 汰舊換新)+ 維修報價 + 申請單

📋 合約輸入(contracts)
  ├─ 上傳:醫院給的合約草稿(PDF/Word)
  └─ AI 產出:合約對照表 + 風險提示

📋 退換貨輸入(forms)
  ├─ 上傳:壞品照片 + 服務技術報告(QM-002-1-C)
  └─ AI 產出:壞品單 + 不計價申請單 + 通報原廠 email 草稿

📋 寄售盤點輸入(WIB09)
  ├─ 選擇:醫院 + 盤點日期
  ├─ 上傳:盤點明細表(手寫拍照 OCR)
  └─ AI 產出:補貨單 + 調整建議

📋 函文輸入(official_letters)
  ├─ 選擇:函文類型(健保變更/缺貨說明/廠牌變更)
  ├─ 選擇:適用醫院(多選)
  └─ AI 產出:制式函文 + 寄送清單

📋 設備暫借(WIB07 DEMO)
  ├─ 選擇:醫院 + 借出品項 + 預計還回日
  └─ AI 產出:借出申請單 + 還回追蹤 + 逾期提醒

📋 議價回報(WIB08)
  ├─ 輸入:議價結果(成交/未成交、金額、折數)
  └─ AI 自動更新:案件狀態 + 成交歷史(供 AI 建議價學習)

📋 院內表格(hospital_forms)
  ├─ 上傳:醫院給的特殊表格(PDF/Word)
  └─ AI 產出:預填好的版本(從主檔自動填)
```

### 4.2 配合的儲存表(超越 11 業務場景,基礎建設)

```sql
-- 業祕丟材料進來
uploads(case_id, upload_type, file_path, ocr_status, 
        ai_extraction_status, extracted_data jsonb)

-- AI 產出
ai_outputs(case_id, output_type, content jsonb, confidence,
           secretary_reviewed, secretary_modified, final_output)

-- 系統產出可下載文件
generated_documents(case_id, document_type, file_path, 
                    ready_for_dingnew)

-- 給 Lynn 的決策畫面
decision_panels(case_id, snapshot_at, cost, margin, suggested_price,
                historical_reference, crm_warnings, manager_decision)
```

---

## 第五部分:8 大功能模組(V2+ 整體規劃)

### 模組 1:醫院規則中央化(主檔治理)⭐ **Sprint 1 進行中**

| V1 已做 | V2 加值 |
|---|---|
| `hospital_operation_rules`(9 欄)| **規則自學**(模式 A/B/C/D 對話式)|
| `hospital_shipping_addresses`(39 收件地址)| **規則衝突偵測**|
| `discount_rules`(3 種折讓模式)| **折讓自動計算**|
| | **完整度視覺化**(9 維分母)|

### 模組 2:標案 + 保證金生命週期 ⭐ Candy 主用(Sprint 2 重點)

對應 SOP:WIB06、WIS04;對應嘉榮 4. 標案

| 功能 | 描述 |
|---|---|
| 標案抓取 | 政府採購網 / g0v 標案 API 自動推播 |
| 標書解析 | AI 拆解 PDF → 規格表、文件清單 |
| 押標金申請 | 自動產 EF 申請單草稿 |
| 履保金追蹤 | 得標後自動建履保金 case |
| 保固金追蹤 | 履約結束自動觸發退保固金 |
| 整體生命週期 | 押標 → 履保 → 保固 → 退保固 4 階段 dashboard |

Schema:`tenders` + `tender_bonds` + `ef_applications`

### 模組 3:報價系統 + AI 建議價

對應 SOP:WIB02/03/04/05;對應嘉榮 1. 報價

| V1 已做 | V2 加值 |
|---|---|
| (V1 沒做)| 7 種報價類型(出貨用/建碼/新品/汰換/維修/耗材/設備預算)|
| | AI 根據歷史成交、體系內參考價、CRM 折讓慣例 → 建議價 |
| | 給 Lynn 一鍵決策畫面(成本/毛利/建議價)|

⚠️ AI 建議價需 3 年歷史成交資料 ETL,**留到 V2.1**

### 模組 4:建碼自動化

對應 SOP:WIB01、WIS01;對應嘉榮 2. 建碼

| 功能 |
|---|
| 從醫院模板自動填建碼資料表 |
| 自動組裝建碼文件包(衛署PDF+QSD+健保碼+同體系契約參考+授權書)|
| 自動產嘉榮 27703 等鼎新 CRM xls 範本(已預填)|

### 模組 5:出貨 / 包貨 / 結帳

對應 SOP:WIB09/10/11/12/13/21、WIS07

| V1 已做 | V2 加值 |
|---|---|
| 配貨包裝紀錄 | 自動排程提醒(讓業祕從「記得做」變「系統提醒做」)|
| 月結對帳 | 折讓自動計算(對應 `discount_rules`)|

### 模組 6:維修 / 壞品 / TiMesh ⭐ Candy + 客服

對應 SOP:WIB15/16/17、WIS09/11

| V1 已做 | V2 加值 |
|---|---|
| 3 條獨立流程 | **保固期自動判斷**(輸入序號,推「保內換新/保外報價」)|
| 技術服務報告 | **壞品照片 AI 分類**(刀片崩/Shunt 漏/burr 不利)|
| 維修群組通報 | **群組通報自動化**(系統按鈕自動發 LINE 訊息)|
| TiMesh 4 工作天追蹤 | **TiMesh 全程追蹤儀表板**(CT 上傳 → 工廠 → 設計圖 → 確認 → 成品)|
| | **美敦力對接通報自動化**(壞品自動產 email 草稿) |

### 模組 7:設備生命週期(交貨 → 保養 → 履約)

對應 SOP:WIB14、WIS08/10;對應嘉榮 6. 交機驗收 + 7. 履約保固

| V1 已做 | V2 加值 |
|---|---|
| 交機驗收 case | 交機文件包自動組裝(出貨單/型錄/進口報單/驗收記錄/保固書)|
| 教育訓練排程 | 設備交機後 X 日內自動建教育訓練 case |
| 設備序號主檔 | 保養工單自動排程(依設備類型)|
| | 月底未交回工單自動列表 |
| | 整合 模組 2 保固金追蹤 |

### 模組 8:函文 + 知識庫

對應嘉榮 10. 函文;對應 RAG `crm_chunks`

| 功能 |
|---|
| 函文模板庫(健保支付點數修訂 / 自費特材代碼變更 / 缺貨說明 / 廠牌變更)|
| 適用醫院多選 → 批次寄送清單 |
| 跟刀 SOP(WIS17)當 RAG 種子(V2.2 給業務端,medteam-app)|
| CRM 規則 RAG(13 份 Excel 抽 chunks)|

---

## 第六部分:Sprint 切分 + 頁面對應

### Sprint 1 範圍(現在卡在 batch A)

| 模組 | 頁面 | 狀態 |
|---|---|---|
| 模組 1 規則中央化 | `index.html` | V1 既有,不動 |
| | `secretary.html` | V1 既有,**batch B 擴充「我負責的醫院」+ 完整度** |
| | `hospital.html` | **batch C 新建**(規則/帳密/audit log/待審 suggestions)|
| | `manager.html` | V1 既有,**batch D 擴充審核中心** |
| | `rule-chat.html` | **batch E 新建**(模式 A/B/C/D 對話式)|
| | (Edge)`claude-chat` | **batch E 新建** |

⚠️ 共用元件:右下角 FAB「💬 問問題」/ 左上角 nav

### Sprint 2 範圍(規劃中)

| 模組 | 頁面 | 對應 |
|---|---|---|
| 模組 2 標案 | `tenders.html` / `bonds.html` | Candy 主入口 |
| 模組 8(部分)| `tender-monitor.html` | g0v 標案 API 推播 + Resend Email |
| 模組 6 維修 | `repairs.html` / `forms.html` | Candy + 客服 |
| (折讓表 ETL) | (背景作業) | 17→12 欄對齊 + 4 家 needs_review 補 |

### Sprint 3+ 規劃

| 模組 | 頁面 | 對應 |
|---|---|---|
| 模組 3 報價 + AI 建議價 | `quotes.html` | V2.1 接 3 年歷史成交 |
| 模組 4 建碼 | `registrations.html` | 從嘉榮模板學 |
| 模組 5 出貨 | (整併 secretary.html 多 tab)| |
| 模組 7 設備 | `deliveries.html` / `warranties.html` | |
| 模組 8 函文 | `letters.html` | |

---

## 第七部分:完整 schema 預覽(27 張表)

```
═══════════════════════════════════════════════════════
medsec-app Schema 全貌
═══════════════════════════════════════════════════════

【主檔層 / Sprint 1 已 seed】
1.  profiles                      60 人(uuid,Supabase Auth)
2.  medsec_hospitals              185(Q8 拍板)/將來 253
3.  products                      5260(INVI02,Sprint 2 ETL)
4.  medsec_secretary_assignments  182 家

【案件主檔 / V3.3 已 merged】
5.  medsec_cases                  貫穿 11 個業務場景

【業務場景表 / Sprint 2+】
6.  medsec_quotes                 報價
7.  medsec_product_registrations  建碼
8.  medsec_hospital_product_codes 院內碼
9.  medsec_tenders                標案 ⭐ Candy
10. medsec_tender_bonds           保證金生命週期 ⭐
11. medsec_contracts              合約
12. medsec_deliveries             交機驗收
13. medsec_warranties             履約保固
14. medsec_forms                  壞品/申請單 ⭐ Candy
15. medsec_hospital_forms         院內表格
16. medsec_official_letters       函文
17. medsec_repairs                維修案件 ⭐ Candy
18. medsec_case_documents         彈性文件包

【補充規則 / Sprint 1 含一部分】
19. medsec_hospital_operation_rules   ⭐ Sprint 1
20. medsec_hospital_doc_templates     各醫院文件包模板
21. medsec_hospital_shipping_addresses 39 收件地址
22. medsec_hospital_credentials       ⭐ Sprint 1
23. medsec_rule_suggestions           ⭐ Sprint 1(規則自學)
24. medsec_audit_log                  ⭐ Sprint 1
25. medsec_discount_rules             3 種折讓(Sprint 2 ETL)
26. medsec_accounting_subjects        1284-1/3/5、1113A02

【AI 處理層 / Sprint 2+】
27. uploads                       業祕丟材料
28. ai_outputs                    AI 產出
29. generated_documents           可下載文件
30. decision_panels               給 Lynn 的決策畫面

【外部整合 / Sprint 3+】
31. ef_applications               EF 申請紀錄
32. erp_vouchers                  鼎新 ERP 傳票

【RAG 知識庫 / V2.2】
33. crm_chunks                    13 份 CRM 抽
```

---

## 第八部分:跟 CC 溝通的標準句型

### 動 Sprint 1 batch 時

```
動 batch B(secretary.html「我負責的醫院」+ 完整度卡片)。

範圍:只限模組 1 醫院規則中央化。
讀 docs/PROJECT_OVERVIEW.md + docs/PAGES_SPEC.md §2 當需求。
跑 acceptance 3 條:
  1. RLS — 業祕 A 看不到業祕 B 主分區
  2. 完整度 % 跟手動算 view 一致
  3. 點卡片正確跳轉

⚠️ 提醒:這頁將來會擴充成業祕主入口,Sprint 2 會加標案/維修/出貨等 tab,
所以 layout 要留出 navigation 擴充空間。
```

### 設計 schema 時提醒 CC 看大圖

```
動 medsec_quotes(模組 3 報價)schema 時,
要先看 docs/PROJECT_OVERVIEW.md 第五部分模組 3 的「7 種報價類型」+
第四部分「報價輸入介面」設計。

不要只設計「出貨用報價」一種,要 7 種都涵蓋,用 quote_type enum 區分:
- shipment(出貨用)
- registration(建碼)
- new_product(新品)
- replacement(汰舊換新)
- repair(維修)
- consumable(耗材)
- budget(設備預算)

每種 quote_type 對應不同 UI,但底層 schema 共用。
```

### 接手新 session 時

```
讀完這 3 份再動:
1. docs/PROJECT_OVERVIEW.md(全景)
2. docs/PAGES_SPEC.md(頁面詳細)
3. docs/v1_schema_snapshot_and_v2_conflicts.md(現有 V1 別撞)

絕對不要:
- DROP / RENAME V1 既有表
- 重新發明 medsec_employees(用 profiles)
- 把單一 sprint 範圍越界
- 不確定欄名/型別就腦補(查 information_schema)

絕對要:
- 任何欄名查 information_schema.columns 確認
- 不確定就停下來問
- 動 Sprint X 之前看 PROJECT_OVERVIEW 第六部分對應模組
```

---

## 第九部分:角色 → 頁面 → 模組 對照表

| 角色 | 主入口 | 主要看 |
|---|---|---|
| Lynn(manager)| `manager.html` | 全部模組 1-8 含成本 |
| 業祕(secretary)| `secretary.html` | 模組 1, 3, 4, 5(自己分區)|
| Candy(bidding)| `tenders.html`(Sprint 2 後)| 模組 2, 6 全部 + 模組 1 唯讀 |
| 會計 | (Sprint 2 後)| 模組 2 保證金 + 模組 5 月結 + 模組 7 履約 |
| 業務 | medteam-app 為主 | medsec 唯讀:模組 5 出貨進度、模組 6 維修進度 |
| 客服 | (待釐清)| 模組 6 美敦力對接 |

---

## 第十部分:重要拍板原則(Sprint 1 已定)

1. **dingxin_code** = COPI01 唯一 source of truth
2. **員工識別** = `profiles.id` uuid → `auth.uid()`,不建 medsec_employees
3. **完整度分母** = 9 維(不含 dual_invoice/contact_person/special_notes)
4. **RLS 助手** = reuse V1 既有 `can_see_medsec_hospital()`
5. **帳密誰看** = 主祕 + 副祕 + 管理層(Q7 B)
6. **hospitals 主祕 text 欄** = display cache,RLS 不依賴
7. **Sprint 1 hospital 範圍** = 只動已 seed 的 185
8. **未對應折讓 4 家** = 排除標 needs_review
9. **invoice_company** = integer 不是 'AE'/'LD' 字串
10. **EF / 鼎新 ERP / Super Helper** = 不取代,只追蹤
