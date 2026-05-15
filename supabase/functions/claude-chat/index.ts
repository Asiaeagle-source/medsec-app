// claude-chat — Supabase Edge Function
//
// 給 medsec-app rule-chat.html (V2 sprint 1 §3.3 模式 D 自由問答) 用。
// 前端 call 這支 → 我們服務端拿 ANTHROPIC_API_KEY call Claude → 回 JSON。
// 前端不放 API key (per V2 §6.2)。
//
// 部署:
//   supabase functions deploy claude-chat --no-verify-jwt=false
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//
// 安全:
//   - JWT 驗證 (--no-verify-jwt=false 預設) — 只認證使用者能 call
//   - 不對 user input 做任何資料庫查詢 (純 LLM relay)
//   - 醫院資料由前端先 query (走 RLS),再以 system prompt context 形式餵進來

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";

// 預設模型 (per claude-api skill 知識:Sonnet 4.6 是現行平衡選擇)
// 用環境變數 override:CLAUDE_MODEL
const DEFAULT_MODEL = "claude-sonnet-4-6";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ChatRequest {
  system?: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  max_tokens?: number;
  temperature?: number;
  // 預設關 thinking (V2.0 不需要,V2.1+ 評估)
  thinking?: { type: "enabled"; budget_tokens: number };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "method not allowed");
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    console.error("[claude-chat] ANTHROPIC_API_KEY not set");
    return errorResponse(500, "server config: ANTHROPIC_API_KEY missing");
  }

  let body: ChatRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid JSON body");
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return errorResponse(400, "messages required");
  }

  // --- rate limit + 用量 log (Lynn #3 防員工刷量爆成本) ---
  const userId = decodeJwtSub(req.headers.get("authorization"));
  const supaUrl = Deno.env.get("SUPABASE_URL");
  const svcKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const RATE_WINDOW_MIN = Number(Deno.env.get("CHAT_RATE_WINDOW_MIN") ?? 5);
  const RATE_MAX = Number(Deno.env.get("CHAT_RATE_MAX") ?? 20);
  const DAILY_MAX = Number(Deno.env.get("CHAT_DAILY_MAX") ?? 200);

  if (userId && supaUrl && svcKey) {
    try {
      const winIso = new Date(Date.now() - RATE_WINDOW_MIN * 60_000).toISOString();
      const dayIso = new Date(new Date().toISOString().slice(0, 10)).toISOString();
      const [winCount, dayCount] = await Promise.all([
        countLog(supaUrl, svcKey, userId, winIso),
        countLog(supaUrl, svcKey, userId, dayIso),
      ]);
      if (winCount >= RATE_MAX) {
        return errorResponse(429, `太頻繁:${RATE_WINDOW_MIN} 分鐘最多 ${RATE_MAX} 次,稍等再問`);
      }
      if (dayCount >= DAILY_MAX) {
        return errorResponse(429, `今日已達上限 ${DAILY_MAX} 次,明天再來`);
      }
    } catch (e) {
      console.warn("[claude-chat] rate check failed (fail-open)", e);
    }
  }

  const lastUserMsg = body.messages.filter((m) => m.role === "user").slice(-1)[0];
  const promptChars = lastUserMsg ? lastUserMsg.content.length : 0;
  const modelName = Deno.env.get("CLAUDE_MODEL") || DEFAULT_MODEL;

  const payload = {
    model: modelName,
    max_tokens: Math.min(body.max_tokens ?? 1024, 4096),
    temperature: body.temperature ?? 0.3,
    system: body.system,
    messages: body.messages,
    ...(body.thinking ? { thinking: body.thinking } : {}),
  };

  let resp: Response;
  try {
    resp = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    console.error("[claude-chat] fetch error", e);
    return errorResponse(502, `upstream fetch failed: ${e instanceof Error ? e.message : String(e)}`);
  }

  const respText = await resp.text();

  // 用量 log (fail-open:寫 log 失敗不影響回覆)
  if (userId && supaUrl && svcKey) {
    logCall(supaUrl, svcKey, {
      user_id: userId,
      prompt_chars: promptChars,
      model: modelName,
      ok: resp.ok,
      error_msg: resp.ok ? null : respText.slice(0, 300),
    }).catch((e) => console.warn("[claude-chat] log failed", e));
  }

  if (!resp.ok) {
    console.warn("[claude-chat] upstream error", resp.status, respText);
    return new Response(respText, {
      status: resp.status,
      headers: { ...CORS_HEADERS, "content-type": "application/json" },
    });
  }

  return new Response(respText, {
    status: 200,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
});

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: { type: "invalid_request_error", message } }), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
}

// JWT 已由 edge gateway 驗過 (--no-verify-jwt=false),這裡只 decode payload 取 sub
function decodeJwtSub(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const m = authHeader.match(/Bearer\s+(.+)/i);
  if (!m) return null;
  try {
    const payload = m[1].split(".")[1];
    const json = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
    return json.sub || null;
  } catch {
    return null;
  }
}

async function countLog(
  supaUrl: string,
  svcKey: string,
  userId: string,
  sinceIso: string,
): Promise<number> {
  const url = `${supaUrl}/rest/v1/medsec_chat_log?select=id&user_id=eq.${userId}&created_at=gte.${encodeURIComponent(sinceIso)}`;
  const r = await fetch(url, {
    headers: {
      apikey: svcKey,
      authorization: `Bearer ${svcKey}`,
      prefer: "count=exact",
      range: "0-0",
    },
  });
  // content-range: 0-0/<total>
  const cr = r.headers.get("content-range") || "";
  const total = cr.split("/")[1];
  return total ? parseInt(total, 10) : 0;
}

async function logCall(
  supaUrl: string,
  svcKey: string,
  row: Record<string, unknown>,
): Promise<void> {
  await fetch(`${supaUrl}/rest/v1/medsec_chat_log`, {
    method: "POST",
    headers: {
      apikey: svcKey,
      authorization: `Bearer ${svcKey}`,
      "content-type": "application/json",
      prefer: "return=minimal",
    },
    body: JSON.stringify(row),
  });
}
