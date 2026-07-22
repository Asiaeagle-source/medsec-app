// ============================================================
// scripts/verify_scan_paging.mjs — 掃描分頁驗收腳本(免外部依賴)
// 執行:node scripts/verify_scan_paging.mjs(Node 18+,repo 根目錄)
// 驗:@odata.nextLink 逐頁掃全(service 250 封 3 頁)、穩態單頁不受影響、
//     掃描預算截斷 → scan_truncated + partial、頁數上限防失控。
// 全 mock(Graph/Supabase/Anthropic),不碰真環境。
// ============================================================
process.env.CRON_SECRET = "s"; process.env.GRAPH_TENANT_ID = "t";
process.env.GRAPH_CLIENT_ID = "c"; process.env.GRAPH_CLIENT_SECRET = "x";
process.env.GRAPH_MAILBOX = "m@x.com"; process.env.SUPABASE_URL = "https://db.test";
process.env.SUPABASE_SERVICE_KEY = "k"; process.env.ANTHROPIC_API_KEY = "a";

const NOW = Date.now();
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const mkMail = (id, i) => ({
  id, receivedDateTime: iso(10 + i), subject: `信 ${id}`,
  from: { emailAddress: { name: "寄", address: "a@ntuh.gov.tw" } },
  bodyPreview: "p", body: { content: "內文" }, webLink: "w", hasAttachments: false,
});
const J = (o) => ({ ok: true, status: 200, json: async () => o, text: async () => JSON.stringify(o) });

// service 桶 250 封 → 3 頁(100/100/50);inbox 20 封單頁
const state = { pagesFetched: [] };
function servicePage(n) {
  const start = n * 100, cnt = Math.min(100, 250 - start);
  const value = Array.from({ length: cnt }, (_, i) => mkMail(`svc-${start + i}`, start + i));
  const next = start + cnt < 250 ? `https://graph.microsoft.com/v1.0/next/service?page=${n + 1}` : undefined;
  return { value, ...(next ? { "@odata.nextLink": next } : {}) };
}
globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  if (u.includes("anthropic")) return J({ content: [{ type: "text", text: '{"summary":"x","hospital":null}' }] });
  if (u.includes("login.microsoftonline.com")) return J({ access_token: "tok" });
  if (u.includes("/rest/v1/profiles")) return J([]);
  if (u.includes("/mailFolders/inbox/childFolders")) {
    const name = decodeURIComponent(u).includes("service") ? "svc-folder" : "lynn-folder";
    return J({ value: [{ id: name, displayName: name }] });
  }
  if (u.includes("/next/service")) {                                 // nextLink 續頁
    const n = Number(new URL(u).searchParams.get("page"));
    state.pagesFetched.push(`svc-p${n}`);
    return J(servicePage(n));
  }
  if (u.includes("svc-folder/messages")) {                           // service 第 1 頁
    state.pagesFetched.push("svc-p0");
    return J(servicePage(0));
  }
  if (u.includes("lynn-folder/messages")) return J({ value: [] });
  if (u.includes("/mailFolders/inbox/messages"))
    return J({ value: Array.from({ length: 20 }, (_, i) => mkMail(`in-${i}`, i)) });   // inbox 單頁,無 nextLink
  if (u.includes("/rest/v1/mail_digest?select=")) {
    // 已入庫:svc-0..svc-239 與 inbox 全部(模擬前幾發已消化,只剩 svc-240..249 是新信)
    const rows = [];
    for (let i = 0; i < 240; i++) rows.push({ id: `d-${i}`, graph_message_id: `svc-${i}`, priority: "amber" });
    for (let i = 0; i < 20; i++) rows.push({ id: `di-${i}`, graph_message_id: `in-${i}`, priority: "amber" });
    return J(rows);
  }
  if (u.includes("/rest/v1/mail_attachments?select=")) return J([]);
  if (u.includes("/rest/v1/mail_digest")) {
    const rows = JSON.parse(opts.body);
    return J(rows.map((r, i) => ({ id: "new-" + i, graph_message_id: r.graph_message_id })));
  }
  return J({});
};

const { default: handler } = await import("../api/cron/mail-triage.js");
async function run(q) {
  let out = null;
  const res = { status(c) { this._c = c; return this; }, json(o) { out = o; return this; } };
  await handler({ headers: { authorization: "Bearer s" }, query: q }, res);
  return out;
}
let fails = 0;
const t = (n, c, x = "") => { if (!c) fails++; console.log(`${c ? "✓" : "✗"} ${n}${c ? "" : "  [" + x + "]"}`); };

// ---- 案 1:3 頁掃全(修 bug 主案)----
let r = await run({ days: 3 });
t("service 3 頁全跟到(p0/p1/p2)", JSON.stringify(state.pagesFetched) === '["svc-p0","svc-p1","svc-p2"]', JSON.stringify(state.pagesFetched));
t("scanned = 270(250 service + 20 inbox,不再卡 100)", r.scanned === 270, "scanned=" + r.scanned);
t("folderStats service = 250", JSON.stringify(r.folders).includes("250"), JSON.stringify(r.folders));
t("只分類新 10 封(svc-240..249)", r.classified === 10, "classified=" + r.classified);
t("scan_truncated = false / partial = false", r.scan_truncated === false && r.partial === false, JSON.stringify({ st: r.scan_truncated, p: r.partial }));

// ---- 案 2:截斷路徑 —— 永遠有 nextLink 的資料夾撞 SCAN_MAX_PAGES=10 停下,
// 標 scan_truncated + partial(續作重打會繼續掃;時間預算截斷走同一分支)。
let bigPages = 0;
const bigPage = (n) => {
  const value = Array.from({ length: 100 }, (_, i) => mkMail(`big-${n * 100 + i}`, i));
  return { value, "@odata.nextLink": `https://graph.microsoft.com/v1.0/next/service?page=${n + 1}` };  // 永遠有下一頁
};
const origFetch = globalThis.fetch;
globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  if (u.includes("/next/service") || u.includes("svc-folder/messages")) {
    bigPages++;
    const n = u.includes("page=") ? Number(new URL(u).searchParams.get("page")) : 0;
    return J(bigPage(n));
  }
  if (u.includes("lynn-folder/messages") || u.includes("/mailFolders/inbox/messages")) return J({ value: [] });
  if (u.includes("/rest/v1/mail_digest?select=")) {
    const rows = [];
    for (let i = 0; i < 1000; i++) rows.push({ id: `d-${i}`, graph_message_id: `big-${i}`, priority: "amber" });
    return J(rows);
  }
  return origFetch(url, opts);
};
r = await run({ days: 3 });
t("頁數上限:恰停在 10 頁(1000 封)", bigPages === 10, "pages=" + bigPages);
t("截斷 → scan_truncated = true", r.scan_truncated === true, JSON.stringify(r.scan_truncated));
t("截斷 → partial = true(續作會繼續掃)", r.partial === true);
t("folderStats 帶截斷標記", JSON.stringify(r.folders).includes("截斷"), JSON.stringify(r.folders));

console.log(fails ? `\n${fails} FAIL` : "\nALL PASS(掃描分頁驗收通過)");
process.exit(fails ? 1 : 0);
