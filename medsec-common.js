/* ============================================================
   AE MED Hub — medsec-app 共用 JS
   Version: V1.0 骨架版
   負責：Supabase 連線、Auth 守門、角色守門、登出、Profile 載入
   ============================================================ */

// ⚠️ 替換成 medteam-app 同樣的 Supabase 設定（共用同一個 Project）
const SUPABASE_URL = 'https://yincuegybnuzgojakkuc.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpbmN1ZWd5Ym51emdvamFra3VjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ1MjYzNDQsImV4cCI6MjA5MDEwMjM0NH0.cYy7YQpmNAqQ49wG1q_hgiujLroWdkVaKlqlMx5zIFM'; // ⚠️ 貼上你的 anon key（跟 medteam-app 一樣）

// 全域 supabase client
const supa = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// 全域 profile（守門通過後會塞進來）
let currentProfile = null;

/* ------------------------------------------------------------
   角色 → 對應頁面 對照表
   ------------------------------------------------------------ */
const ROLE_PAGE_MAP = {
  manager:      'manager.html',
  bidding_team: 'candy.html',
  purchasing:   'cindie.html',
  accounting:   'accounting.html',
  secretary:    'secretary.html',
};

const ROLE_LABEL_MAP = {
  manager:      '管理者',
  bidding_team: '標案團隊',
  purchasing:   '採購',
  accounting:   '會計',
  secretary:    '業務祕書',
};

const ROLE_TAG_CLASS = {
  manager:      'manager',
  bidding_team: 'bidding',
  purchasing:   'purchasing',
  accounting:   'accounting',
  secretary:    'secretary',
};

/* ------------------------------------------------------------
   守門：每個角色頁面進來時都要呼叫
   - requiredRole: 'manager' | 'bidding_team' | ...
   檢查項目：
     1. 是否已登入
     2. 是否有 has_medsec_access
     3. medsec_role 是否符合
   不通過 → 跳回 login.html
   通過 → 回傳 profile（含 name, employee_id, medsec_role）
   ------------------------------------------------------------ */
async function guardRole(requiredRole) {
  // 1. 取得 session
  const { data: { session }, error: sessionErr } = await supa.auth.getSession();
  if (sessionErr || !session) {
    window.location.href = 'login.html';
    return null;
  }

  // 2. 從 profiles 撈出完整資料
  const { data: profile, error: profileErr } = await supa
    .from('profiles')
    .select('id, employee_id, name, nickname, medsec_role, has_medsec_access')
    .eq('id', session.user.id)
    .single();

  if (profileErr || !profile) {
    alert('找不到帳號資料，請聯繫管理員');
    await supa.auth.signOut();
    window.location.href = 'login.html';
    return null;
  }

  // 3. 檢查 MedSec 存取權
  if (!profile.has_medsec_access) {
    alert('您沒有 MedSec Hub 的存取權限');
    await supa.auth.signOut();
    window.location.href = 'login.html';
    return null;
  }

  // 4. 檢查角色是否符合此頁面
  if (profile.medsec_role !== requiredRole) {
    // 角色不符 → 跳到他自己的頁面（避免越權）
    const targetPage = ROLE_PAGE_MAP[profile.medsec_role];
    if (targetPage) {
      window.location.href = targetPage;
    } else {
      alert('您的角色未設定，請聯繫管理員');
      await supa.auth.signOut();
      window.location.href = 'login.html';
    }
    return null;
  }

  // 通過所有守門，存到全域
  currentProfile = profile;
  return profile;
}

/* ------------------------------------------------------------
   渲染 sidebar 底部的使用者資訊
   ------------------------------------------------------------ */
function renderUserInfo(profile) {
  const nameEl = document.getElementById('user-name');
  const idEl = document.getElementById('user-id');
  if (nameEl) nameEl.textContent = profile.nickname || profile.name || '使用者';
  if (idEl) idEl.textContent = `#${profile.employee_id} · ${ROLE_LABEL_MAP[profile.medsec_role] || profile.medsec_role}`;
}

/* ------------------------------------------------------------
   登出
   ------------------------------------------------------------ */
