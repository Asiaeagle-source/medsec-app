// ============================================================
// MedSec 信件分流 — 規則設定 + AI 分類邏輯
// ------------------------------------------------------------
// 這支跑在排程後端 (Vercel Cron function)，每天早午各一次:
//   1. 用 Microsoft Graph 抓當日未讀/新信 (寄件者、主旨、前段內文)
//   2. 跑 classifyMail() 分流 → 紅黃灰、歸類、認醫院、出摘要
//   3. 寫進 Supabase mail_digest
//
// 安全: 只把「寄件者 + 主旨 + 內文前段」送進判斷，不存全文。
// 原則: AI 出料，人決斷 — 這裡只分類，不回信、不外送。
// ============================================================

// ---- 標紅規則 (可調) -------------------------------------------------
// 命中任一 redTriggers → 紅 (今日必處理)
// 否則命中 amberTriggers → 黃 (本週注意)
// 都沒中 → 灰 (批次瀏覽)
export const TRIAGE_RULES = {

  red: {
    // 主旨/內文關鍵詞 → 標紅 + 對應原因標籤
    keywords: [
      { match: ["招標", "投標", "決標", "比價"], reason: "招標 / 投標" },
      { match: ["程序委員會", "衛materials委員會", "衛材委員會", "醫材會", "審議"], reason: "程序委員會" },
      { match: ["客訴", "申訴", "抱怨"], reason: "客訴" },
      { match: ["退貨", "退回", "換貨"], reason: "退貨" },
      { match: ["不良品", "器械異常", "故障", "瑕疵", "MDR"], reason: "器械異常" },
      { match: ["召回", "回收", "recall"], reason: "召回" },
      { match: ["缺貨", "斷貨", "供貨延遲", "交期延後", "backorder"], reason: "缺貨" },
      { match: ["採購單", "訂單", "PO", "purchase order"], reason: "正式採購單" },
    ],
    // 主旨含這些「急迫詞」也直接標紅
    urgencyWords: ["急", "緊急", "今日", "本日", "限今", "截止", "deadline", "ASAP", "盡快"],
  },

  amber: {
    keywords: [
      { match: ["報價", "詢價", "估價"], reason: "報價請求" },
      { match: ["續約", "合約", "契約"], reason: "合約 / 續約" },
      { match: ["詢問", "洽詢", "請問"], reason: "一般詢問" },
      { match: ["請款", "對帳", "發票", "付款"], reason: "帳務" },
    ],
  },

  // 灰: 電子報、系統自動信、原廠 newsletter — 不必逐封看
  gray: {
    senderHints: ["newsletter", "no-reply", "noreply", "notification", "donotreply", "mailer"],
    keywords: [{ match: ["電子報", "週報", "活動通知", "研討會"], reason: "電子報 / 通知" }],
  },
};

// ---- 醫院辨識: 寄件網域 → 院碼 -------------------------------------
// 認出寄件醫院後，前端再對「業祕分區」帶出負責業祕。
// 院碼對齊 medsec_hospitals.id(COPI01)，取自 sql/04_seed_medsec_hospitals.sql。
// 這份對照先放常用大院，其餘交給 AI 從署名/內文判斷 (hospital_hint)。
export const HOSPITAL_DOMAINS = {
  "ntuh.gov.tw":     { name: "台大醫院",  hospital_code: "NTUN" },
  "vghtpe.gov.tw":   { name: "台北榮總",  hospital_code: "VGTN" },
  "vghks.gov.tw":    { name: "高雄榮總",  hospital_code: "VGKS" },
  "vghtc.gov.tw":    { name: "台中榮總",  hospital_code: "VGTM" },
  "cgmh.org.tw":     { name: "林口長庚",  hospital_code: "CGLN" },  // 預設林口長庚;子網域可細分基/桃/嘉/高
  "mmh.org.tw":      { name: "台北馬偕",  hospital_code: "MMTN" },
  "cmuh.cmu.edu.tw": { name: "中國附醫",  hospital_code: "CMUM" },
  "kmuh.org.tw":     { name: "高醫",      hospital_code: "KCUS" },
  // … 之後可從醫院主檔批次匯入完整對照
};

// ============================================================
// 規則先跑 (零成本)，規則模糊或要摘要時才呼叫 Claude。
// ============================================================

