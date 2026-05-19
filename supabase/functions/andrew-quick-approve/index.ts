// andrew-quick-approve — Supabase Edge Function (Sprint 2.5 第一批)
//
// Andrew(0001 林群雄, 老闆)不登入主 app。他從 email 連結進 andrew-review.html,
// 該頁呼叫本 fn。安全「全靠 HMAC 簽名 token」,不靠登入:
//   token 由 send-notification 用 NOTIFY_TOKEN_SECRET 簽,本 fn 驗。
//   token 綁 quote_id + 過期時間,過期或竄改一律 401。
//
// 部署(注意 --no-verify-jwt,因為 Andrew 沒 JWT):
//   supabase functions deploy andrew-quick-approve --no-verify-jwt
//   supabase secrets set NOTIFY_TOKEN_SECRET=<夠長的隨機字串>
//   (本 fn 另需 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY,Supabase 預設注入)
//
// action:
//   view          → 回 quote + items + advisories(給 andrew-review.html 顯示)
//   approve       → status=approved, reviewed_by=Andrew, 寫 timeline, 通知業祕
//   request_call  → 不改 status, 寫 timeline, 通知 Lynn「Andrew 想電話討論」

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// token 格式: "<exp>.<sigHex>",payload 簽的是 "<quoteId>.<exp>"
async function verifyToken(
  secret: string,
  quoteId: string,
  token: string,
): Promise<boolean> {
  const dot = token.indexOf(".");
  if (dot < 0) return false;
  const exp = token.slice(0, dot);
  const sig = token.slice(dot + 1);
  const expNum = Number(exp);
  if (!Number.isFinite(expNum) || Date.now() / 1000 > expNum) return false;
  const expect = await hmacHex(secret, `${quoteId}.${exp}`);
  return timingSafeEqual(expect, sig);
}

async function sb(
  path: string,
  init: RequestInit & { svc: string; url: string },
): Promise<Response> {
  return await fetch(`${init.url}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: init.svc,
      authorization: `Bearer ${init.svc}`,
      "content-type": "application/json",
      ...(init.headers || {}),
    },
  });
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const secret = Deno.env.get("NOTIFY_TOKEN_SECRET");
  const url = Deno.env.get("SUPABASE_URL");
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret || !url || !svc) {
    return json(500, { error: "server config missing (NOTIFY_TOKEN_SECRET / service role)" });
  }

  let body: { quote_id?: string; token?: string; action?: string; notes?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid JSON" });
  }
  const quoteId = body.quote_id || "";
  const token = body.token || "";
  const action = body.action || "view";
  if (!quoteId || !token) return json(400, { error: "quote_id + token required" });

  if (!(await verifyToken(secret, quoteId, token))) {
    return json(401, { error: "連結已過期或無效,請回覆 Lynn 重寄一次" });
  }

  // ---- view ----
  if (action === "view") {
    const qr = await sb(
      `medsec_quotes?id=eq.${quoteId}&select=id,hospital_id,quote_type,status,ai_suggested_total,ai_confidence,ai_reasoning,subtotal,manager_final_total`,
      { svc, url, method: "GET" },
    );
    const quote = (await qr.json())[0];
    if (!quote) return json(404, { error: "找不到報價" });
    const it = await sb(
      `medsec_quote_items?quote_id=eq.${quoteId}&select=product_code,product_name,quantity,list_price,ai_suggested_price`,
      { svc, url, method: "GET" },
    );
    const adv = await sb(
      `medsec_quote_advisories?quote_id=eq.${quoteId}&select=advisory_type,severity,message,created_at`,
      { svc, url, method: "GET" },
    );
    return json(200, {
      quote,
      items: await it.json(),
      advisories: await adv.json(),
    });
  }

  // 取 Andrew / Lynn profile id
  const andrew = (await (await sb(
    `profiles?employee_id=eq.0001&select=id`,
    { svc, url, method: "GET" },
  )).json())[0]?.id ?? null;

  if (action === "approve") {
    const patch = {
      status: "approved",
      reviewed_at: new Date().toISOString(),
      reviewed_by: andrew,
      manager_decision: "adopt",
      review_notes: body.notes || "Andrew 一鍵同意(email 連結)",
    };
    const up = await sb(`medsec_quotes?id=eq.${quoteId}`, {
      svc, url, method: "PATCH",
      headers: { prefer: "return=representation" },
      body: JSON.stringify(patch),
    });
    if (!up.ok) return json(502, { error: "更新失敗:" + (await up.text()).slice(0, 200) });
    const q = (await up.json())[0];
    await sb(`medsec_quote_timeline`, {
      svc, url, method: "POST",
      body: JSON.stringify({
        quote_id: quoteId, event_type: "approved", actor_id: andrew,
        from_status: "pending_andrew", to_status: "approved",
        notes: "Andrew 透過 email 連結直接同意",
      }),
    });
    // 通知業祕(submitted_by)
    if (q?.submitted_by) {
      await sb(`medsec_notifications`, {
        svc, url, method: "POST",
        body: JSON.stringify({
          recipient_id: q.submitted_by,
          notification_type: "quote_approved_for_secretary",
          reference_table: "medsec_quotes", reference_id: quoteId,
          title: "報價已拍板", body: "Andrew 已同意,請至報價優化填 CRM 單號",
          channel: ["in_app"], sent_at: new Date().toISOString(),
        }),
      });
    }
    return json(200, { ok: true, status: "approved" });
  }

  if (action === "request_call") {
    const lynn = (await (await sb(
      `profiles?employee_id=eq.0006&select=id`,
      { svc, url, method: "GET" },
    )).json())[0]?.id ?? null;
    await sb(`medsec_quote_timeline`, {
      svc, url, method: "POST",
      body: JSON.stringify({
        quote_id: quoteId, event_type: "andrew_wants_call", actor_id: andrew,
        notes: body.notes || "Andrew 想跟 Lynn 電話討論再決定",
      }),
    });
    if (lynn) {
      await sb(`medsec_notifications`, {
        svc, url, method: "POST",
        body: JSON.stringify({
          recipient_id: lynn,
          notification_type: "andrew_wants_call",
          reference_table: "medsec_quotes", reference_id: quoteId,
          title: "Andrew 想電話討論",
          body: `Andrew 想跟你電話討論報價 ${quoteId.slice(0, 8)}`,
          channel: ["in_app"], sent_at: new Date().toISOString(),
        }),
      });
    }
    return json(200, { ok: true, status: "request_call_sent" });
  }

  return json(400, { error: "unknown action" });
});