async function handleLogout() {
  if (!confirm('確認登出？')) return;
  await supa.auth.signOut();
  window.location.href = 'login.html';
}

/* ------------------------------------------------------------
   nav 切換（單頁切換 placeholder 用）
   ------------------------------------------------------------ */
function switchModule(moduleId) {
  // 切換 active 狀態
  document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
  const triggered = document.querySelector(`[data-module="${moduleId}"]`);
  if (triggered) triggered.classList.add('active');

  // 切換內容區
  document.querySelectorAll('[id^="mod-"]').forEach(el => el.style.display = 'none');
  const target = document.getElementById(`mod-${moduleId}`);
  if (target) target.style.display = 'block';
}

/* ------------------------------------------------------------
   隱藏載入遮罩
   ------------------------------------------------------------ */
function hideLoading() {
  const mask = document.getElementById('loading-mask');
  if (mask) mask.classList.add('hidden');
}

/* ============================================================
   Week 3-2 · 案件模組共用常數 / helpers
   ============================================================ */

/* 10 個 V1 action_type（V3.3 §Q2 拍板）→ 中文標籤 */
const ACTION_TYPE_LABEL = {
  coding:           '建碼',
  quote:            '一般報價',
  surplus:          '結餘款報價',
  budget:           '年度預算',
  renewal:          '汰舊換新',
  urgent:           '臨購案',
  amortize:         '攤提成交',
  negotiate:        '議價',
  tender_supply:    '耗材招標',
  tender_equipment: '設備招標',
  // V2 範圍（顯示用，業務目前不會提）
  borrow:           '暫借/Demo',
  repair_quote:     '維修報價',
  maintenance:      '設備保養',
};

/* 9 種 status（V3.3 §Q3 拍板）→ 中文 + 視覺色 */
const STATUS_META = {
  pending:            { label: '待認領',   tone: 'pending' },
  claimed:            { label: '已認領',   tone: 'claimed' },
  packaging:          { label: '整理中',   tone: 'packaging' },
  pending_decision:   { label: '等決策',   tone: 'wait-decide' },
  decided:            { label: '已拍板',   tone: 'decided' },
  crm_sent:           { label: '已打鼎新', tone: 'done' },
  closed:             { label: '已結案',   tone: 'done' },
  returned:           { label: '已退回',   tone: 'returned' },
  pending_supplement: { label: '待補件',   tone: 'returned' },
};

/* ------------------------------------------------------------
   SOP 提示卡（V1 硬編碼 12 卡）
   key = action_type，每個 action_type 有 2-3 個 status 對應卡片
   surplus/budget/renewal/urgent/amortize → 共用 WIS02 (一張定義給 5 個 key 用)
   tender_supply / tender_equipment       → 共用 WIS04
   ------------------------------------------------------------ */
