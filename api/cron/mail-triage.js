// api/cron/mail-triage.js
// MedSec 信件分流 — 排程抓信 (Vercel Cron Function)
// 流程: Graph 抓當日新信 → classifyMail() 分流 → upsert 進 mail_digest

import { classifyMail } from "../../supabase/functions/mail-triage/rules.js";
// ↑ 路徑對齊 repo 裡 rules.js (classifyMail) 的實際位置, 不對就改這行

// ---- 1. 拿 Graph access token (client credentials) ----
async function getGraphToken() {
  const res = await fetch(
    `https://login.microsoftonline.com/${process.env.GRAPH_TENANT_ID}/oauth2/v2.0/token`,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: process.env.GRAPH_CLIENT_ID,
        client_secret: process.env.GRAPH_CLIENT_SECRET,
        scope: "https://graph.microsoft.com/.default",
        grant_type: "client_credentials",
      }),
    }
  );
  const data = await res.json();
  if (!data.access_token) throw new Error("Graph token 失敗: " + JSON.stringify(data));
  return data.access_token;
}

// ---- 2. 抓「上次掃描之後」的新信 ----
// 只取 寄件者/主旨/收到時間/內文前段, 不抓全文。
// folderId 可以是 well-known 名稱 (例如 'inbox') 或 Graph 回傳的 folder id。
async function fetchNewMail(token, folderId, sinceISO) {
  const mailbox = process.env.GRAPH_MAILBOX;
  const url =
    `https://graph.microsoft.com/v1.0/users/${mailbox}/mailFolders/${folderId}/messages` +
    `?$filter=receivedDateTime ge ${sinceISO}` +
    `&$select=id,subject,from,receivedDateTime,bodyPreview` +
    `&$top=100&$orderby=receivedDateTime desc`;

  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  if (!data.value) throw new Error("Graph 抓信失敗: " + JSON.stringify(data));

  return data.value.map((m) => ({
    graphMessageId: m.id,
    receivedAt: m.receivedDateTime,
    subject: m.subject || "",
    senderName: m.from?.emailAddress?.name || "",
    senderEmail: m.from?.emailAddress?.address || "",
    snippet: (m.bodyPreview || "").slice(0, 400),
  }));
}

// 用 displayName 查 inbox 底下的子資料夾 id;查不到回 null。
// OData 字串裡 ' 用 '' 脫逸;URL 整段交給 URL constructor 編碼。
async function getInboxChildFolderId(token, displayName) {
  const mailbox = process.env.GRAPH_MAILBOX;
  const safe = displayName.replace(/'/g, "''");
  const url = new URL(
    `https://graph.microsoft.com/v1.0/users/${mailbox}/mailFolders/inbox/childFolders`
  );
  url.searchParams.set("$filter", `displayName eq '${safe}'`);
  url.searchParams.set("$select", "id,displayName");
  url.searchParams.set("$top", "1");
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  if (!res.ok || !data.value || !data.value.length) return null;
  return data.value[0].id;
}

// ---- 3. upsert 進 Supabase (graph_message_id 唯一, 重跑不重複) ----
// 注意: 新版 sb_secret_ 格式 key, apikey 與 Bearer 都帶同一把
// PostgREST 批次 upsert 要求每筆物件 key 集合完全一致 (否則 PGRST102
// 「All object keys must match」),所以寫入前統一 normalize 一次。
const DIGEST_KEYS = [
  "graph_message_id",
  "received_at",
  "sender_email",
  "sender_name",
  "subject",
  "ai_summary",
  "priority",
  "category",
  "flag_reason",
  "deadline",
  "hospital_id",
  "assigned_to",   // v3:rules 給 employee_id 字串 → 寫入前由 employeeIdToUuid map 轉成 profiles.id (uuid);客戶→null 由 hospital_id 帶業秘
];
function normalizeDigest(row) {
  const out = {};
  for (const k of DIGEST_KEYS) out[k] = row[k] !== undefined ? row[k] : null;
  return out;
}

// ---- profiles 員編 → uuid 對照 ----
// rules.js classifyMail 回傳的 assigned_to 是員編字串 ("0003"/"0015"/"0132"/"0176"),
// 但 mail_digest.assigned_to 是 uuid FK→profiles.id,直接寫字串會 22P02。
// cron 啟動時拉一次 profiles(全公司不多,~60 列),建 employee_id→id map。
async function loadEmployeeMap() {
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/profiles?select=id,employee_id&employee_id=not.is.null`,
    { headers: { apikey: process.env.SUPABASE_SERVICE_KEY, Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}` } }
  );
  if (!res.ok) throw new Error("loadEmployeeMap 失敗: " + (await res.text()));
  const rows = await res.json();
  const map = {};
  for (const r of (rows || [])) {
    const k = String(r.employee_id || '').trim();
    if (k) map[k] = r.id;
  }
  return map;
}

