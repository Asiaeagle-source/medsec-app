// ============================================================
// secretary-todo.js · 業秘每日待辦工作台(secretary.html #mod-todo)
// ------------------------------------------------------------
// 資料層由 MedTeam 端出(schedule_items / secretary_todos_v /
// secretary_carry_over_todos),兩邊共用同一 Supabase。本檔只做 UI +
// 呼叫既有 view/RPC,不建任何 schema、不下 RLS。
//
// 依 SECRETARY_MEDSEC_HANDOFF_v2:
//  §4 撈 secretary_todos_v 必須 .eq('due_date', today)(view 含歷史)
//  §2 每日首開呼叫 secretary_carry_over_todos() 一次(localStorage 防重)
//  §6 完成動線:純 schedule 直寫 is_done;工單條目 C1 今日進度 / C3 結案
//  §3 @類型 6 選存 activities[0].type(中文字串)
//
// ⚠️ 後端契約假設集中在 STD;工單分支(source='ticket')於 view v2 上線後
//    才會有資料,v1 休眠(不影響)。樣式自帶(stodo-*),PR-Sec-3 可沿用。
// ============================================================
const STD = {
  view: 'secretary_todos_v',
  table: 'schedule_items',
  carryRpc: 'secretary_carry_over_todos',
  ticketRpc: 'ticket_action',
  categories: ['出貨', '報價', '月結請款', '文件行政', '庶務支援', '其他'],
};

let TSTATE = { rows: [], me: null };
let _todoInitPromise = null;

