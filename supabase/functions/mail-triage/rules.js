// ============================================================
// MedSec 信件分流 — 規則 v3 (AI 認分院 + 客戶/廠商分流)
// ------------------------------------------------------------
// 與 v2 差異: 院碼不再靠網域查表 (多院區分不出), 改由 AI 從內文認出
// 「哪一家分院」, 程式再去 medsec_hospitals 模糊比對拿院碼。
// 網域只用來判「是不是醫院系統(客戶)」。
//
// 流程: routeMail 判性質+客戶/廠商 → AI 出摘要+認醫院名 →
//        resolveHospitalCode 名稱轉院碼 → 落到該分院業秘
//
// priority: red / amber / order / billing / gray
// 第一批: 單一主辦 (assignees[0])。原廠請款的會計副辦(0176)留到第二批 assigned_cc。
// ============================================================

export const ROLE_ASSIGNEE = {
  purchasing: "0003",  // 採購 — 廠商訂貨/原廠
  service:    "0015",  // 客服 — 維修/設備警報
  bidding:    "0132",  // 鄭欣菱 — 標案
  accounting: "0176",  // 會計 — 匯款/請款/非醫材供應商
};

// 灰名單 (廣告/電子報/自動信 直接歸灰)
export const GRAY_SENDERS = ["news@epaperwt.smda.tw", "fpgcs@lm.tradevan.com.tw"];
// sender OR subject 任一含這些 hint 即降為灰。
// 注意:加新詞前確認不會誤殺正事(例如「課程」太通用,只用「開課/實戰班」較準)。
export const GRAY_HINTS = [
  // 寄件人特徵
  "newsletter","no-reply","noreply","notification","donotreply","mailer","epaper",
  // 行銷 / 電子報主旨關鍵詞
  "熱訊","每日熱訊","電子報","屆期提示",
  // HR / 課程廣告主旨關鍵詞
  "開課","實戰班","招生簡章","講習會","課程招生",
];

// 醫院系統網域 (只判「是不是客戶」, 不決定院碼; 院碼由 AI 認分院)
export const CUSTOMER_DOMAINS = [
  "ntuh.gov.tw","vghtpe.gov.tw","vghks.gov.tw","vhyk.gov.tw","vghtc.gov.tw",
  "cgmh.org.tw","mmh.org.tw","show.org.tw","chimei.org.tw","cych.org.tw",
  "cch.org.tw","tzuchi.com.tw","femh.org.tw","ncku.edu.tw","hosp.ncku.edu.tw",
  "tpech.gov.tw","pohai.org.tw","ktgh.com.tw","hch.gov.tw","ylh.gov.tw",
  "sinlau.org.tw","mail.vhyk.gov.tw",
  // 之後補其餘醫院網域; 不在表內也可能是客戶 — AI 認出醫院名也算客戶
];

const KW = {
  repair:    ["維修","報修","故障","保固","送修","檢修","校正"],
  alarm:     ["溫控","溫度異常","saveris","testo","system warning","alarm","警報","warning","alert","temperature out of range"],
  // 技術性設備異常 → 客服 0015(從 complaint 拆出,避免客戶網域寄來時被當一般客訴落到業祕 null)
  device:    ["器械異常","設備異常","儀器異常","機台異常","不良品","瑕疵","MDR","召回","回收"],
  bidding:   ["招標","投標","決標","比價","議價","標案","採購公告","開標","廢標"],
  remit:     ["匯款","匯入","入帳","已付款","付款通知","轉帳"],
  // 催貨升 red 只比對 SUBJECT(避免內文 footer「請於限期內回覆」誤升)。
  // 移除原本太寬的 "限期" / "速辦";加 "逾期不候" 確保真正催件被抓。
  urge:      ["催交","催貨","催單","儘速","逾期","逾期不候","未出貨","急出貨","催出貨"],
  order:     ["訂貨單","訂購單","訂單","採購單","採購通知","出貨","補貨","履約","交貨","訂貨通知","寄銷","寄賣","消耗檔"],
  // 一般客訴 / 退貨 / 缺貨(非技術性 → 派業祕處理)
  complaint: ["客訴","申訴","抱怨","退貨","退回","缺貨","斷貨"],
  quote:     ["報價","詢價","估價","詢問","洽詢"],
  invoice:   ["發票","折讓","請款","催款","對帳","應收","應付","帳單","收款"],
  oem:       ["原廠","medtronic"],
};
const hit = (text, list) => list.some(w => text.toLowerCase().includes(w.toLowerCase()));