function ruleScan(subject = "", snippet = "", senderEmail = "") {
  const text = `${subject} ${snippet}`;
  const lowerSender = senderEmail.toLowerCase();

  // 灰: 自動信寄件者
  if (TRIAGE_RULES.gray.senderHints.some(h => lowerSender.includes(h))) {
    return { priority: "gray", category: "電子報 / 通知", flag_reason: null };
  }
  // 紅: 關鍵詞
  for (const k of TRIAGE_RULES.red.keywords) {
    if (k.match.some(w => text.includes(w))) return { priority: "red", category: k.reason, flag_reason: k.reason };
  }
  // 紅: 急迫詞
  if (TRIAGE_RULES.red.urgencyWords.some(w => text.includes(w))) {
    return { priority: "red", category: "急件", flag_reason: "標示急件" };
  }
  // 黃
  for (const k of TRIAGE_RULES.amber.keywords) {
    if (k.match.some(w => text.includes(w))) return { priority: "amber", category: k.reason, flag_reason: k.reason };
  }
  return null; // 規則沒判定 → 交給 AI
}

function hospitalFromDomain(senderEmail = "") {
  const domain = senderEmail.split("@")[1]?.toLowerCase() || "";
  const hit = Object.keys(HOSPITAL_DOMAINS).find(d => domain.endsWith(d));
  return hit ? HOSPITAL_DOMAINS[hit] : null;
}

// ---- Claude 分類 (補規則沒判到的 + 一律出摘要) -----------------------
// 用 claude-haiku 跑分類最划算; 要更準可換 sonnet。
async function aiClassify({ subject, snippet, senderName, senderEmail }) {
  const prompt = `你是醫材經銷公司的業務祕書助手，幫忙把進來的信件分流。
只能根據以下資訊判斷，不要臆測沒有的內容。

寄件者: ${senderName} <${senderEmail}>
主旨: ${subject}
內文前段: ${snippet}

請輸出 JSON (只輸出 JSON，不要任何其他文字):
{
  "priority": "red|amber|gray",   // red=今日必處理, amber=本週注意, gray=批次瀏覽
  "category": "招標|程序委員會|客訴|退貨|器械異常|召回|缺貨|採購單|報價|合約|帳務|電子報|其他",
  "flag_reason": "若 red, 用4字內說明原因; 否則 null",
  "deadline": "若內容有明確截止日期則填 YYYY-MM-DD, 否則 null",
  "hospital_hint": "若認得出是哪家醫院則填院名, 否則 null",
  "summary": "用一句話(35字內)說這封在講什麼、要做什麼"
}

判斷標準:
- 招標/投標/程序委員會/客訴/退貨/器械異常/召回/缺貨/正式採購單, 或含截止日的急件 → red
- 報價請求/合約續約/一般詢問/帳務 → amber
- 電子報/系統自動信/原廠newsletter → gray`;

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": process.env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1000,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  const data = await res.json();
  const text = data.content.filter(b => b.type === "text").map(b => b.text).join("");
  return JSON.parse(text.replace(/```json|```/g, "").trim());
}

// ---- 對外主函式 -----------------------------------------------------
// 排程後端對每封信呼叫這個，回傳可直接寫進 mail_digest 的物件。
export async function classifyMail(mail) {
  const { subject = "", snippet = "", senderName = "", senderEmail = "", graphMessageId, receivedAt } = mail;

  // 1) 規則先跑
  const ruled = ruleScan(subject, snippet, senderEmail);
  // 2) 醫院從網域認
  const hosp = hospitalFromDomain(senderEmail);
  // 3) AI 補判定 + 出摘要 (規則命中時仍呼叫 AI 拿 summary/deadline)
  const ai = await aiClassify({ subject, snippet, senderName, senderEmail });

  return {
    graph_message_id: graphMessageId,
    received_at: receivedAt,
    sender_email: senderEmail,
    sender_name: senderName,
    subject,
    ai_summary: ai.summary || null,
    priority: ruled?.priority || ai.priority || "gray",   // 規則優先, AI 補位
    category: ruled?.category || ai.category || "其他",
    flag_reason: ruled?.flag_reason || ai.flag_reason || null,
    deadline: ai.deadline || null,
    hospital_code: hosp?.hospital_code || null,            // 認不出 → null → 待主管指派
    // assigned_to / status 由 DB 預設與 view 處理
  };
}
