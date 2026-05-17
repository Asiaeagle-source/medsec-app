# Backlog

# Sprint 3:AI 建議價 v2(外部資料源整合)

## 目標
Lynn 審核報價時,AI 自動查 4 個來源算建議價:
1. 內部歷史成交(已有 sales_history 表)
2. 健保支付標準(每月 ETL 衛福部 Excel)
3. 自費特材比價網(每週爬蟲)
4. 政府電子採購得標公告(每天 g0v API ETL)

## Schema 新增
- medsec_nhi_pricing(健保支付)
- medsec_product_nhi_mapping(品號↔健保碼)
- medsec_self_pay_prices(自費比價)
- medsec_tender_awards(標案得標)

## 主要工作
- Edge function:weekly-fetch-self-pay
- Edge function:daily-fetch-tender-awards
- ETL script:monthly-import-nhi
- SQL function:calculate_ai_suggested_price_v2
- Lynn 審核畫面顯示 4 源
- Cindie 維護「品號↔健保碼」對應介面

## 估時
5-7 個工作天

## 前置依賴
- Sprint 2.5 第一批完成 ✅
- Sprint 2.5 補強(Cindie 上傳)完成 ⏳
- 鼎新銷售明細匯出(會計提供)⏳
