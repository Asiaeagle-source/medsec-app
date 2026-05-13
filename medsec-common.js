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
    .select('employee_id, name, nickname, medsec_role, has_medsec_access')
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
