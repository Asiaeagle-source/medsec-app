// send-notification — Supabase Edge Function (Sprint 2.5 第一批)
//
// 寫 medsec_notifications(service role)+ 視 channel 寄 Email(Resend)。
// 呼叫者要登入(Lynn / 業祕),走預設 JWT 驗證。
//
// 部署:
//   supabase functions deploy send-notification
//   supabase secrets set NOTIFY_TOKEN_SECRET=<與 andrew-quick-approve 同一把>
//   supabase secrets set RESEND_API_KEY=re_xxx
//   supabase secrets set RESEND_FROM="AE MED Hub <noreply@yourdomain>"
//   supabase secrets set ANDREW_EMAIL=andrew@example.com
//   supabase secrets set REVIEW_BASE_URL=https://<vercel-domain>
//   (沒設 RESEND_* 時 email 靜默略過,in_app 通知仍會寫 — fail-open)
//
// body: { type, quote_id }
//   type: quote_submitted_for_lynn | quote_pending_andrew | quote_approved_for_secretary

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS, "content-type": "application/json" },
  });
}

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sb(url: string, svc: string, path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${url}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: svc, authorization: `Bearer ${svc}`,
      "content-type": "application/json", ...(init.headers || {}),
    },
  });
}

async function getProfileId(url: string, svc: string, emp: string): Promise<string | null> {
  const r = await sb(url, svc, `profiles?employee_id=eq.${emp}&select=id`, { method: "GET" });
  return (await r.json())[0]?.id ?? null;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !svc) return json(500, { error: "service role config missing" });

  let body: { type?: string; quote_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "invalid JSON" }); }
  const type = body.type || "";
  const quoteId = body.quote_id || "";
  if (!type || !quoteId) return json(400, { error: "type + quote_id required" });

  const qr = await sb(url, svc,
    `medsec_quotes?id=eq.${quoteId}&select=id,hospital_id,quote_type,status,ai_suggested_total,manager_final_total,submitted_by`,
    { method: "GET" });
  const quote = (await qr.json())[0];
  if (!quote) return json(404, { error: "找不到報價" });

  const inserts: Record<string, unknown>[] = [];
  let emailTo: string | null = null;
  let emailSubject = "";
  let emailHtml = "";

  if (type === "quote_submitted_for_lynn") {
    const lynn = await getProfileId(url, svc, "0006");
    if (lynn) {
      inserts.push({
        recipient_id: lynn, notification_type: type,
        reference_table: "medsec_quotes", reference_id: quoteId,
        title: "有報價待你審核",
        body: `${quote.hospital_id} · 業祕已送審,請至報價決策`,
        channel: ["in_app"], sent_at: new Date().toISOString(),
      });
    }
  } else if (type === "quote_approved_for_secretary") {
    if (quote.submitted_by) {
      inserts.push({
        recipient_id: quote.submitted_by, notification_type: type,
        reference_table: "medsec_quotes", reference_id: quoteId,
        title: "報價已拍板",
        body: `${quote.hospital_id} 已拍板,請至報價優化填 CRM 單號`,
        channel: ["in_app"], sent_at: new Date().toISOString(),
      });
    }
  } else if (type === "quote_pending_andrew") {
    const secret = Deno.env.get("NOTIFY_TOKEN_SECRET");
    const base = Deno.env.get("REVIEW_BASE_URL") || "";
    const ttlDays = Number(Deno.env.get("TOKEN_TTL_DAYS") ?? 7);
    if (!secret) return json(500, { error: "NOTIFY_TOKEN_SECRET missing" });
    const exp = Math.floor(Date.now() / 1000) + ttlDays * 86400;
    const sig = await hmacHex(secret, `${quoteId}.${exp}`);
    const token = `${exp}.${sig}`;
    const actionUrl = `${base}/andrew-review.html?quote_id=${quoteId}&token=${token}`;
    const andrew = await getProfileId(url, svc, "0001");
    inserts.push({
      recipient_id: andrew, notification_type: type,
      reference_table: "medsec_quotes", reference_id: quoteId,
      title: `Lynn 請您確認:${quote.hospital_id} 報價`,
      body: "點連結看品項與 Lynn 建議價,可一鍵同意或請 Lynn 電話討論",
      action_url: actionUrl, channel: ["email", "in_app"],
      sent_at: new Date().toISOString(),
    });
    emailTo = Deno.env.get("ANDREW_EMAIL") || null;
    emailSubject = `Lynn 請您確認報價:${quote.hospital_id}`;
    emailHtml =
      `<p>Lynn 請您確認一筆報價(${quote.hospital_id})。</p>` +
      `<p>建議拍板總額:<b>${quote.manager_final_total ?? quote.ai_suggested_total ?? "—"}</b></p>` +
      `<p><a href="${actionUrl}">點此查看並決定(同意 / 請 Lynn 電話討論)</a></p>` +
      `<p style="color:#888;font-size:12px">連結 ${ttlDays} 天內有效,僅本報價可用。</p>`;
  } else {
    return json(400, { error: "unknown type" });
  }

  for (const row of inserts) {
    await sb(url, svc, "medsec_notifications", {
      method: "POST", headers: { prefer: "return=minimal" },
      body: JSON.stringify(row),
    }).catch((e) => console.warn("[send-notification] insert failed", e));
  }

  // Email(fail-open)
  let emailed = false;
  if (emailTo) {
    const rk = Deno.env.get("RESEND_API_KEY");
    const from = Deno.env.get("RESEND_FROM");
    if (rk && from) {
      try {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { authorization: `Bearer ${rk}`, "content-type": "application/json" },
          body: JSON.stringify({ from, to: emailTo, subject: emailSubject, html: emailHtml }),
        });
        emailed = r.ok;
        if (!r.ok) console.warn("[send-notification] resend", r.status, (await r.text()).slice(0, 200));
      } catch (e) {
        console.warn("[send-notification] resend error", e);
      }
    } else {
      console.warn("[send-notification] RESEND_* 未設,email 略過(in_app 已寫)");
    }
  }

  return json(200, { ok: true, notified: inserts.length, emailed });
});