// 把 row.assigned_to 從員編字串轉成 uuid;map 查不到就 null(別硬塞字串)。
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function resolveAssignedTo(row, empMap) {
  const v = row.assigned_to;
  if (v == null) return row;            // null / undefined 維持
  const s = String(v).trim();
  if (UUID_RE.test(s)) { row.assigned_to = s; return row; }   // 已是 uuid 直接過
  row.assigned_to = empMap[s] || null;   // 員編 → uuid,查不到落 null
  return row;
}

async function upsertDigest(rows) {
  if (!rows.length) return 0;
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/mail_digest?on_conflict=graph_message_id`,
    {
      method: "POST",
      headers: {
        apikey: process.env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify(rows),
    }
  );
  if (!res.ok) throw new Error("寫入 Supabase 失敗: " + (await res.text()));
  return rows.length;
}

// ---- 主入口 ----
export default async function handler(req, res) {
  if (req.headers["authorization"] !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  try {
    // 啟動時平行拉:Graph token + profiles 員編→uuid map(後面 assigned_to 用)
    const [token, empMap] = await Promise.all([
      getGraphToken(),
      loadEmployeeMap(),
    ]);
    // 預設回看 24 小時(Hobby 一天跑一次,避免漏信);
    // 帶 ?days=7 可加大視窗(首次回填、補跑用)。
    const daysRaw = Number(req.query?.days);
    const days = Number.isFinite(daysRaw) && daysRaw > 0 ? Math.min(daysRaw, 90) : 1;
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();

    // 三個資料夾:inbox + inbox/子資料夾 Lynn.lai + inbox/子資料夾 service。
    // 每個都帶 $filter=receivedDateTime ge since,絕對不要無時間 filter
    // 全抓 —— service 有六萬多封歷史信。
    const [lynnId, serviceId] = await Promise.all([
      getInboxChildFolderId(token, "Lynn.lai"),
      getInboxChildFolderId(token, "service"),
    ]);
    const targets = [
      { name: "inbox",    id: "inbox" },
      { name: "Lynn.lai", id: lynnId },
      { name: "service",  id: serviceId },
    ];
    const folderStats = {};
    const merged = new Map();   // graphMessageId → mail (defensive dedup)
    for (const t of targets) {
      if (!t.id) { folderStats[t.name] = "folder not found"; continue; }
      try {
        const arr = await fetchNewMail(token, t.id, since);
        folderStats[t.name] = arr.length;
        for (const m of arr) merged.set(m.graphMessageId, m);
      } catch (e) {
        folderStats[t.name] = `error: ${e.message || e}`;
      }
    }
    const mails = [...merged.values()];

    const rows = [];
    for (const mail of mails) {
      try {
        const r = await classifyMail(mail);
        resolveAssignedTo(r, empMap);   // 員編 → uuid;查不到落 null
        rows.push(normalizeDigest(r));
      } catch (e) {
        // 分類失敗 → 落到 fallback,仍然走 normalizeDigest 補齊空欄,
        // 確保跟成功路徑 key 集合一致(避免 PGRST102)。
        rows.push(normalizeDigest({
          graph_message_id: mail.graphMessageId,
          received_at: mail.receivedAt,
          sender_email: mail.senderEmail,
          sender_name: mail.senderName,
          subject: mail.subject,
          ai_summary: "(分類失敗, 請人工確認)",
          priority: "amber",
          category: "其他",
          // flag_reason / deadline / hospital_id / assigned_to 由 normalizeDigest 補 null
        }));
      }
    }
    const n = await upsertDigest(rows);
    return res.status(200).json({ scanned: mails.length, written: n, since, days, folders: folderStats });
  } catch (e) {
    return res.status(500).json({ error: String(e) });
  }
}
