// api/cron/mail-triage.js
// MedSec 信件分流 — 排程抓信 (Vercel Cron Function)
// 流程: Graph 抓當日新信 → classifyMail() 分流 → upsert 進 mail_digest

import { classifyMail } from "../../supabase/functions/mail-triage/rules.js";
// ↑ 路徑對齊 repo 裡 rules.js (classifyMail) 的實際位置, 不對就改這行
import { parseAttachment, sanitizeFilename, extOf, ALLOWED_EXT } from "./attachment-parser.js";

const ATTACH_BUCKET = "mail-attachments";
const MAX_ATT_BYTES = 10 * 1024 * 1024;   // 10MB 上限
const PER_MAIL_TIMEOUT_MS = 20000;         // 單信附件處理逾時 → 標 failed 跳過

// 逾時包裝:超過 ms 直接 reject,呼叫端 catch 後計 failed、不中斷主 triage。
function withTimeout(promise, ms, label = "timeout") {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${label} ${ms}ms`)), ms);
    promise.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

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
    `&$select=id,subject,from,receivedDateTime,bodyPreview,body,webLink,hasAttachments` +
    `&$top=100&$orderby=receivedDateTime desc`;

  // Prefer: 取純文字 body(不要 HTML),body.content 直接是 plain text。
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Prefer: 'outlook.body-content-type="text"' },
  });
  const data = await res.json();
  if (!data.value) throw new Error("Graph 抓信失敗: " + JSON.stringify(data));

  return data.value.map((m) => ({
    graphMessageId: m.id,
    receivedAt: m.receivedDateTime,
    subject: m.subject || "",
    senderName: m.from?.emailAddress?.name || "",
    senderEmail: m.from?.emailAddress?.address || "",
    snippet: (m.bodyPreview || "").slice(0, 400),
    bodyText: (m.body?.content || m.bodyPreview || "").slice(0, 10000),   // 純文字全文(截 10000)
    webLink: m.webLink || null,                                          // OWA 開信連結(PR B「開啟原信」用)
    hasAttachments: !!m.hasAttachments,
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
  "body_text",     // PR A:純文字全文(截 10000)
  "web_link",      // PR A:OWA 開信連結
  "needs_reply",   // PR A:是否需回覆
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

// ---- upsert 回傳(拿 mail_digest.id 對 graph_message_id,附件寫入要用)----
async function upsertDigestReturning(rows) {
  if (!rows.length) return [];
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/mail_digest?on_conflict=graph_message_id&select=id,graph_message_id`,
    {
      method: "POST",
      headers: {
        apikey: process.env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=representation",
      },
      body: JSON.stringify(rows),
    }
  );
  if (!res.ok) throw new Error("寫入 Supabase 失敗: " + (await res.text()));
  return await res.json();   // [{ id, graph_message_id }]
}

