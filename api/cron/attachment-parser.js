// api/cron/attachment-parser.js
// MedSec 訂單附件解析 — 由 mail-triage cron 呼叫(只在 order 桶信件用)
// ------------------------------------------------------------
// 支援 CSV / XLSX / XLS / PDF。
//   CSV  : iconv-lite 先試 big5(大量 U+FFFD 才 fallback utf-8)→ papaparse → 欄位對映
//   XLSX : SheetJS 讀第一個非空 sheet → 同 CSV 欄位對映邏輯
//   PDF  : pdf.js 抽文字;<50 字 → 掃描件(不呼叫 AI);≥50 字 → Anthropic haiku 抽品項
//
// ⚠️ Vercel serverless 相容性(FUNCTION_INVOCATION_FAILED 教訓):
//   * 解析套件一律「函式內 lazy import + 靜態字串」——頂層 import 一旦在
//     bundler 環境載不進來,整台 function 每次呼叫都炸;lazy 化之後最多該附件
//     標 failed,import 錯誤原文進 parse_error(DB 可查)。
//   * 不用 pdf-parse 的 loader(lib/pdf-parse.js 內部是 computed require
//     `./pdf.js/${version}/build/pdf.js`,nft/esbuild 追不到)——改直接
//     import 它內附的 pdf.js build(靜態路徑),文字抽取自己做(同其 render 邏輯)。
//
// 純字串/資料函式(mapHeaders / mapRows / extractJsonArray / sanitizeFilename …)
// 保持頂層無依賴,方便單元測試。
// ============================================================

// TODO(V2.3 寄賣對帳):.txt 加入白名單當 CSV 解析(big5→utf8 同邏輯)——
// 高雄榮總每日消耗檔是 tab/逗號分隔 .txt,是寄賣對帳的天然資料源。
export const ALLOWED_EXT = [".csv", ".xlsx", ".xls", ".pdf"];

// ---- lazy loaders(靜態 specifier;快取 promise,一次載入)----
const _mods = {};
function loadMod(key, loader) {
  if (!_mods[key]) _mods[key] = loader();
  return _mods[key];
}
const getIconv = () => loadMod("iconv", async () => (await import("iconv-lite")).default);
const getPapa  = () => loadMod("papa",  async () => { const m = await import("papaparse"); return m.default ?? m; });
const getXlsx  = () => loadMod("xlsx",  async () => { const m = await import("xlsx"); return m.default ?? m; });
// pdf.js v1.10.100 build(pdf-parse 內附;靜態路徑,bundler 可追蹤)
const getPdfjs = () => loadMod("pdfjs", async () => {
  const m = await import("pdf-parse/lib/pdf.js/v1.10.100/build/pdf.js");
  return m.default ?? m;
});

