# mail-triage(信件分流)

階段一只完成「規則 + AI 分類 + 醫院辨識」邏輯,**還沒**接 Microsoft Graph、也還沒落地成 Supabase Edge Function。`rules.js` 先當設計稿放這裡,未來排程後端(Vercel Cron 或 Supabase Function)直接 import。

## 接續工作

1. 寫排程器:每天兩次抓 Exchange 未讀信(寄件者 / 主旨 / 內文前段)→ 對每封呼叫 `classifyMail()`。
2. 把回傳物件 upsert 進 `public.mail_digest`(schema 見 `sql/v3/20_mail_digest_schema.sql`),`graph_message_id` 為唯一鍵。
3. 前端 `mail-triage.html` 已在讀 `v_mail_digest_assigned`,落地後即顯示真實資料。

## `classifyMail(mail)` 輸入

```ts
{
  graphMessageId: string,
  receivedAt:     string,   // ISO
  subject:        string,
  snippet:        string,   // 內文前段(只送這段給 Claude,不送全文)
  senderName:     string,
  senderEmail:    string,
}
```

## 輸出(可直接 upsert 到 `mail_digest`)

```ts
{
  graph_message_id, received_at,
  sender_email, sender_name, subject,
  ai_summary, priority, category, flag_reason, deadline,
  hospital_id,   // medsec_hospitals.id;認不出 → null,manager 手動指派
}
```

`assigned_to` / `status` / `digest_date` 由 DB 預設值補。`v_mail_digest_assigned` 會把 `hospital_id` 對到 `medsec_secretary_assignments` 自動帶出 `effective_secretary_id` / `effective_secretary_name`。