function sToday(){ return new Date().toISOString().slice(0, 10); }
function sEsc(s){ return String(s==null?'':s).replace(/[&<>]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function sMe(){ return TSTATE.me || (typeof currentProfile !== 'undefined' ? currentProfile : null); }

// ---- 樣式(自帶,可抽用) ----
function sInjectCss(){
  if (document.getElementById('stodo-css')) return;
  const css = `
  .stodo-head{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:16px}
  .stodo-head .acts{display:flex;gap:8px;flex-wrap:wrap}
  .stodo-btn{font-size:13px;font-family:inherit;border-radius:9px;padding:7px 13px;cursor:pointer;border:1px solid transparent;font-weight:600}
  .stodo-btn.primary{color:#fff;background:#2563eb;border-color:#2563eb}
  .stodo-btn.ghost{color:#2563eb;background:#eef4ff;border-color:#d3e0fb}
  .stodo-btn.soft{color:#475569;background:#f1f3f7}
  .stodo-sec-h{display:flex;align-items:center;gap:8px;font-size:14px;font-weight:700;margin:14px 0 10px}
  .stodo-sec-h .n{font-size:12px;color:#6b7280;font-weight:600}
  .stodo-sec-h.done{color:#1a7f45}.stodo-sec-h.pend{color:#c2790b}.stodo-sec-h.skip{color:#6b7280}
  .stodo-list{display:flex;flex-direction:column;gap:9px;margin-bottom:8px}
  .stodo-card{background:#fff;border:1px solid #e8e9ef;border-radius:12px;padding:12px 15px}
  .stodo-card.is-done{opacity:.7}
  .stodo-top{display:flex;align-items:center;gap:7px;flex-wrap:wrap;margin-bottom:5px}
  .stodo-cat{font-size:11.5px;padding:2px 9px;border-radius:7px;font-weight:600;background:#eef4ff;color:#2563eb}
  .stodo-badge{font-size:11px;padding:2px 8px;border-radius:7px;background:#fdf3df;color:#c2790b;font-weight:600}
  .stodo-badge.ticket{background:#f3f0fb;color:#7c53c9;cursor:pointer}
  .stodo-content{font-size:14px;color:#1d2330;font-weight:500}
  .stodo-meta{font-size:12px;color:#9aa0ab;margin-top:3px}
  .stodo-foot{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:9px;flex-wrap:wrap}
  .stodo-foot .info{font-size:12px;color:#6b7280}
  .stodo-foot .acts{display:flex;gap:7px}
  .stodo-mini{font-size:12px;font-family:inherit;border-radius:8px;padding:5px 11px;cursor:pointer;font-weight:600;border:1px solid transparent}
  .stodo-mini.done{color:#fff;background:#1a7f45}
  .stodo-mini.skip{color:#8b6d00;background:#fdf6e3;border-color:#f0dcae}
  .stodo-mini.prog{color:#2563eb;background:#eef4ff;border-color:#d3e0fb}
  .stodo-mini.resolve{color:#fff;background:#2563eb}
  .stodo-empty{background:#fff;border:1px dashed #e2e5ec;border-radius:12px;padding:22px;text-align:center;color:#9aa0ab;font-size:13px}
  .stodo-mask{position:fixed;inset:0;background:rgba(15,23,42,.42);display:flex;align-items:center;justify-content:center;z-index:80}
  .stodo-modal{background:#fff;border-radius:14px;padding:22px;width:min(440px,92vw);box-shadow:0 14px 44px rgba(0,0,0,.2)}
  .stodo-modal h3{font-size:16px;margin:0 0 4px}
  .stodo-modal p{font-size:12.5px;color:#8b94a3;margin:0 0 14px}
  .stodo-modal label{display:block;font-size:12.5px;color:#475569;font-weight:600;margin:0 0 5px}
  .stodo-modal select,.stodo-modal textarea{width:100%;box-sizing:border-box;font-family:inherit;font-size:14px;padding:10px 12px;border:1px solid #dfe3ea;border-radius:9px;outline:none;margin-bottom:14px}
  .stodo-modal textarea:focus,.stodo-modal select:focus{border-color:#2563eb}
  .stodo-modal .row{display:flex;gap:10px;justify-content:flex-end}
  .stodo-modal button{font-family:inherit;font-size:13.5px;padding:8px 16px;border-radius:9px;cursor:pointer;border:1px solid transparent;font-weight:600}
  .stodo-modal .cancel{background:#f1f3f7;color:#475569}
  .stodo-modal .ok{background:#2563eb;color:#fff}
  .stodo-modal .ok:disabled{opacity:.45;cursor:default}
  .stodo-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%);background:#1d2330;color:#fff;font-size:13px;padding:10px 18px;border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.2);z-index:90;opacity:0;pointer-events:none;transition:opacity .2s;max-width:80vw;text-align:center}
  .stodo-toast.show{opacity:1}
  .stodo-toast.err{background:#b3261e}.stodo-toast.ok{background:#1a7f45}
  `;
  const el = document.createElement('style'); el.id = 'stodo-css'; el.textContent = css;
  document.head.appendChild(el);
}

let _sToastTimer = null;
function sToast(msg, kind){
  let t = document.getElementById('stodo-toast');
  if (!t){ t = document.createElement('div'); t.id = 'stodo-toast'; document.body.appendChild(t); }
  t.className = 'stodo-toast ' + (kind||'') + ' show'; t.textContent = msg;
  clearTimeout(_sToastTimer); _sToastTimer = setTimeout(()=>{ t.className = 'stodo-toast ' + (kind||''); }, 2600);
}

// ---- 資料 ----
async function todoCarryOverOnce(){
  const me = sMe(); if (!me) return;
  const key = 'lastCarryOver_' + me.id, today = sToday();
  if (localStorage.getItem(key) === today) return;
  const { data, error } = await supa.rpc(STD.carryRpc);
  if (error){ console.warn('[todo] carry-over 失敗', error); return; }   // 不擋清單載入
  localStorage.setItem(key, today);
  if (data && data.length) sToast(`已結轉 ${data.length} 條未完成事項到今日`, 'ok');
}
async function loadTodos(){
  const { data, error } = await supa.from(STD.view).select('*')
    .eq('due_date', sToday())                          // ⚠️ §4 必要:view 含歷史
    .order('carried_days', { ascending: false });
  if (error){ console.error('[todo] 讀取失敗', error); sToast('待辦讀取失敗:' + (error.message||error), 'err'); TSTATE.rows = []; return; }
  TSTATE.rows = data || [];
}
async function todoRefresh(){ await loadTodos(); renderTodo(); }

// 首次進模組:carry-over → 載入 → render(共用 promise 防重入)
function ensureTodoModule(){
  if (!_todoInitPromise){
    _todoInitPromise = (async () => {
      sInjectCss();
      TSTATE.me = (typeof currentProfile !== 'undefined') ? currentProfile : null;
      await todoCarryOverOnce();
      await loadTodos();
      renderTodo();
    })();
  }
  return _todoInitPromise;
}

// ---- render ----
function carriedText(r){
  const d = r.carried_days || 0;
  if (r.ticket_id && r.ticket_seq) return `工單 #${r.ticket_seq}`;
  if (d > 1) return `拖 ${d} 天 · 昨日滾入`;
  if (d === 1) return '昨日滾入';
  return '今日新增';
}
function todoCard(r){
  const isTicket = r.source === 'ticket';
  const carried = carriedText(r);
  const carriedCls = (r.ticket_id && r.ticket_seq) ? 'stodo-badge ticket' : 'stodo-badge';
  const carriedEl = (r.carried_days > 0 || (r.ticket_id && r.ticket_seq))
    ? `<span class="${carriedCls}"${isTicket?` onclick="todoOpenTicket('${sEsc(r.row_id)}')"`:''}>${sEsc(carried)}</span>` : '';
  let acts = '';
  if (r.is_done){
    acts = '<span class="info">✓ 已完成</span>';
  } else if (r.skip_reason){
    acts = `<span class="info">⏭ 沒跑:${sEsc(r.skip_reason)}</span>`;
  } else if (isTicket){
    // 工單條目(v2):今日進度(記日誌)/ 結案(resolve)
    acts = `<div class="acts">
      <button class="stodo-mini prog" onclick="todoTicketProgress('${sEsc(r.ticket_id||r.row_id)}')">今日進度</button>
      <button class="stodo-mini resolve" onclick="todoTicketResolve('${sEsc(r.ticket_id||r.row_id)}','${sEsc(r.ticket_seq||'')}')">結案</button>
    </div>`;
  } else {
    // 純 schedule 條目
    acts = `<div class="acts">
      <button class="stodo-mini done" onclick="todoComplete('${sEsc(r.row_id)}')">✓ 完成</button>
      <button class="stodo-mini skip" onclick="todoSkip('${sEsc(r.row_id)}')">沒跑</button>
    </div>`;
  }
  const needInfo = (isTicket && r.ticket_status === 'need_info' && r.ticket_need_info_note)
    ? `<div class="stodo-meta">⚠ 需補資訊:${sEsc(r.ticket_need_info_note)}</div>` : '';
  return `<div class="stodo-card${r.is_done?' is-done':''}" data-todo="${sEsc(r.row_id)}">
    <div class="stodo-top">
      <span class="stodo-cat">${sEsc(r.category || '其他')}</span>
      ${r.hospital && r.hospital !== '未填' ? `<span class="stodo-meta" style="margin:0">${sEsc(r.hospital)}</span>` : ''}
      ${carriedEl}
    </div>
    <div class="stodo-content">${sEsc(r.content || (isTicket ? r.ticket_title : '') || '(無內容)')}</div>
    ${needInfo}
    <div class="stodo-foot"><span class="info"></span>${acts}</div>
  </div>`;
}
function sectionHtml(title, cls, rows){
  if (!rows.length) return '';
  return `<div class="stodo-sec-h ${cls}">${title}<span class="n">${rows.length}</span></div>
    <div class="stodo-list">${rows.map(todoCard).join('')}</div>`;
}
function renderTodo(){
  const el = document.getElementById('mod-todo');
  if (!el) return;
  const rows = TSTATE.rows;
  // §4 分組(排序已在 query 端 carried_days DESC)
  const done    = rows.filter(r => r.is_done);
  const pending = rows.filter(r => !r.is_done && !r.skip_reason);
  const skipped = rows.filter(r => r.skip_reason);
  const dateStr = new Date().toLocaleDateString('zh-TW', { month:'long', day:'numeric', weekday:'short' });

  let body = '';
  body += sectionHtml('⏳ 待辦', 'pend', pending);
  body += sectionHtml('⏭ 沒跑', 'skip', skipped);
  body += sectionHtml('✅ 完成', 'done', done);
  if (!rows.length) body = `<div class="stodo-empty">今日沒有待辦事項。用「＋ 新增」或「＋ 批次新增」加入。</div>`;

  el.innerHTML = `
    <div class="page-header"><div><div class="breadcrumb">MedSec Hub / 業祕 / 我的待辦</div><h1>我的待辦 · ${sEsc(dateStr)}</h1></div></div>
    <div class="stodo-head">
      <div class="info" style="font-size:13px;color:#475569">待辦 <b>${pending.length}</b> · 完成 <b>${done.length}</b> · 沒跑 <b>${skipped.length}</b></div>
      <div class="acts">
        <button class="stodo-btn primary" onclick="todoAdd()">＋ 新增</button>
        <button class="stodo-btn ghost" onclick="todoBatch()">＋ 批次新增</button>
        <button class="stodo-btn soft" onclick="todoRefresh()">↻ 重新整理</button>
      </div>
    </div>
    ${body}`;
}

// ---- 完成 / 沒跑(純 schedule,直寫 is_done / skip_reason;RLS 保護)----
async function todoComplete(rowId){
  const { error } = await supa.from(STD.table)
    .update({ is_done: true, done_at: new Date().toISOString() })
    .eq('id', rowId);
  if (error){ sToast('完成失敗:' + (error.message||error), 'err'); return; }
  sToast('已完成', 'ok'); await todoRefresh();
}
async function todoSkip(rowId){
  const reason = await sAskText({ title:'標記沒跑', label:'沒跑理由(必填)', placeholder:'例:設備維修 / 客戶延期…', required:true });
  if (reason === undefined) return;
  const { error } = await supa.from(STD.table)
    .update({ skip_reason: reason, skipped_at: new Date().toISOString() })
    .eq('id', rowId);
  if (error){ sToast('標記失敗:' + (error.message||error), 'err'); return; }
  sToast('已標記沒跑', 'ok'); await todoRefresh();
}

// ---- 新增 / 批次(insert schedule_items;first_added_date 由 trigger 補)----
function _cleanLine(raw){
  let s = (raw || '').trim();
  if (!s) return null;
  s = s.replace(/^[\-\*•・\.\)、，,]\s*/, '');   // 前綴符號 - * • ・ . ) 、 ,
  s = s.replace(/^[✓✗✘]\s*/, '');                  // 前綴 ✓ ✗ ✘
  s = s.replace(/^[\u{1F300}-\u{1FAFF}]\s*/u, '');                // 前綴 emoji
  s = s.replace(/^\d+[\.\)、]\s*/, '');                       // 前綴 1. 1) 1、
  s = s.trim();
  return s || null;
}
function _insertRows(items){
  const me = sMe(), today = sToday();
  return items.map(it => ({
    user_id: me.id, date: today, is_done: false,
    hospital: '未填', action: '(業秘庶務)',
    activities: [{ type: it.type || '其他', content: it.content }],
  }));
}
async function todoAdd(){
  const r = await sAddSheet();
  if (!r) return;
  const { error } = await supa.from(STD.table).insert(_insertRows([{ type: r.type, content: r.content }]));
  if (error){ sToast('新增失敗:' + (error.message||error), 'err'); return; }
  sToast('已新增', 'ok'); await todoRefresh();
}
async function todoBatch(){
  const r = await sBatchSheet();
  if (!r) return;
  const lines = r.text.split('\n').map(_cleanLine).filter(Boolean);
  if (!lines.length){ sToast('沒有可新增的行', 'err'); return; }
  const type = r.type || '其他';
  const { data, error } = await supa.from(STD.table).insert(_insertRows(lines.map(content => ({ type, content })))).select('id');
  if (error){ sToast('批次新增失敗:' + (error.message||error), 'err'); return; }
  sToast(`已新增 ${data ? data.length : lines.length} 條`, 'ok'); await todoRefresh();
}

