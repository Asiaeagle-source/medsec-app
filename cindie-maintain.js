/* ============================================================
   cindie-maintain.js — Cindie 產品主檔維護(交期 / 庫存)共用邏輯
   由 cindie-delivery.html / cindie-inventory.html 各自帶 CINDIE_CFG
   後呼叫 initCindieMaintain()。依賴 medsec-common.js(supa 等)
   + SheetJS(XLSX,.xlsx 解析,CDN)。
   ============================================================ */
let CM = null;          // 目前 config
let CM_PROFILE = null;  // 登入者
let CM_PARSED = null;   // 解析後待套用的列

function cmEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"]/g, c =>
    ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
}
function cmCoerce(col, v) {
  if (v == null || v === '') return col.type === 'bool' ? false : null;
  v = String(v).trim();
  if (col.type === 'int') { const n = parseInt(v, 10); return Number.isFinite(n) ? n : null; }
  if (col.type === 'num') { const n = Number(v); return Number.isFinite(n) ? n : null; }
  if (col.type === 'bool') return /^(true|1|y|yes|是|延遲|停產|discontinued)$/i.test(v);
  return v;
}

async function initCindieMaintain(cfg) {
  CM = cfg;
  // 自訂守門:Lynn(manager,全域職代)或 Cindie(purchasing)才可進
  const { data: { session } } = await supa.auth.getSession();
  if (!session) { location.href = 'login.html'; return; }
  const { data: profile } = await supa.from('profiles')
    .select('id, employee_id, name, nickname, medsec_role, has_medsec_access')
    .eq('id', session.user.id).single();
  if (!profile || !profile.has_medsec_access ||
      !['manager', 'purchasing'].includes(profile.medsec_role)) {
    alert('您沒有此頁的維護權限'); location.href = 'login.html'; return;
  }
  CM_PROFILE = profile;
  const nm = document.getElementById('cm-user'); if (nm) nm.textContent = profile.nickname || profile.name || '';
  document.getElementById('cm-h1').textContent = cfg.title;
  document.getElementById('cm-bc').textContent = cfg.breadcrumb;
  if (typeof hideLoading === 'function') hideLoading();
  buildTableHead();
  loadRows();
}

function cmListCols() { return CM.listColumns || CM.columns; }

function buildTableHead() {
  document.getElementById('cm-thead').innerHTML =
    '<tr>' + cmListCols().map(c => `<th>${cmEsc(c.label)}</th>`).join('') + '<th style="width:70px">操作</th></tr>';
}

let CM_DATA = [];
let CM_FILTER = 'all';

function renderFilters() {
  const box = document.getElementById('cm-filters');
  if (!box || !CM.filters) return;
  box.innerHTML = CM.filters.map(f =>
    `<button class="qm-pill ${CM_FILTER === f.key ? 'active' : ''}" onclick="cmSetFilter('${f.key}')">${f.label}</button>`
  ).join('');
}
function cmSetFilter(k) { CM_FILTER = k; renderFilters(); renderRows(); }

function renderRows() {
  const tb = document.getElementById('cm-tbody');
  const f = (CM.filters || []).find(x => x.key === CM_FILTER);
  const rows = (f && f.match) ? CM_DATA.filter(f.match) : CM_DATA;
  document.getElementById('cm-count').textContent =
    `${rows.length} 筆${CM_DATA.length !== rows.length ? ` / 共 ${CM_DATA.length}` : ''}`;
  if (rows.length === 0) {
    tb.innerHTML = `<tr><td colspan="${cmListCols().length + 1}" class="case-empty">沒有符合的資料</td></tr>`;
    return;
  }
  tb.innerHTML = rows.map(r => '<tr>' + cmListCols().map(c => {
    if (c.derived && CM.derived && CM.derived[c.derived]) return `<td>${CM.derived[c.derived](r)}</td>`;
    if (c.fmt) return `<td>${cmEsc(c.fmt(r[c.key], r))}</td>`;
    let v = r[c.key];
    if (c.type === 'bool') v = v ? '是' : '—';
    else if (v == null || v === '') v = '—';
    return `<td>${cmEsc(v)}</td>`;
  }).join('') + `<td><button class="btn-copy" onclick='cmEdit(${JSON.stringify(JSON.stringify(r))})'>編輯</button></td></tr>`).join('');
}

