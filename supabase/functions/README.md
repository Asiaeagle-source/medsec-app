# supabase/functions — Edge Functions

## claude-chat

服務端 relay Claude API,讓前端不暴露 `ANTHROPIC_API_KEY`。
給 `rule-chat.html` (V2 sprint 1 §3.3 模式 D 自由問答) 用。

### 部署 (Lynn 一次性設定)

```bash
# 1. 安裝 Supabase CLI (一次性)
#    macOS: brew install supabase/tap/supabase
#    Windows: scoop bucket add supabase https://github.com/supabase/scoop-bucket.git && scoop install supabase

# 2. 登入 + link project (一次性)
supabase login
supabase link --project-ref yincuegybnuzgojakkuc

# 3. 設定 ANTHROPIC_API_KEY 為 Supabase secret (一次性)
#    去 https://console.anthropic.com 拿一把 sk-ant-... 開頭的 key
supabase secrets set ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxx

# 4. (Optional) override 模型
supabase secrets set CLAUDE_MODEL=claude-sonnet-4-6

# 5. 部署 function
cd /path/to/medsec-app
supabase functions deploy claude-chat
```

部署後 endpoint:
```
https://yincuegybnuzgojakkuc.supabase.co/functions/v1/claude-chat
```

### 前端呼叫範例

```js
const { data: { session } } = await supa.auth.getSession();
const r = await fetch(`${SUPABASE_URL}/functions/v1/claude-chat`, {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${session.access_token}`,
    'apikey': SUPABASE_ANON_KEY,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    system: '你是雄鷹業祕助手,...',
    messages: [{ role: 'user', content: '高榮 MR8 怎麼出?' }],
    max_tokens: 1024,
  }),
});
const data = await r.json();
const text = data.content[0]?.text || '';
```

### 安全模型

- JWT auth required (預設,non-anon)
- 不對 user input 做任何 DB 查詢 (純 LLM relay)
- 醫院規則 / 帳密等敏感資料**由前端先 query** (走 RLS),再以 system prompt 形式餵進來
  - 不在 edge function 裡查 DB → service-role key 不會洩漏業祕看不到的資料

### 限額 / 監控

V2.0 不做 rate limit,V2.1 加。
log 在 Supabase Dashboard > Edge Functions > claude-chat > Logs。

### Troubleshooting

| 症狀 | 原因 | 修 |
|---|---|---|
| `500 ANTHROPIC_API_KEY missing` | 沒設 secret | `supabase secrets set ANTHROPIC_API_KEY=...` |
| `401 invalid_api_key` | key 錯 / 過期 | 去 console.anthropic.com 重產 |
| `400 model_not_found` | CLAUDE_MODEL 寫錯 | 改回 `claude-sonnet-4-6` |
| `429 rate_limit_exceeded` | 用太多 | 等 / 升 Anthropic plan |
| 前端 CORS 錯 | edge fn 沒回 CORS header | (本檔已處理) |