// ---- 檔名 / 副檔名 ----
export function extOf(name) {
  const m = /\.[^.\/\\]+$/.exec(String(name || ""));
  return m ? m[0].toLowerCase() : "";
}
// 檔名清洗:去非法字元(storage path 與 OS 都安全),保留中英數與底線,限長。
export function sanitizeFilename(name) {
  let s = String(name == null ? "" : name).normalize("NFC");
  s = s.replace(/[\/\\?%*:|"<> -]/g, "_");   // 路徑/控制字元
  s = s.replace(/\s+/g, "_").replace(/_+/g, "_").replace(/^[_.]+|[_.]+$/g, "");
  if (!s) s = "file";
  return s.slice(0, 180);
}
// Storage 專用 key:全 ASCII(Supabase storage key 帶中文會 InvalidKey)。
// 規則:base 去非 ASCII 後保留殘餘;曾含非 ASCII(或殘餘為空)則綴上
// 原始檔名的 hash8 保唯一;副檔名保留(小寫)。同名必得同 key —— deterministic,
// 重跑 x-upsert 覆蓋同檔。原始中文檔名照存 DB filename 欄供顯示,不受影響。
export function storageSafeName(name) {
  const raw = String(name == null ? "" : name).normalize("NFC");
  const ext = extOf(raw);                                        // ".pdf"(小寫)
  const base = ext ? raw.slice(0, raw.length - ext.length) : raw;
  let ascii = base.replace(/[^A-Za-z0-9._-]+/g, "_")
    .replace(/_+/g, "_").replace(/^[_.]+|[_.]+$/g, "").slice(0, 80);
  const needHash = /[^\x00-\x7F]/.test(raw) || !ascii;
  if (!needHash) return ascii + ext;
  let h = 5381;                                                  // djb2 over 原始檔名
  for (let i = 0; i < raw.length; i++) h = ((h * 33) ^ raw.charCodeAt(i)) >>> 0;
  const h8 = h.toString(16).padStart(8, "0");
  return (ascii ? ascii + "_" : "") + h8 + ext;
}

// ---- 欄位關鍵字對映 ----
const HEADER_MAP = [
  { key: "item_code",   kws: ["品號", "物料碼", "料號", "條碼"] },
  { key: "item_name",   kws: ["品名", "名稱"] },
  { key: "qty",         kws: ["數量", "訂購量"] },
  { key: "contract_no", kws: ["合約", "案號"] },
];
// header 列 → { fieldKey: colIndex };每欄取第一個命中的欄位。
export function mapHeaders(headerRow) {
  const out = {};
  (headerRow || []).forEach((h, i) => {
    const s = String(h == null ? "" : h).trim();
    if (!s) return;
    for (const { key, kws } of HEADER_MAP) {
      if (out[key] === undefined && kws.some((k) => s.includes(k))) out[key] = i;
    }
  });
  return out;
}
export function mapRows(rows, hmap) {
  const items = [];
  for (const row of rows || []) {
    const get = (k) => (hmap[k] !== undefined ? String(row[hmap[k]] == null ? "" : row[hmap[k]]).trim() : "");
    const item_code = get("item_code"), item_name = get("item_name");
    const qtyRaw = get("qty"), contract_no = get("contract_no");
    if (!item_code && !item_name) continue;   // 整列無品號無品名 → 空列跳過
    let qty = null;
    if (qtyRaw !== "") { const n = Number(qtyRaw.replace(/,/g, "")); qty = Number.isFinite(n) ? n : qtyRaw; }
    items.push({
      item_code: item_code || null,
      item_name: item_name || null,
      qty,
      contract_no: contract_no || null,
    });
  }
  return items;
}

// ---- CSV ----
// big5 先解;U+FFFD 過多(絕對>5 個 或 佔比>2%)才判為非 big5 → 改 utf-8。
export async function decodeBuffer(buf) {
  const iconv = await getIconv();
  let s = iconv.decode(buf, "big5");
  const bad = (s.match(/�/g) || []).length;
  if (bad > 5 || bad / Math.max(s.length, 1) > 0.02) s = iconv.decode(buf, "utf8");
  return s;
}
export async function parseCsv(buf) {
  const Papa = await getPapa();
  const text = await decodeBuffer(Buffer.isBuffer(buf) ? buf : Buffer.from(buf));
  const parsed = Papa.parse(text.replace(/^﻿/, "").trim(), { skipEmptyLines: true });
  const rows = parsed.data || [];
  if (!rows.length) return { items: [] };
  const hmap = mapHeaders(rows[0]);
  return { items: mapRows(rows.slice(1), hmap) };
}

// ---- XLSX / XLS ----
export async function parseXlsx(buf) {
  const XLSX = await getXlsx();
  const wb = XLSX.read(Buffer.isBuffer(buf) ? buf : Buffer.from(buf), { type: "buffer" });
  let rows = null;
  for (const name of wb.SheetNames) {                 // 第一個非空 sheet
    const arr = XLSX.utils.sheet_to_json(wb.Sheets[name], { header: 1, blankrows: false, defval: "" });
    if (arr && arr.length) { rows = arr; break; }
  }
  if (!rows || !rows.length) return { items: [] };
  const hmap = mapHeaders(rows[0]);
  return { items: mapRows(rows.slice(1), hmap) };
}

// ---- PDF 文字抽取(pdf.js 直用;同 pdf-parse render_page 的換行邏輯)----
export async function pdfToText(buf) {
  const PDFJS = await getPdfjs();
  PDFJS.disableWorker = true;
  const u8 = Buffer.isBuffer(buf) ? new Uint8Array(buf) : new Uint8Array(Buffer.from(buf));
  const doc = await PDFJS.getDocument(u8);
  let text = "";
  try {
    for (let i = 1; i <= doc.numPages; i++) {
      const page = await doc.getPage(i);
      const tc = await page.getTextContent({ normalizeWhitespace: false, disableCombineTextItems: false });
      let lastY = null, pageText = "";
      for (const item of tc.items) {
        if (lastY === item.transform[5] || lastY === null) pageText += item.str;
        else pageText += "\n" + item.str;
        lastY = item.transform[5];
      }
      text += pageText + "\n\n";
    }
  } finally {
    if (doc.destroy) doc.destroy();
  }
  return text.trim();
}

// ---- AI 回應 → JSON 陣列(容錯:直接 parse → strip ```json → 抓 [...] 片段)----
export function extractJsonArray(raw) {
  if (raw == null) return null;
  const tryParse = (x) => { try { const v = JSON.parse(x); return Array.isArray(v) ? v : null; } catch { return null; } };
  let s = String(raw).trim();
  let v = tryParse(s); if (v) return v;
  s = s.replace(/```json/gi, "").replace(/```/g, "").trim();   // 去 markdown 圍欄再試
  v = tryParse(s); if (v) return v;
  const a = s.indexOf("["), b = s.lastIndexOf("]");            // 抓第一個 [ 到最後一個 ]
  if (a >= 0 && b > a) { v = tryParse(s.slice(a, b + 1)); if (v) return v; }
  return null;
}

const EXTRACT_SYSTEM =
  "你是醫材訂單解析器。使用者會給你一份訂單/採購單的純文字內容。" +
  "請抽出所有品項,只回傳一個 JSON 陣列,不要任何說明文字,不要 markdown 圍欄。\n" +
  '每個元素格式:{"item_code":"","item_name":"","qty":0,"unit":"","contract_no":"","delivery_date":"","confidence":"high"}\n' +
  "規則:\n" +
  "1. 品號(item_code)請逐字元精確抄寫,不要臆測、不要自行補零或改格式。\n" +
  '2. 任何看不清或不確定的欄位,值留空字串,並把該元素的 confidence 設為 "low";有把握才用 "high"。\n' +
  "3. qty 填數字;沒有的欄位填空字串。\n" +
  "4. 完全沒有品項時回傳 []。";

// PDF 文字 → AI 抽品項(claude-haiku-4-5)。回 { parse_status, items, parse_error }。
export async function aiExtractItems(text) {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": process.env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5",
        max_tokens: 2000,
        system: EXTRACT_SYSTEM,
        messages: [{ role: "user", content: String(text).slice(0, 20000) }],
      }),
    });
    const data = await res.json();
    const raw = (data.content || []).filter((b) => b.type === "text").map((b) => b.text).join("").trim();
    const items = extractJsonArray(raw);
    if (items === null) {
      return { parse_status: "failed", items: [], parse_error: "AI 回應無法解析為 JSON: " + raw.slice(0, 500) };
    }
    return { parse_status: "ok", items };
  } catch (e) {
    return { parse_status: "failed", items: [], parse_error: "AI 呼叫失敗: " + (e.message || e) };
  }
}