async function loadRows() {
  const tb = document.getElementById('cm-tbody');
  tb.innerHTML = `<tr><td colspan="${cmListCols().length + 1}" class="case-empty">載入中…</td></tr>`;
  const kw = (document.getElementById('cm-search').value || '').trim();
  let q = supa.from(CM.table).select('*').order('updated_at', { ascending: false }).limit(2000);
  if (kw) q = q.ilike('product_code', `%${kw}%`);
  const { data, error } = await q;
  if (error) { tb.innerHTML = `<tr><td colspan="${cmListCols().length + 1}" class="case-empty">載入失敗:${error.message}</td></tr>`; return; }
  CM_DATA = data || [];
  if (CM_DATA.length === 0) {
    document.getElementById('cm-count').textContent = '0 筆';
    tb.innerHTML = `<tr><td colspan="${cmListCols().length + 1}" class="case-empty">尚無資料,點「上傳」或「新增單筆」</td></tr>`;
    return;
  }
  renderFilters();
  renderRows();
}

/* ---------- 單筆新增 / 編輯 ---------- */
function cmNew() { openEditModal(null); }
function cmEdit(json) { openEditModal(JSON.parse(JSON.parse(json))); }

function openEditModal(row) {
  const isNew = !row;
  document.getElementById('cm-edit-title').textContent = isNew ? '新增單筆' : `編輯 ${row.product_code}`;
  document.getElementById('cm-edit-body').innerHTML = CM.columns.map(c => {
    const val = row ? (row[c.key] == null ? '' : row[c.key]) : '';
    const ro = (c.key === 'product_code' && !isNew) ? 'readonly' : '';
    if (c.type === 'bool')
      return `<label style="display:block;margin:8px 0;font-size:13px">
        <input type="checkbox" class="cm-f" data-k="${c.key}" ${val ? 'checked' : ''}> ${cmEsc(c.label)}</label>`;
    if (c.type === 'enum')
      return `<div style="margin:8px 0"><label style="font-size:12px;color:var(--text-muted)">${cmEsc(c.label)}</label>
        <select class="rc-text-input cm-f" data-k="${c.key}">
          ${c.options.map(o => `<option value="${o}" ${String(val) === o ? 'selected' : ''}>${o}</option>`).join('')}</select></div>`;
    const t = c.type === 'date' ? 'date' : (c.type === 'int' || c.type === 'num') ? 'number' : 'text';
    return `<div style="margin:8px 0"><label style="font-size:12px;color:var(--text-muted)">${cmEsc(c.label)}${c.required ? ' *' : ''}</label>
      <input type="${t}" class="rc-text-input cm-f" data-k="${c.key}" value="${cmEsc(val)}" ${ro}></div>`;
  }).join('');
  document.getElementById('cm-edit-modal').hidden = false;
}

async function cmSaveEdit() {
  const rec = { updated_by: CM_PROFILE.id };
  document.querySelectorAll('#cm-edit-body .cm-f').forEach(el => {
    const k = el.dataset.k;
    const col = CM.columns.find(c => c.key === k);
    rec[k] = (el.type === 'checkbox') ? el.checked : cmCoerce(col, el.value);
  });
  if (!rec.product_code) { alert('品號必填'); return; }
  const { error } = await supa.from(CM.table).upsert(rec, { onConflict: 'product_code' });
  if (error) { alert('儲存失敗:' + error.message); return; }
  document.getElementById('cm-edit-modal').hidden = true;
  loadRows();
}