// ---- needs_reply 判定(PR A)----
// 主旨/摘要含以下 hint → 需回覆;行銷/系統通知(gray / 電子報 / 通知)永遠 false。
export const NEEDS_REPLY_HINTS = ["詢價","報價","請回覆","請確認","煩請","是否","能否","？","?"];
export function needsReply({ subject="", summary="", priority="", category="" }) {
  if (priority === "gray") return false;                 // 灰名單(行銷/自動信)不回
  if (/電子報|通知/.test(category)) return false;        // 系統通知類不回
  const text = `${subject} ${summary || ""}`;
  return NEEDS_REPLY_HINTS.some(h => text.includes(h));
}
const domainOf = (e="") => (e.split("@")[1] || "").toLowerCase();
const isCustomerDomain = (e="") => { const d = domainOf(e); return CUSTOMER_DOMAINS.some(x => d.endsWith(x)); };
// service 寄件人特徵(testo / saveris 設備警報走自己的網域,不是醫院也不是廠商)
const SERVICE_SENDERS = ["testo", "saveris"];
const isServiceSender = (e="") => SERVICE_SENDERS.some(k => e.toLowerCase().includes(k));

// ---- 性質分派 (不含院碼; 院碼後面 AI 認) ----
function routeMail({ subject="", snippet="", senderEmail="" }, aiSaysHospital) {
  const text = `${subject} ${snippet}`;
  const sender = senderEmail.toLowerCase();
  const A = ROLE_ASSIGNEE;
  // 客戶 = 網域命中醫院系統, 或 AI 認出是某醫院
  const isCustomer = isCustomerDomain(senderEmail) || !!aiSaysHospital;

  // 0) 灰名單
  if (GRAY_SENDERS.includes(sender) || GRAY_HINTS.some(h => sender.includes(h) || subject.includes(h)))
    return { priority:"gray", category:"電子報/通知", flag_reason:null, assignee:null };

  // 1) 特殊性質 — 不分客戶廠商,優先派固定角色(覆蓋 isCustomer 的 null)
  // 設備警報 / 器械異常 / 維修 都吃客服 0015,確保 testo 警報 + 各院設備異常不漏接
  if (hit(text, KW.alarm) || isServiceSender(sender))
                             return { priority:"red",     category:"設備警報", flag_reason:"設備警報", assignee:A.service };
  if (hit(text, KW.device))  return { priority:"red",     category:"器械異常", flag_reason:"器械異常", assignee:A.service };
  if (hit(text, KW.repair))  return { priority:"amber",   category:"維修",     flag_reason:null,       assignee:A.service };
  if (hit(text, KW.bidding)) return { priority:"red",     category:"標案",     flag_reason:"標案",     assignee:A.bidding };
  if (hit(text, KW.remit))   return { priority:"billing", category:"匯款通知", flag_reason:null,       assignee:A.accounting };

  // 2) 客戶(醫院) — 派該院業秘 (assignee=null, 由 hospital_id 帶業秘)
  if (isCustomer) {
    // urge 只比 SUBJECT,讓例行採購單/交貨通知不會因內文 footer「請於限期內回覆」誤升 red。
    // 真正催件(主旨含「催/逾期/儘速/逾期不候/急出貨」)才升 red,其他走 order/客訴/...
    if (hit(subject, KW.urge))   return { priority:"red",   category:"催貨",     flag_reason:"催貨/催交", assignee:null };
    if (hit(text, KW.complaint)) return { priority:"red",   category:"客訴",     flag_reason:"客訴",     assignee:null };
    if (hit(text, KW.order))     return { priority:"order", category:"訂單",     flag_reason:null,        assignee:null };
    if (hit(text, KW.invoice))   return { priority:"amber", category:"發票/折讓", flag_reason:null,        assignee:null };
    if (hit(text, KW.quote))     return { priority:"amber", category:"報價詢問", flag_reason:null,        assignee:null };
    return { priority:"amber", category:"醫院往來", flag_reason:null, assignee:null };
  }

  // 3) 廠商
  if (hit(text, KW.invoice)) {
    // 原廠請款 → 採購主辦 (會計副辦 0176 留待第二批 assigned_cc)
    return { priority:"billing", category: hit(text,KW.oem) ? "原廠請款" : "廠商請款",
             flag_reason:null, assignee: hit(text,KW.oem) ? A.purchasing : A.accounting };
  }
  if (hit(text, KW.order) || hit(text, KW.oem))
    return { priority:"order", category:"廠商訂貨", flag_reason:null, assignee:A.purchasing };

  // 4) 其他非醫材供應商 → 會計
  return { priority:"amber", category:"廠商其他", flag_reason:null, assignee:A.accounting };
}