// PDF：抽文字 → 掃描件判定 / AI 抽品項
export async function parsePdf(buf) {
  let text = "";
  try {
    text = await pdfToText(buf);
  } catch (e) {
    return { file_kind: "pdf", parse_status: "failed", items: [], parse_error: "pdf 抽字失敗: " + (e.message || e) };
  }
  if (text.length < 50) {
    return { file_kind: "pdf_scanned", parse_status: "scanned_needs_manual", items: [], parse_error: null };
  }
  const ai = await aiExtractItems(text);
  return { file_kind: "pdf", parse_status: ai.parse_status, items: ai.items, parse_error: ai.parse_error || null };
}

// ---- 對外總入口:依副檔名分派 ----
// 回 { file_kind, parse_status, items, parse_error }
export async function parseAttachment({ buffer, filename }) {
  const ext = extOf(filename);
  try {
    if (ext === ".csv") { const r = await parseCsv(buffer); return { file_kind: "csv", parse_status: "ok", items: r.items, parse_error: null }; }
    if (ext === ".xlsx" || ext === ".xls") { const r = await parseXlsx(buffer); return { file_kind: "xlsx", parse_status: "ok", items: r.items, parse_error: null }; }
    if (ext === ".pdf") { return await parsePdf(buffer); }
    return { file_kind: "other", parse_status: "skipped", items: [], parse_error: null };
  } catch (e) {
    return { file_kind: ext.replace(".", "") || "other", parse_status: "failed", items: [], parse_error: "解析例外: " + (e.message || e) };
  }
}