/* ---------- 上傳:檔案 / 貼上 → 解析預覽 → 套用 ---------- */
function cmOpenUpload() {
  document.getElementById('cm-up-paste').value = '';
  document.getElementById('cm-up-preview').innerHTML =
    `<div class="rc-question-help">表頭請含品號欄(可用「品號」或 <code>product_code</code>)。`
    + `可辨識欄位:${CM.columns.map(c => `${c.label}/<code>${c.key}</code>`).join('、')}</div>`;
  CM_PARSED = null;
  document.getElementById('cm-up-apply').disabled = true;
  document.getElementById('cm-upload-modal').hidden = false;
}

function cmHeaderIndex(header) {
  // 表頭名 → 欄位 key(接受中文 label 或英文 key,大小寫/空白不敏感)
  const norm = s => String(s || '').trim().toLowerCase();
  const idx = {};
  CM.columns.forEach(c => {
    const names = [c.key, c.label, ...(c.aliases || [])].map(norm);
    const h = header.findIndex(x => names.includes(norm(x)));
    idx[c.key] = h;
  });
  return idx;
}

const CM_TOTAL_RE = /^(總和|總計|合計|小計|總數|total|sum)$/i;

function cmRowsFromMatrix(matrix) {
  const rows = matrix.filter(r => r && r.some(c => String(c).trim() !== ''));
  if (rows.length < 2) return { rows: [], bad: 0 };
  // 動態找表頭列:第一個含「品號 / product_code」的列(前面若有「總和」摘要列就跳過)
  let hi = -1, idx = null;
  for (let i = 0; i < rows.length; i++) {
    const cand = cmHeaderIndex(rows[i].map(x => String(x)));
    if (cand.product_code >= 0) { hi = i; idx = cand; break; }
  }
  if (hi < 0) return { error: '表頭找不到「品號 / product_code」欄' };
  const out = [], skip = [];
  for (let i = hi + 1; i < rows.length; i++) {
    const f = rows[i];
    const rec = { updated_by: CM_PROFILE.id };
    CM.columns.forEach(c => { if (idx[c.key] >= 0) rec[c.key] = cmCoerce(c, f[idx[c.key]]); });
    const code = rec.product_code == null ? '' : String(rec.product_code).trim();
    // 跳:無品號 / 總和摘要列(品號或第一格為 總和/合計/total…)
    if (!code || CM_TOTAL_RE.test(code) || CM_TOTAL_RE.test(String(f[0] || '').trim())) {
      skip.push(i); continue;
    }
    out.push(rec);
  }
  return { rows: out, bad: skip.length };
}

function cmParseCsvText(txt) {
  const sep = txt.indexOf('\t') >= 0 ? '\t' : ',';   // Excel 複製貼上 = tab
  return txt.split(/\r?\n/).map(line => {
    if (sep === '\t') return line.split('\t');
    const out = []; let cur = '', q = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (q) { if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
               else if (ch === '"') q = false; else cur += ch; }
      else { if (ch === '"') q = true; else if (ch === ',') { out.push(cur); cur = ''; } else cur += ch; }
    }
    out.push(cur); return out;
  });
}

async function cmPreview(matrix) {
  const res = cmRowsFromMatrix(matrix);
  const box = document.getElementById('cm-up-preview');
  if (res.error) { box.innerHTML = `<div class="case-empty">${res.error}</div>`; return; }
  if (res.rows.length === 0) { box.innerHTML = '<div class="case-empty">沒有可匯入的資料列</div>'; return; }
  // 對 medsec_products 主檔標 ✓ / ⚠
  const codes = [...new Set(res.rows.map(r => r.product_code))];
  const { data: prod } = await supa.from('medsec_products').select('id, name').in('id', codes);
  const master = {}; (prod || []).forEach(p => { master[p.id] = p.name; });
  CM_PARSED = res.rows;
  box.innerHTML = `
    <div style="font-size:13px;margin-bottom:6px">解析 <b>${res.rows.length}</b> 列${res.bad ? ` · ${res.bad} 列略過(無品號)` : ''}
      · <span style="color:var(--success,#16a34a)">✓ 主檔有</span> / <span style="color:var(--warning,#d97706)">⚠ 主檔查無(仍可匯)</span></div>
    <table class="case-list"><thead><tr><th>對應</th>${CM.columns.map(c => `<th>${cmEsc(c.label)}</th>`).join('')}</tr></thead>
      <tbody>${res.rows.slice(0, 30).map(r => `<tr>
        <td>${master[r.product_code] ? '✓' : '⚠'}</td>
        ${CM.columns.map(c => `<td>${r[c.key] == null ? '—' : (c.type === 'bool' ? (r[c.key] ? '是' : '—') : cmEsc(r[c.key]))}</td>`).join('')}
      </tr>`).join('')}</tbody></table>
    ${res.rows.length > 30 ? `<div style="font-size:12px;color:#888">只顯示前 30 列,套用全部 ${res.rows.length} 列</div>` : ''}`;
  document.getElementById('cm-up-apply').disabled = false;
}

