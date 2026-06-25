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
export const GRAY_HINTS = ["newsletter","no-reply","noreply","notification","donotreply","mailer","epaper","熱訊","電子報"];

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
  urge:      ["催交","催貨","催單","儘速","速辦","逾期","未出貨","急出","催出","限期"],
  order:     ["訂貨單","訂購單","訂單","採購單","採購通知","出貨","補貨","履約","交貨","訂貨通知","寄銷","寄賣","消耗檔"],
  // 一般客訴 / 退貨 / 缺貨(非技術性 → 派業祕處理)
  complaint: ["客訴","申訴","抱怨","退貨","退回","缺貨","斷貨"],
  quote:     ["報價","詢價","估價","詢問","洽詢"],
  invoice:   ["發票","折讓","請款","催款","對帳","應收","應付","帳單","收款"],
  oem:       ["原廠","medtronic"],
};
const hit = (text, list) => list.some(w => text.toLowerCase().includes(w.toLowerCase()));
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
    if (hit(text, KW.urge))      return { priority:"red",   category:"催貨",     flag_reason:"催貨/催交", assignee:null };
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
async function resolveHospitalCode(name) {
  if (!name) return null;
  try {
    const url = `${process.env.SUPABASE_URL}/rest/v1/medsec_hospitals?select=id,name_full,name_short`
      + `&or=(name_short.ilike.*${encodeURIComponent(name)}*,name_full.ilike.*${encodeURIComponent(name)}*)&limit=1`;
    const res = await fetch(url, { headers:{ apikey:process.env.SUPABASE_SERVICE_KEY, Authorization:`Bearer ${process.env.SUPABASE_SERVICE_KEY}` } });
    const rows = await res.json();
    return Array.isArray(rows) && rows[0] ? rows[0].id : null;
  } catch { return null; }
}

// ---- 對外主函式 ----
export async function classifyMail(mail) {
  const { subject="", snippet="", senderName="", senderEmail="", graphMessageId, receivedAt } = mail;

  // 先 AI 出摘要+認醫院 (一次呼叫)
  const ai = await aiSummaryAndHospital({ subject, snippet, senderName, senderEmail });
  // 認出醫院名 → 查院碼
  const hospitalId = await resolveHospitalCode(ai.hospital);
  // 性質分派 (AI 認出醫院也算客戶)
  const r = routeMail({ subject, snippet, senderEmail }, ai.hospital);

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
  };
}