// ---- 附件上傳 private bucket(service role;x-upsert 讓 cron 重跑覆蓋同檔)----
async function uploadToStorage(path, buffer, contentType) {
  const res = await fetch(
    `${process.env.SUPABASE_URL}/storage/v1/object/${ATTACH_BUCKET}/${encodeURI(path)}`,
    {
      method: "POST",
      headers: {
        apikey: process.env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}`,
        "Content-Type": contentType || "application/octet-stream",
        "x-upsert": "true",
      },
      body: buffer,
    }
  );
  if (!res.ok) throw new Error("storage 上傳失敗: " + res.status + " " + (await res.text()));
}

// ---- mail_attachments upsert(service role;on_conflict (mail_digest_id, filename) 防重跑重複)----
const ATT_KEYS = ["mail_digest_id","filename","storage_path","file_kind","parse_status","items","parse_error","size_bytes","content_type"];
async function upsertAttachment(row) {
  const obj = {}; for (const k of ATT_KEYS) obj[k] = row[k] !== undefined ? row[k] : null;
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/mail_attachments?on_conflict=mail_digest_id,filename`,
    {
      method: "POST",
      headers: {
        apikey: process.env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify([obj]),
    }
  );
  if (!res.ok) throw new Error("mail_attachments upsert 失敗: " + (await res.text()));
}

// 拉某封信的附件並逐一入庫 + 解析。stats 就地累加(found/parsed/scanned/failed)。
async function processMailAttachments(token, messageId, digestId, stats) {
  const mailbox = process.env.GRAPH_MAILBOX;
  const url = `https://graph.microsoft.com/v1.0/users/${mailbox}/messages/${messageId}/attachments`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json();
  if (!Array.isArray(data.value)) return;

  for (const att of data.value) {
    // 只處理檔案附件;略過 inline(簽名圖等)與 >10MB
    if (att["@odata.type"] && !/fileAttachment/i.test(att["@odata.type"])) continue;
    if (att.isInline) continue;
    if (typeof att.size === "number" && att.size > MAX_ATT_BYTES) continue;

    stats.found++;
    const filename = att.name || "attachment";
    const ext = extOf(filename);
    const safe = sanitizeFilename(filename);
    const path = `${digestId}/${safe}`;

    // 非白名單副檔名 → 記錄一列 skipped(不上傳、不解析)
    if (!ALLOWED_EXT.includes(ext)) {
      await upsertAttachment({ mail_digest_id: digestId, filename, storage_path: null, file_kind: "other",
        parse_status: "skipped", items: [], parse_error: null, size_bytes: att.size ?? null, content_type: att.contentType || null });
      continue;
    }

    const buffer = Buffer.from(att.contentBytes || "", "base64");
    await uploadToStorage(path, buffer, att.contentType);          // 原檔進 bucket
    const parsed = await parseAttachment({ buffer, filename });    // 解析品項
    if (parsed.parse_status === "ok") stats.parsed++;
    else if (parsed.parse_status === "scanned_needs_manual") stats.scanned++;
    else if (parsed.parse_status === "failed") stats.failed++;

    await upsertAttachment({
      mail_digest_id: digestId, filename, storage_path: path,
      file_kind: parsed.file_kind, parse_status: parsed.parse_status,
      items: parsed.items || [], parse_error: parsed.parse_error || null,
      size_bytes: att.size ?? buffer.length, content_type: att.contentType || null,
    });
  }
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

    // 分類:同時記住每封的 priority(判斷是不是 order 桶)與 graphMessageId(拉附件)
    const classified = [];
    for (const mail of mails) {
      try {
        const r = await classifyMail(mail);   // 已含 body_text / web_link / needs_reply
        resolveAssignedTo(r, empMap);         // 員編 → uuid;查不到落 null
        classified.push({ mail, row: normalizeDigest(r), priority: r.priority });
      } catch (e) {
        // 分類失敗 → 落到 fallback,仍走 normalizeDigest 補齊空欄(key 集合一致,避免 PGRST102)。
        const row = normalizeDigest({
          graph_message_id: mail.graphMessageId,
          received_at: mail.receivedAt,
          sender_email: mail.senderEmail,
          sender_name: mail.senderName,
          subject: mail.subject,
          ai_summary: "(分類失敗, 請人工確認)",
          priority: "amber",
          category: "其他",
          body_text: mail.bodyText ? String(mail.bodyText).slice(0, 10000) : null,
          web_link: mail.webLink || null,
          needs_reply: false,
        });
        classified.push({ mail, row, priority: "amber" });
      }
    }

    // upsert 並取回 id(附件寫入要對 mail_digest_id)
    const digestRows = await upsertDigestReturning(classified.map((c) => c.row));
    const idByGraph = new Map(digestRows.map((d) => [d.graph_message_id, d.id]));

    // 附件:只處理 order 桶。整段 try-catch + 單信 20 秒逾時,任何失敗都不中斷主 triage。
    const att = { found: 0, parsed: 0, scanned: 0, failed: 0 };
    for (const c of classified) {
      if (c.priority !== "order") continue;
      if (c.mail.hasAttachments === false) continue;         // Graph 明確說沒附件就跳過(省一次呼叫)
      const digestId = idByGraph.get(c.mail.graphMessageId);
      if (!digestId) continue;
      try {
        await withTimeout(processMailAttachments(token, c.mail.graphMessageId, digestId, att), PER_MAIL_TIMEOUT_MS, "單信附件逾時");
      } catch (e) {
        att.failed++;   // 逾時或整段失敗 → 標 failed 跳過,不影響其他信
      }
    }

    return res.status(200).json({
      scanned: mails.length, written: digestRows.length, since, days, folders: folderStats,
      attachments_found: att.found, parsed: att.parsed, scanned_needs_manual: att.scanned, attachments_failed: att.failed,
    });
  } catch (e) {
    return res.status(500).json({ error: String(e) });
  }
}