function cmParsePasted() {
  const txt = document.getElementById('cm-up-paste').value.trim();
  if (!txt) { alert('先貼上內容或拖檔'); return; }
  cmPreview(cmParseCsvText(txt));
}

function cmHandleFile(file) {
  if (!file) return;
  const name = (file.name || '').toLowerCase();
  if (name.endsWith('.xlsx') || name.endsWith('.xls')) {
    if (typeof XLSX === 'undefined') { alert('Excel 解析元件未載入,請改存成 CSV 或貼上'); return; }
    const fr = new FileReader();
    fr.onload = e => {
      const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
      const ws = wb.Sheets[wb.SheetNames[0]];
      cmPreview(XLSX.utils.sheet_to_json(ws, { header: 1, raw: false, defval: '' }));
    };
    fr.readAsArrayBuffer(file);
  } else {
    const fr = new FileReader();
    fr.onload = e => cmPreview(cmParseCsvText(String(e.target.result)));
    fr.readAsText(file, 'utf-8');
  }
}

async function cmApply() {
  if (!CM_PARSED || CM_PARSED.length === 0) return;
  const btn = document.getElementById('cm-up-apply');
  if (!confirm(`套用 ${CM_PARSED.length} 列到 ${CM.table}?(重複品號會覆蓋)`)) return;
  btn.disabled = true; btn.textContent = '套用中…';
  // 標記本批 Excel 匯入時間(config 指定欄位才寫)
  if (CM.uploadStamp) {
    const ts = new Date().toISOString();
    CM_PARSED.forEach(r => { r[CM.uploadStamp] = ts; });
  }
  // 分批 upsert,避免單批過大
  let done = 0, err = null;
  for (let i = 0; i < CM_PARSED.length; i += 500) {
    const chunk = CM_PARSED.slice(i, i + 500);
    const { error } = await supa.from(CM.table).upsert(chunk, { onConflict: 'product_code' });
    if (error) { err = error; break; }
    done += chunk.length;
  }
  btn.disabled = false; btn.textContent = `套用 ${CM_PARSED.length} 列`;
  if (err) { alert(`已套用 ${done} 列後失敗:${err.message}`); }
  else { alert(`已套用 ${done} 列`); document.getElementById('cm-upload-modal').hidden = true; }
  CM_PARSED = null;
  loadRows();
}

/* 拖曳綁定(頁面載入後呼叫一次)*/
function cmBindDrop() {
  const dz = document.getElementById('cm-dropzone');
  if (!dz) return;
  ['dragover', 'dragenter'].forEach(ev => dz.addEventListener(ev, e => {
    e.preventDefault(); dz.classList.add('dz-over');
  }));
  ['dragleave', 'drop'].forEach(ev => dz.addEventListener(ev, e => {
    e.preventDefault(); dz.classList.remove('dz-over');
  }));
  dz.addEventListener('drop', e => {
    const f = e.dataTransfer.files && e.dataTransfer.files[0];
    if (f) cmHandleFile(f);
  });
}