// ---- AI: 一次呼叫出「摘要 + 認醫院名」----
async function aiSummaryAndHospital({ subject, snippet, senderName, senderEmail }) {
  const prompt = `你是醫材經銷公司的助理。讀以下信件, 只輸出 JSON (不要其他文字):
{"summary":"一句話(35字內)說這封在講什麼、要做什麼",
 "hospital":"若是某醫院寄來或關於某醫院, 填該醫院全名或短名(如 林口長庚/彰濱秀傳/台北慈濟); 不是醫院或認不出填 null"}
寄件者: ${senderName} <${senderEmail}>
主旨: ${subject}
內文前段: ${snippet}`;
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type":"application/json", "x-api-key":process.env.ANTHROPIC_API_KEY, "anthropic-version":"2023-06-01" },
      body: JSON.stringify({ model:"claude-haiku-4-5-20251001", max_tokens:300, messages:[{role:"user",content:prompt}] }),
    });
    const data = await res.json();
    const txt = data.content?.filter(b=>b.type==="text").map(b=>b.text).join("").replace(/```json|```/g,"").trim();
    const j = JSON.parse(txt);
    return { summary: j.summary || null, hospital: j.hospital || null };
  } catch { return { summary:null, hospital:null }; }
}

// ---- 醫院名稱 → 院碼 (查 medsec_hospitals 模糊比對) ----
//
// 處理三類輸入(由嚴格到寬鬆,先 hit 先回):
//   (A) AI 給的整段名 ilike(原行為,例:長庚 → 林口長庚紀念醫院 ✓)
//   (B) 「分院」拆「主名 + 分院地名」:先用地名把候選撈回來(單一 or 查詢),
//       再在 JS 端用主名 + 台/臺正規化過濾、排除生醫園區(見 splitBranchTokens /
//       pickBranchRow)。帶 alias(成大→成功大學、北榮→臺北榮民、台大→臺灣大學…),
//       避免 name_full 用全名而 AI 給短名時對不上。
//   (C) 去掉通用詞(分院/總院/紀念醫院/附設醫院/醫院/大學…)後再 ilike 一次。
const HOSPITAL_NAME_ALIASES = {
  "成大": "成功大學",
  "臺大": "臺灣大學",
  "台大": "臺灣大學",
  "北榮": "臺北榮民",
  "中榮": "臺中榮民",
  "高榮": "高雄榮民",
  // AI 也常給「XX榮總」全稱(如高雄榮總台南分院),補上讓主名對得到 name_full。
  "臺北榮總": "臺北榮民",
  "臺中榮總": "臺中榮民",
  "高雄榮總": "高雄榮民",
  "長庚": "長庚紀念",
  "馬偕": "馬偕紀念",
  "慈濟": "慈濟",
  "秀傳": "秀傳",
  "中山": "中山醫學",
};

// 已知分院地名(臺灣醫院分院常見地名)。B 段拆「主名 + 地名」時用它定位地名,
// 不再假設地名固定在「分院」前 2 字 —— 臺大體系把地名放在主名前(新竹臺大分院),
// 馬偕體系放在「分院」前(淡水分院),位置不固定。需要新地名直接往清單加。
export const BRANCH_LOCATIONS = [
  "淡水","斗六","雲林","新竹","台南","臺南","澎湖","汐止","桃園","基隆",
  "金門","東港","潮州","鳳山","岡山","板橋","土城","永和","中和","蘇澳",
  "玉里","關山","鳳林","豐原","嘉義","苗栗","員林","埔里","羅東","花蓮",
];

// 台/臺 常見混用(台南 vs 臺南),查詢時兩種寫法都試一次。
function tzVariants(s) {
  const out = new Set([s]);
  if (s.includes("台")) out.add(s.replace(/台/g, "臺"));
  if (s.includes("臺")) out.add(s.replace(/臺/g, "台"));
  return [...out];
}