// ---- 工單條目(v2 · C1 今日進度 / C3 結案)----
async function todoTicketProgress(ticketId){
  const note = await sAskText({ title:'記今日進度', label:'今天做了什麼(記日誌,不動工單狀態)', placeholder:'例:已提供健保報價單,待客戶回覆…', required:true });
  if (note === undefined) return;
  const me = sMe();
  const { error } = await supa.from(STD.table).insert({
    user_id: me.id, date: sToday(), is_done: true, done_at: new Date().toISOString(),
    hospital: '未填', action: '(業秘處理工單)', ticket_id: ticketId,
    activities: [{ type: '其他', content: '今日進度:' + note }],
  });
  if (error){ sToast('記錄失敗:' + (error.message||error), 'err'); return; }
  sToast('已記今日進度', 'ok'); await todoRefresh();
}
async function todoTicketResolve(ticketId, seq){
  const note = await sAskText({ title:`結案工單${seq?' #'+seq:''}`, label:'結案說明 ＊(業務會看到)', placeholder:'例:已提供健保報價單,價格如附…', required:true });
  if (note === undefined) return;
  const { error } = await supa.rpc(STD.ticketRpc, { p_ticket_id: ticketId, p_action: 'resolve', p_note: note, p_rating: null });
  if (error){ sToast('結案失敗:' + (error.message||error), 'err'); return; }
  sToast('已結案,待業務確認', 'ok'); await todoRefresh();
}
function todoOpenTicket(rowId){ sToast('工單詳情整合於 v2', 'ok'); }

