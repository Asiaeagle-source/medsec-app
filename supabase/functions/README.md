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

### 限額 / 監控 (Lynn #3 防成本爆)

**前提**:先跑 `sql/v2/09_create_chat_log.sql` 建用量 log 表。

rate limit (每使用者,可用 env 調):

| env | 預設 | 意義 |
|---|---|---|
| `CHAT_RATE_WINDOW_MIN` | 5 | 滑動視窗分鐘數 |
| `CHAT_RATE_MAX` | 20 | 視窗內最多幾次 |
| `CHAT_DAILY_MAX` | 200 | 每人每日上限 |

超過回 429「太頻繁 / 今日已達上限」。fail-open:rate 檢查本身掛掉
不擋使用者 (避免 log 表故障 = 全公司不能問)。

每次 call 寫一筆 `medsec_chat_log` (user / prompt_chars / model / ok)。
manager 可在 SQL Editor 查用量 (檔尾有範例 query),或:

```sql
-- 今天每人問幾次 + 字數 (粗估成本)
SELECT p.nickname, count(*) calls, sum(c.prompt_chars) chars
FROM medsec_chat_log c JOIN profiles p ON p.id=c.user_id
WHERE c.created_at >= current_date
GROUP BY p.nickname ORDER BY calls DESC;
```

調 env 範例:
```bash
supabase secrets set CHAT_RATE_MAX=30 CHAT_DAILY_MAX=300
```

log 也在 Supabase Dashboard > Edge Functions > claude-chat > Logs。

### Troubleshooting

| 症狀 | 原因 | 修 |
|---|---|---|
| `500 ANTHROPIC_API_KEY missing` | 沒設 secret | `supabase secrets set ANTHROPIC_API_KEY=...` |
| `401 invalid_api_key` | key 錯 / 過期 | 去 console.anthropic.com 重產 |
| `400 model_not_found` | CLAUDE_MODEL 寫錯 | 改回 `claude-sonnet-4-6` |
| `429 rate_limit_exceeded` | 用太多 | 等 / 升 Anthropic plan |
| 前端 CORS 錯 | edge fn 沒回 CORS header | (本檔已處理) |