// 把「台」正規化成「臺」。alias 比對與 JS 端過濾都先正規化,避免全形/半形對不上
// (台大 vs 臺大、台北榮總 vs 臺北榮總、台南 vs 臺南)。
const normTz = (s) => (s || "").replace(/台/g, "臺");

// 把「XX分院」名稱拆成 { loc(分院地名), mains(主名候選, 含 alias 全名) }。
// 純字串解析、不查 DB,方便單元測試;認不出分院地名回 null。
//
//   1. 先去掉括號別名:雲林分院(斗六) → 雲林分院(斗六 是別名不是地名)。
//   2. 取「分院」前字串裡、最靠近「分院」的已知地名當分院地名
//      —— 高雄榮總台南分院 的 高雄 屬主名,台南 才是分院地名。
//   3. 主名 = 去掉地名/通用詞後剩下的字,再補命中的系統別名全名。
export function splitBranchTokens(rawName) {
  if (!rawName || !rawName.includes("分院")) return null;
  const cleaned = rawName.replace(/[（(][^）)]*[）)]/g, "");           // 去括號別名
  const beforeBranch = cleaned.slice(0, cleaned.indexOf("分院"));
  if (!beforeBranch) return null;

  let loc = null, locPos = -1;
  for (const p of BRANCH_LOCATIONS) {
    const pos = beforeBranch.lastIndexOf(p);   // 取最靠近「分院」的地名(rightmost)
    if (pos > locPos) { locPos = pos; loc = p; }
  }
  if (!loc) return null;

  const raw = [];
  let mainRaw = beforeBranch.split(loc).join("").replace(/醫院|[-－]/g, "").trim();
  // 地名夾在主名中間時(臺大新竹臺大 去掉「新竹」→「臺大臺大」),收斂完全重複的疊字。
  if (mainRaw.length >= 2 && mainRaw.length % 2 === 0) {
    const half = mainRaw.length / 2;
    if (mainRaw.slice(0, half) === mainRaw.slice(half)) mainRaw = mainRaw.slice(0, half);
  }
  if (mainRaw) raw.push(mainRaw);
  // alias 比對做台/臺正規化(台大↔臺大、台北榮總↔臺北榮總 都能命中),再補系統別名全名。
  const beforeNorm = normTz(beforeBranch);
  for (const [short, full] of Object.entries(HOSPITAL_NAME_ALIASES)) {
    if (beforeNorm.includes(normTz(short)) && !raw.includes(full)) raw.push(full);
  }
  if (!raw.length) return null;
  // 主名候選展開台/臺變體(臺大 → 臺大 + 台大),name_short 常用半形「台大」才好中。
  const mains = [];
  for (const m of raw) for (const v of tzVariants(m)) if (!mains.includes(v)) mains.push(v);
  return { loc, mains };
}

// 從撈回的候選列挑出正確分院(純函式,可單元測試,不查 DB):
//   - 主名 tokens 至少一個要出現在 name_full 或 name_short(皆台/臺正規化)。
//   - 生醫園區特殊分院:來信沒指名「生醫/園區」時排除,避免「新竹臺大分院」誤中
//     NTNN(台大新竹生醫),要中 NTHN(台大新竹一般分院);指名時才回生醫那筆。
export function pickBranchRow(rows, tokens, rawName = "") {
  if (!Array.isArray(rows) || !rows.length || !tokens) return null;
  const mains = tokens.mains.map(normTz);
  const loc = normTz(tokens.loc);
  const isBio = (r) => /生醫|園區/.test(normTz(r.name_full) + normTz(r.name_short));
  const cand = rows.filter((r) => {
    const full = normTz(r.name_full), short = normTz(r.name_short);
    if (!mains.some((m) => m && (full.includes(m) || short.includes(m)))) return false;
    return (full + short).includes(loc);
  });
  if (!cand.length) return null;
  const wantsBio = /生醫|園區/.test(rawName);
  const primary = cand.filter((r) => (wantsBio ? isBio(r) : !isBio(r)));
  if (primary.length) return primary[0];
  return wantsBio ? cand[0] : null;   // 沒指名生醫卻只剩生醫園區 → 不亂猜,回 null 待認領
}

const SVC_HEADERS = {
  apikey: process.env.SUPABASE_SERVICE_KEY,
  Authorization: `Bearer ${process.env.SUPABASE_SERVICE_KEY}`,
};