// ---- 輕量 modal(text / add / batch)----
function sAskText(opts){
  return new Promise(resolve => {
    sInjectCss();
    const mask = document.createElement('div'); mask.className = 'stodo-mask';
    mask.innerHTML = `<div class="stodo-modal"><h3>${sEsc(opts.title)}</h3>
      <label>${sEsc(opts.label||'')}</label>
      <textarea id="stodo-in" rows="3" placeholder="${sEsc(opts.placeholder||'')}"></textarea>
      <div class="row"><button class="cancel" type="button">取消</button><button class="ok" type="button"${opts.required?' disabled':''}>確認</button></div></div>`;
    document.body.appendChild(mask);
    const ta = mask.querySelector('#stodo-in'), okB = mask.querySelector('.ok');
    let closed = false; const close = v => { if (closed) return; closed = true; document.body.removeChild(mask); resolve(v); };
    if (opts.required) ta.addEventListener('input', () => { okB.disabled = !ta.value.trim(); });
    mask.querySelector('.cancel').onclick = () => close(undefined);
    okB.onclick = () => { const v = ta.value.trim(); if (opts.required && !v) return; close(v); };
    ta.addEventListener('keydown', e => { if (e.key === 'Escape') close(undefined); });
    mask.addEventListener('mousedown', e => { if (e.target === mask) close(undefined); });
    setTimeout(() => ta.focus(), 0);
  });
}
function _catOptions(withPlaceholder){
  const opts = STD.categories.map(c => `<option value="${sEsc(c)}">${sEsc(c)}</option>`).join('');
  return (withPlaceholder ? `<option value="">單獨後補(其他)</option>` : '') + opts;
}
function sAddSheet(){
  return new Promise(resolve => {
    sInjectCss();
    const mask = document.createElement('div'); mask.className = 'stodo-mask';
    mask.innerHTML = `<div class="stodo-modal"><h3>新增待辦</h3>
      <label>類別</label>
      <select id="stodo-cat">${_catOptions(false)}</select>
      <label>內容</label>
      <textarea id="stodo-content" rows="3" placeholder="例:淡水馬偕報刀品出貨"></textarea>
      <div class="row"><button class="cancel" type="button">取消</button><button class="ok" type="button" disabled>加入</button></div></div>`;
    document.body.appendChild(mask);
    const cat = mask.querySelector('#stodo-cat'), content = mask.querySelector('#stodo-content'), okB = mask.querySelector('.ok');
    let closed = false; const close = v => { if (closed) return; closed = true; document.body.removeChild(mask); resolve(v); };
    content.addEventListener('input', () => { okB.disabled = !content.value.trim(); });
    mask.querySelector('.cancel').onclick = () => close(null);
    okB.onclick = () => { const c = content.value.trim(); if (!c) return; close({ type: cat.value, content: c }); };
    mask.addEventListener('mousedown', e => { if (e.target === mask) close(null); });
    setTimeout(() => content.focus(), 0);
  });
}
function sBatchSheet(){
  return new Promise(resolve => {
    sInjectCss();
    const mask = document.createElement('div'); mask.className = 'stodo-mask';
    mask.innerHTML = `<div class="stodo-modal"><h3>批次新增(一行一條)</h3>
      <label>清單(貼上,一行一條)</label>
      <textarea id="stodo-batch" rows="6" placeholder="淡水馬偕報刀品出貨\n北馬訂單出貨\n聖馬報價單提供醫院"></textarea>
      <label>全部套用類型</label>
      <select id="stodo-bcat">${_catOptions(true)}</select>
      <div class="row"><button class="cancel" type="button">取消</button><button class="ok" type="button" disabled>加入</button></div></div>`;
    document.body.appendChild(mask);
    const ta = mask.querySelector('#stodo-batch'), cat = mask.querySelector('#stodo-bcat'), okB = mask.querySelector('.ok');
    let closed = false; const close = v => { if (closed) return; closed = true; document.body.removeChild(mask); resolve(v); };
    const upd = () => { const n = ta.value.split('\n').map(_cleanLine).filter(Boolean).length; okB.disabled = n === 0; okB.textContent = n ? `加入 ${n} 條` : '加入'; };
    ta.addEventListener('input', upd);
    mask.querySelector('.cancel').onclick = () => close(null);
    okB.onclick = () => { if (!ta.value.trim()) return; close({ text: ta.value, type: cat.value }); };
    mask.addEventListener('mousedown', e => { if (e.target === mask) close(null); });
    setTimeout(() => ta.focus(), 0);
  });
}