const _SOP_WIS02 = {
  claimed: {
    title: 'WIS02 結餘/預算/汰換 SOP 提醒',
    items: [
      '確認本次屬於哪類資金來源（結餘款 / 年度預算 / 汰換 / 臨購 / 攤提）',
      '醫院端對應窗口（採購 / 護理 / 院長室）已釐清',
      '是否與既有 CRM 案件重複（同醫院 30 天內同產品）',
    ],
  },
  pending_decision: {
    title: 'WIS02 送決策前最後確認',
    items: [
      '醫院端使用截止日（影響交期）已填',
      '同醫院近 5 筆同產品成交價已附',
      'ai_suggested_price 已產生（不為 0 / NULL）',
    ],
  },
};
const _SOP_WIS04 = {
  claimed: {
    title: 'WIS04 招標 SOP 提醒',
    items: [
      '標案編號 / 開標日期已填',
      '押標金金額已填',
      '三間廠商到齊（招標法定要求）',
    ],
  },
  packaging: {
    title: 'WIS04 標單包整理',
    items: [
      '規格符合招標公告（逐條對應）',
      '報價低於預算',
      '標單文件齊全（廠商資格 / 過往實績 / 樣品）',
    ],
  },
  pending_decision: {
    title: 'WIS04 送決策前確認',
    items: [
      '押標金支付截止日（避免棄標）',
      '競爭廠商分析（已知者列出）',
      '設備類需附原廠授權書',
    ],
  },
};
const SOP_CARDS = {
  coding: {
    claimed: {
      title: 'WIS01 建碼 SOP 提醒',
      items: [
        '與醫院確認是否需試用（連 WIS05 暫借）',
        '提供報價單前先了解醫院折扣率',
        '確認衛署字號 / QSD 已建檔',
      ],
    },
    packaging: {
      title: 'WIS01 建碼文件包整理',
      items: [
        '同醫院近 5 筆成交價已查',
        '體系折扣率已查',
        '同產品健保碼 / 衛署字號齊全',
      ],
    },
    pending_decision: {
      title: 'WIS01 送決策前確認',
      items: [
        '決策包資料齊全（成交歷史 / 規則 / 底價）',
        '已附醫院規則卡（付款週期 / 發票格式）',
        'Lynn 預計 2 分鐘內回覆',
      ],
    },
  },
  quote: {
    claimed: {
      title: '一般報價 SOP 提醒',
      items: [
        '同醫院近 5 筆同產品成交價已查',
        '體系折扣率已查',
        '醫院付款週期 / 開立發票方式已對',
      ],
    },
    pending_decision: {
      title: '一般報價送決策前確認',
      items: [
        'ai_suggested_price 已產生（不為 0 / NULL）',
        '毛利率對 OK（高於體系平均）',
        '預設 erp_doc_code 是否需改 (耗材/設備/器械)',
      ],
    },
  },
  surplus:   _SOP_WIS02,
  budget:    _SOP_WIS02,
  renewal:   _SOP_WIS02,
  urgent:    _SOP_WIS02,
  amortize:  _SOP_WIS02,
  tender_supply:    _SOP_WIS04,
  tender_equipment: _SOP_WIS04,
  negotiate: {
    claimed: {
      title: 'WIS06 議價 SOP 提醒',
      items: [
        '議價對象（採購 / 院長室 / 標案中心）',
        '對手報價已掌握',
        '底價是否已知（manager 才看得到）',
      ],
    },
    pending_decision: {
      title: 'WIS06 議價送決策前確認',
      items: [
        '議價空間區間（最低可接受價）已對',
        '議價時機（招標前 / 開標後）',
        '同體系類似案件參考',
      ],
    },
  },
};

/* ------------------------------------------------------------
   業祕分區醫院 id list（自己是主祕或副祕的醫院）
   ------------------------------------------------------------ */
async function loadMySecretaryHospitalIds(userId) {
  const { data, error } = await supa
    .from('medsec_secretary_assignments')
    .select('hospital_id, primary_secretary_id, co_secretary_id')
    .or(`primary_secretary_id.eq.${userId},co_secretary_id.eq.${userId}`);
  if (error) {
    console.error('[loadMySecretaryHospitalIds]', error);
    return [];
  }
  return (data || []).map(r => r.hospital_id);
}

/* ------------------------------------------------------------
   認領案件：pending → claimed + 寫 timeline
   ------------------------------------------------------------ */
async function claimCase(caseId, profile) {
  // 1. UPDATE — RLS 不過會回 0 row
  const { data: updated, error: updErr } = await supa
    .from('medsec_cases')
    .update({
      status: 'claimed',
      current_owner_id: profile.id,
      current_owner_role: 'secretary',
    })
    .eq('id', caseId)
    .eq('status', 'pending')                       // 防搶單 race（兩人同點只有一人成功）
    .select('id')
    .maybeSingle();

  if (updErr) return { ok: false, error: updErr.message };
  if (!updated) return { ok: false, error: '已被他人認領或狀態已變' };

  // 2. INSERT timeline — V1 不做 transaction，update 成功才寫
  const { error: tlErr } = await supa
    .from('medsec_case_timeline')
    .insert({
      case_id: caseId,
      event_type: 'claimed',
      event_data: { from_status: 'pending', to_status: 'claimed' },
      actor_id: profile.id,
      description: `${profile.nickname || profile.name || '業祕'} 認領案件`,
    });
  if (tlErr) console.warn('[claimCase] timeline insert 失敗（不阻塞）', tlErr);

  return { ok: true };
}