async function lookupOne(query) {
  try {
    const url = `${process.env.SUPABASE_URL}/rest/v1/medsec_hospitals?select=id&${query}&limit=1`;
    const res = await fetch(url, { headers: SVC_HEADERS });
    if (!res.ok) return null;
    const rows = await res.json();
    return Array.isArray(rows) && rows[0] ? rows[0].id : null;
  } catch { return null; }
}

// 撈多筆候選(含 name_full/name_short 供 JS 端過濾)。單一 or 查詢,語法穩。
async function lookupRows(query) {
  try {
    const url = `${process.env.SUPABASE_URL}/rest/v1/medsec_hospitals?select=id,name_full,name_short&${query}&limit=50`;
    const res = await fetch(url, { headers: SVC_HEADERS });
    if (!res.ok) return [];
    const rows = await res.json();
    return Array.isArray(rows) ? rows : [];
  } catch { return []; }
}

async function resolveHospitalCode(name) {
  if (!name) return null;
  const enc = (s) => encodeURIComponent(s);

  // (A) 整段 ilike
  const idA = await lookupOne(
    `or=(name_short.ilike.*${enc(name)}*,name_full.ilike.*${enc(name)}*)`
  );
  if (idA) return idA;

  // (B) 「分院」→ 用地名(含台/臺變體)把候選撈回來,再在 JS 端用主名 + 台/臺正規化過濾、
  //     並排除生醫園區特殊分院。改用地名撈 + JS 過濾(不再靠 PostgREST 巢狀 and/or),
  //     才對得上臺大體系(新竹臺大分院 / 雲林分院(斗六))與 高雄榮總台南分院,並區分
  //     新竹(NTHN) vs 新竹生醫(NTNN)。
  const tokens = splitBranchTokens(name);
  if (tokens) {
    const locOr = tzVariants(tokens.loc)
      .flatMap((v) => [`name_full.ilike.*${enc(v)}*`, `name_short.ilike.*${enc(v)}*`])
      .join(",");
    const rows = await lookupRows(`or=(${locOr})`);
    const picked = pickBranchRow(rows, tokens, name);
    if (picked) return picked.id;
  }

  // (C) 去通用詞後再 ilike 一次
  const stripped = name
    .replace(/分院|總院|紀念醫院|附設醫院|醫學院|醫院|大學/g, "")
    .trim();
  if (stripped && stripped !== name && stripped.length >= 2) {
    const idC = await lookupOne(
      `or=(name_short.ilike.*${enc(stripped)}*,name_full.ilike.*${enc(stripped)}*)`
    );
    if (idC) return idC;
  }

  return null;
}

// ---- 對外主函式 ----
export async function classifyMail(mail) {
  const { subject="", snippet="", senderName="", senderEmail="", graphMessageId, receivedAt,
          bodyText=null, webLink=null } = mail;

  // 先 AI 出摘要+認醫院 (一次呼叫)
  const ai = await aiSummaryAndHospital({ subject, snippet, senderName, senderEmail });
  // 認出醫院名 → 查院碼
  const hospitalId = await resolveHospitalCode(ai.hospital);
  // 性質分派 (AI 認出醫院也算客戶)
  const r = routeMail({ subject, snippet, senderEmail }, ai.hospital);
  // needs_reply:主旨/摘要判定(PR A)
  const needs_reply = needsReply({ subject, summary: ai.summary, priority: r.priority, category: r.category });

  return {
    graph_message_id: graphMessageId,
    received_at: receivedAt,
    sender_email: senderEmail,
    sender_name: senderName,
    subject,
    ai_summary: ai.summary,
    priority: r.priority,
    category: r.category,
    flag_reason: r.flag_reason,
    deadline: null,
    hospital_id: hospitalId,        // AI 認分院 → 院碼; 認不出 = null = 待認領
    assigned_to: r.assignee,        // 員編字串 (採購/客服/會計/標案); cron handler 會用 employee_id→uuid map 轉成 profiles.id 再寫 DB; null = 由 hospital_id 帶業秘
    // ---- PR A 新欄 ----
    body_text: bodyText != null ? String(bodyText).slice(0, 10000) : null,   // 純文字全文(截 10000)
    web_link: webLink || null,                                               // Outlook/OWA 開信連結
    needs_reply,
  };
}
