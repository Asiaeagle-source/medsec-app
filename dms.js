// ============================================================
// dms.js · V2.3 寄賣對帳(secretary.html #mod-dms)
// ------------------------------------------------------------
// 權限:has_dms_access 或 medsec_role IN (manager,accounting)。無權者入口隱藏
//   (pre-flight 讀 profiles.has_dms_access;欄位/權限不存在 → 視為無權)。
// Phase 1:a) 刀表上傳(xlsx, SheetJS, header 在第 2 列) b) 對帳單建立(手動行項)
//          c) 媒合結果(依 material_code_map 聚合當期,雙基準 sale/surgery 並列,
//             吻合綠/差異橘,差異項展開前後 45 天跨月候選)。
// AI 抽取留 Phase 2。SQL 由 Lynn 審後執行,欄名/表名集中在 DMS。
// ============================================================
const DMS = {
  csTable: 'consignment_sales', stmtTable: 'recon_statements',
  itemTable: 'recon_statement_items', mapTable: 'material_code_map',
  bucket: 'dms-files', crossDays: 45,
  // 刀表 xlsx 欄位別名(header 第 2 列;中文表頭 → 欄位)。實際刀表表頭可在此擴充。
  csAliases: {
    sales_rep:   ['業務','業務員','業務代表'],
    sale_date:   ['銷貨日','銷售日','出貨日','銷貨日期'],
    order_no:    ['訂單號','訂單編號','單號','訂單'],
    surgery_date:['手術日','手術日期','開刀日','手術'],
    customer:    ['客戶','醫院','客戶名稱','醫院名稱'],
    doctor:      ['醫師','醫生','doctor'],
    product_no:  ['品號','產品編號','料號','產品品號'],
    qty:         ['數量','qty','數'],
    follower:    ['跟刀','跟台','跟刀人員'],
    patient:     ['病患','病人','患者','病患姓名'],
    lot_serial:  ['批號序號','批號/序號','批號','序號','lot'],
    amount:      ['金額','小計','amount','銷貨金額'],
    category3:   ['分類三','分類3','category3','大類'],
  },
};

let DSTATE = { access:false, tab:'upload', parsed:[], headerMap:{}, period:'',
  statements:[], maps:[], sales:[], curStmt:null, matchRows:[] };

function dToday(){ return new Date().toISOString().slice(0,10); }
function dPeriodNow(){ const d=new Date(); return `${d.getFullYear()}${String(d.getMonth()+1).padStart(2,'0')}`; }
function dEsc(s){ return String(s==null?'':s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function dMe(){ return (typeof currentProfile!=='undefined') ? currentProfile : null; }
function dNum(v){ const n=Number(String(v==null?'':v).replace(/[, ]/g,'')); return isFinite(n)?n:0; }
function dDateStr(v){ // Excel 日期(數字或字串)→ yyyy-mm-dd
  if(v==null||v==='') return null;
  if(typeof v==='number' && window.XLSX && XLSX.SSF){ const o=XLSX.SSF.parse_date_code(v); if(o) return `${o.y}-${String(o.m).padStart(2,'0')}-${String(o.d).padStart(2,'0')}`; }
  const s=String(v).trim().replace(/\//g,'-'); const m=s.match(/(\d{4})-(\d{1,2})-(\d{1,2})/); return m?`${m[1]}-${String(m[2]).padStart(2,'0')}-${String(m[3]).padStart(2,'0')}`:s;
}
function dPeriodOf(dateStr){ if(!dateStr) return null; const m=String(dateStr).match(/(\d{4})-(\d{2})/); return m?m[1]+m[2]:null; }

// ---- 純邏輯(可單元測試) ----
// SQL LIKE 樣式(% → .*, _ → .)轉 regex 比對品號
function dLike(val, pattern){
  if(val==null) return false;
  const re = '^' + String(pattern).replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/%/g,'.*').replace(/_/g,'.') + '$';
  try{ return new RegExp(re,'i').test(String(val)); }catch(e){ return false; }
}
function dProductMatches(productNo, map){
  if(!productNo || !map) return false;
  const pats = map.product_no_pattern||[], excl = map.exclude_products||[];
  if(excl.some(x => String(x)===String(productNo))) return false;
  return pats.some(p => dLike(productNo, p));
}
// 期別月份範圍
function dPeriodRange(period){
  const y=+period.slice(0,4), m=+period.slice(4,6);
  const first=new Date(Date.UTC(y,m-1,1)), last=new Date(Date.UTC(y,m,0));
  return { first, last };
}
function dInPeriod(dateStr, period){ return dPeriodOf(dateStr)===period; }
function dInWindow(dateStr, period, days){
  if(!dateStr) return false;
  const {first,last}=dPeriodRange(period);
  const lo=new Date(first.getTime()-days*864e5), hi=new Date(last.getTime()+days*864e5);
  const t=new Date(dateStr+'T00:00:00Z').getTime();
  return t>=lo.getTime() && t<=hi.getTime();
}
// 媒合單一 item:雙基準當期加總 + 跨月候選(±45 天,期外)
function dMatchItem(item, sales, map){
  const matched = (map ? sales.filter(s=>dProductMatches(s.product_no, map)) : []);
  const saleSum    = matched.filter(s=>dInPeriod(s.sale_date, item._period)).reduce((a,s)=>a+dNum(s.qty),0);
  const surgerySum = matched.filter(s=>dInPeriod(s.surgery_date, item._period)).reduce((a,s)=>a+dNum(s.qty),0);
  const qty = dNum(item.qty);
  const ok = (saleSum===qty || surgerySum===qty) && qty>0;
  const matched_qty = saleSum;                 // 主基準:銷貨日
  const diff = qty - matched_qty;
  // 跨月候選:命中 pattern、期外、但落在 ±45 天窗內(任一基準)
  const candidates = matched.filter(s =>
    (!dInPeriod(s.sale_date,item._period) && !dInPeriod(s.surgery_date,item._period)) &&
    (dInWindow(s.sale_date,item._period,DMS.crossDays) || dInWindow(s.surgery_date,item._period,DMS.crossDays))
  );
  return { saleSum, surgerySum, matched_qty, diff, status: ok?'ok':(map?'diff':'pending'), candidates, hasMap: !!map };
}
function dBuildHeaderMap(headers){
  const map={};
  (headers||[]).forEach(h=>{
    const hs=String(h||'').trim();
    for(const [field,aliases] of Object.entries(DMS.csAliases)){
      if(map[field]) continue;
      if(aliases.some(a=>hs===a || hs.replace(/\s/g,'').includes(a))) map[field]=h;
    }
  });
  return map;
}
function dMapRow(raw, headerMap, extra){
  const g=f=> headerMap[f]!=null ? raw[headerMap[f]] : undefined;
  return {
    period: extra.period, source_file: extra.source_file,
    sales_rep: g('sales_rep')||null, sale_date: dDateStr(g('sale_date')), order_no: g('order_no')||null,
    surgery_date: dDateStr(g('surgery_date')), customer: g('customer')||null, doctor: g('doctor')||null,
    product_no: g('product_no')!=null?String(g('product_no')).trim():null, qty: dNum(g('qty')),
    follower: g('follower')||null, patient: g('patient')||null, lot_serial: g('lot_serial')!=null?String(g('lot_serial')):null,
    amount: dNum(g('amount')), category3: g('category3')||null,
  };
}

// ---- 樣式 + toast ----
function dInjectCss(){
  if(document.getElementById('dms-css')) return;
  const css=`
  .dms-tabs{display:flex;gap:20px;border-bottom:1px solid #e8e9ef;margin:8px 0 20px}
  .dms-tab{font-size:14.5px;color:#475569;padding:0 2px 11px;cursor:pointer;border:0;background:none;border-bottom:2px solid transparent;font-family:inherit}
  .dms-tab.on{color:#2563eb;border-bottom-color:#2563eb;font-weight:600}
  .dms-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
  .dms-btn{font-size:13px;font-family:inherit;border-radius:9px;padding:8px 14px;cursor:pointer;border:1px solid transparent;font-weight:600}
  .dms-btn.primary{color:#fff;background:#2563eb;border-color:#2563eb}.dms-btn.ghost{color:#2563eb;background:#eef4ff;border-color:#d3e0fb}.dms-btn.soft{color:#475569;background:#f1f3f7}
  .dms-btn:disabled{opacity:.5;cursor:default}
  .dms-inp{font-family:inherit;font-size:13.5px;padding:8px 11px;border:1px solid #dfe3ea;border-radius:9px;outline:none}
  .dms-inp:focus{border-color:#2563eb}
  .dms-card{background:#fff;border:1px solid #e8e9ef;border-radius:12px;padding:14px 16px;margin-bottom:10px}
  .dms-tbl{width:100%;border-collapse:collapse;font-size:12.5px}
  .dms-tbl th{text-align:left;color:#6b7280;font-weight:600;padding:6px 8px;border-bottom:1px solid #e8e9ef;white-space:nowrap}
  .dms-tbl td{padding:6px 8px;border-bottom:1px solid #f1f3f7;color:#334155}
  .dms-tbl tr.ok{background:#f2faf5}.dms-tbl tr.diff{background:#fff7ec}
  .dms-scroll{overflow-x:auto}
  .dms-pill{font-size:11px;padding:2px 9px;border-radius:7px;font-weight:600}
  .dms-pill.ok{background:#eaf7ee;color:#1a7f45}.dms-pill.diff{background:#fdf3df;color:#c2790b}.dms-pill.pending{background:#eef0f4;color:#6b7280}
  .dms-pill.draft{background:#eef0f4;color:#6b7280}.dms-pill.matched{background:#eef4ff;color:#2563eb}.dms-pill.confirmed{background:#eaf7ee;color:#1a7f45}
  .dms-drop{border:1.5px dashed #cbd5e1;border-radius:12px;padding:26px;text-align:center;color:#6b7280;font-size:13px;background:#f8fafc;cursor:pointer}
  .dms-cand{background:#fbfbfd;border-top:1px dashed #eaddc4}
  .dms-empty{background:#fff;border:1px dashed #e2e5ec;border-radius:12px;padding:20px;text-align:center;color:#9aa0ab;font-size:13px}
  .dms-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%);background:#1d2330;color:#fff;font-size:13px;padding:10px 18px;border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.2);z-index:90;opacity:0;pointer-events:none;transition:opacity .2s;max-width:80vw;text-align:center}
  .dms-toast.show{opacity:1}.dms-toast.err{background:#b3261e}.dms-toast.ok{background:#1a7f45}
  `;
  const el=document.createElement('style'); el.id='dms-css'; el.textContent=css; document.head.appendChild(el);
}
let _dToastT=null;
function dToast(msg,kind){ let t=document.getElementById('dms-toast'); if(!t){t=document.createElement('div');t.id='dms-toast';document.body.appendChild(t);} t.className='dms-toast '+(kind||'')+' show'; t.textContent=msg; clearTimeout(_dToastT); _dToastT=setTimeout(()=>{t.className='dms-toast '+(kind||'');},2600); }

// ---- 權限 pre-flight ----
async function dmsHasAccess(){
  const me=dMe(); if(!me) return false;
  if(me.medsec_role==='manager' || me.medsec_role==='accounting') return true;
  try{
    const { data, error } = await supa.from('profiles').select('has_dms_access').eq('id', me.id).maybeSingle();
    if(error) return false;                 // 欄位不存在 / 權限 → 無 DMS
    return !!(data && data.has_dms_access);
  }catch(e){ return false; }
}

// ---- 進模組(secretary.html 的 switchModule('dms') 會呼叫)----
let _dmsInit=null;
function ensureDmsModule(){
  if(!_dmsInit){ _dmsInit=(async()=>{ dInjectCss(); await Promise.all([dmsLoadMaps(), dmsLoadStatements()]); renderDms(); })(); }
  return _dmsInit;
}
async function dmsLoadMaps(){ const {data,error}=await supa.from(DMS.mapTable).select('*').eq('active',true); DSTATE.maps=error?[]:(data||[]); }
async function dmsLoadStatements(){ const {data,error}=await supa.from(DMS.stmtTable).select('*').order('created_at',{ascending:false}); DSTATE.statements=error?[]:(data||[]); }

// ---- render:三分頁 ----
function renderDms(){
  const el=document.getElementById('mod-dms'); if(!el) return;
  const tab=DSTATE.tab;
  el.innerHTML=`
    <div class="page-header"><div><div class="breadcrumb">MedSec Hub / 寄賣對帳</div><h1>寄賣對帳 (DMS)</h1></div></div>
    <div class="dms-tabs">
      <button class="dms-tab ${tab==='upload'?'on':''}" onclick="dmsTab('upload')">刀表上傳</button>
      <button class="dms-tab ${tab==='stmt'?'on':''}" onclick="dmsTab('stmt')">對帳單</button>
      <button class="dms-tab ${tab==='match'?'on':''}" onclick="dmsTab('match')">媒合結果</button>
    </div>
    <div id="dms-body"></div>`;
  const b=document.getElementById('dms-body');
  if(tab==='upload') b.innerHTML=viewUpload();
  else if(tab==='stmt') b.innerHTML=viewStatements();
  else b.innerHTML=viewMatch();
  if(tab==='upload') bindUpload();
}
function dmsTab(t){ DSTATE.tab=t; renderDms(); }

// ---- a. 刀表上傳 ----
function viewUpload(){
  const p=DSTATE.parsed, hm=DSTATE.headerMap;
  const mapped=Object.keys(hm);
  let preview='';
  if(p.length){
    const cols=['product_no','qty','sale_date','surgery_date','customer','order_no'];
    preview=`<div class="dms-card"><b>解析預覽</b>(共 ${p.length} 列;對到欄位:${mapped.map(dEsc).join(' / ')||'無'})
      <div class="dms-scroll"><table class="dms-tbl"><thead><tr>${cols.map(c=>`<th>${c}</th>`).join('')}</tr></thead>
      <tbody>${p.slice(0,8).map(r=>`<tr>${cols.map(c=>`<td>${dEsc(r[c])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      <div class="dms-row" style="margin-top:12px">
        <label>期別 <input id="dms-period" class="dms-inp" style="width:110px" value="${dEsc(DSTATE.period||dPeriodNow())}" placeholder="yyyymm"></label>
        <button class="dms-btn primary" onclick="dmsUploadCommit()">上傳 ${p.length} 列到 consignment_sales</button>
      </div></div>`;
  }
  return `<div class="dms-drop" id="dms-drop">把刀表 .xlsx 拖到這裡,或點此選檔<br><span style="font-size:12px">(表頭在第 2 列;欄位對應見 DMS.csAliases)</span>
    <input type="file" id="dms-file" accept=".xlsx,.xls,.csv" hidden></div>${preview}`;
}
function bindUpload(){
  const drop=document.getElementById('dms-drop'), inp=document.getElementById('dms-file');
  if(!drop||!inp) return;
  drop.onclick=()=>inp.click();
  inp.onchange=()=>{ if(inp.files&&inp.files[0]) dmsParseFile(inp.files[0]); };
  drop.ondragover=e=>{e.preventDefault();}; drop.ondrop=e=>{e.preventDefault(); if(e.dataTransfer.files[0]) dmsParseFile(e.dataTransfer.files[0]); };
}
async function dmsParseFile(file){
  if(!window.XLSX){ dToast('xlsx 解析庫未載入','err'); return; }
  try{
    const buf=await file.arrayBuffer();
    const wb=XLSX.read(buf,{type:'array',cellDates:false});
    const ws=wb.Sheets[wb.SheetNames[0]];
    const rows=XLSX.utils.sheet_to_json(ws,{range:1,defval:''});   // header 在第 2 列 → range:1
    if(!rows.length){ dToast('讀不到資料列','err'); return; }
    DSTATE.headerMap=dBuildHeaderMap(Object.keys(rows[0]));
    DSTATE._file=file; DSTATE._fileName=file.name;
    DSTATE.parsed=rows.map(r=>dMapRow(r, DSTATE.headerMap, {period:'', source_file:file.name})).filter(r=>r.product_no);
    if(!DSTATE.headerMap.product_no) dToast('找不到「品號」欄,請確認表頭在第 2 列','err');
    renderDms();
  }catch(e){ dToast('解析失敗:'+e.message,'err'); }
}
async function dmsUploadCommit(){
  const period=(document.getElementById('dms-period')||{}).value || dPeriodNow();
  if(!/^\d{6}$/.test(period)){ dToast('期別需 yyyymm','err'); return; }
  const rows=DSTATE.parsed.map(r=>({ ...r, period }));
  if(!rows.length){ dToast('沒有可上傳的列','err'); return; }
  // 私有 bucket 存原始檔(signed URL 讀);失敗不擋資料寫入
  let src=DSTATE._fileName||null;
  try{ if(DSTATE._file){ const path=`${period}/${Date.now()}-${(DSTATE._fileName||'sheet.xlsx').replace(/[\/\\]/g,'_')}`; const up=await supa.storage.from(DMS.bucket).upload(path,DSTATE._file); if(!up.error) src=path; } }catch(e){}
  const payload=rows.map(r=>({...r, source_file:src}));
  const { error } = await supa.from(DMS.csTable).insert(payload);
  if(error){ dToast('上傳失敗:'+(error.message||error),'err'); return; }
  dToast(`已上傳 ${payload.length} 列`,'ok');
  DSTATE.parsed=[]; DSTATE.period=period; renderDms();
}

// ---- b. 對帳單 ----
function viewStatements(){
  const list=DSTATE.statements;
  const rows=list.length? list.map(s=>`<div class="dms-card"><div class="dms-row" style="margin:0;justify-content:space-between">
    <div><b>${dEsc(s.statement_no||'(無單號)')}</b> · ${dEsc(s.vendor_name||s.vendor_code||'')} · ${dEsc(s.hospital||'')} <span class="dms-pill ${dEsc(s.status)}">${dEsc(s.status)}</span></div>
    <button class="dms-btn ghost" onclick="dmsGoMatch('${dEsc(s.id)}')">看媒合</button></div>
    <div style="font-size:12px;color:#9aa0ab;margin-top:5px">單據日 ${dEsc(s.statement_date||'—')} · 訂單 ${dEsc(s.order_no||'—')}</div></div>`).join('')
    : `<div class="dms-empty">尚無對帳單。按「＋ 新增對帳單」建立。</div>`;
  return `<div class="dms-row"><button class="dms-btn primary" onclick="dmsNewStatement()">＋ 新增對帳單</button></div>${rows}`;
}
async function dmsNewStatement(){
  const r=await dmsStatementSheet();
  if(!r) return;
  const me=dMe();
  const { data, error } = await supa.from(DMS.stmtTable).insert({
    vendor_code:r.vendor_code, vendor_name:r.vendor_name, statement_no:r.statement_no,
    statement_date:r.statement_date||null, hospital:r.hospital, order_no:r.order_no,
    status:'draft', created_by: me?me.id:null,
  }).select('id').maybeSingle();
  if(error||!data){ dToast('建立失敗:'+((error&&error.message)||''),'err'); return; }
  if(r.items.length){
    const items=r.items.map(it=>({ statement_id:data.id, material_code:it.material_code, item_name:it.item_name,
      spec:it.spec, unit:it.unit, qty:dNum(it.qty), match_status:'pending' }));
    const ins=await supa.from(DMS.itemTable).insert(items);
    if(ins.error){ dToast('行項寫入失敗:'+ins.error.message,'err'); }
  }
  dToast('對帳單已建立','ok');
  await dmsLoadStatements(); renderDms();
}

// ---- c. 媒合結果 ----
async function dmsGoMatch(stmtId){ DSTATE.tab='match'; renderDms(); await dmsRunMatch(stmtId); }
function viewMatch(){
  const opts=DSTATE.statements.map(s=>`<option value="${dEsc(s.id)}" ${DSTATE.curStmt&&DSTATE.curStmt.id===s.id?'selected':''}>${dEsc(s.statement_no||s.id)} · ${dEsc(s.vendor_name||s.vendor_code||'')}</option>`).join('');
  const picker=`<div class="dms-row"><label>對帳單 <select id="dms-stmt-pick" class="dms-inp" onchange="dmsRunMatch(this.value)"><option value="">選一張…</option>${opts}</select></label>
    ${DSTATE.curStmt?`<button class="dms-btn primary" onclick="dmsWriteBack()">寫回媒合結果</button>`:''}</div>`;
  if(!DSTATE.curStmt) return picker+`<div class="dms-empty">選一張對帳單以聚合當期刀表數量。</div>`;
  const mr=DSTATE.matchRows;
  if(!mr.length) return picker+`<div class="dms-empty">這張對帳單沒有行項。</div>`;
  const body=mr.map((m,i)=>{
    const cands=m.res.candidates;
    const candHtml=cands.length?`<tr class="dms-cand"><td colspan="7"><b>跨月候選(前後 ${DMS.crossDays} 天,共 ${cands.length} 筆)</b>
      <div class="dms-scroll"><table class="dms-tbl"><thead><tr><th>品號</th><th>數量</th><th>銷貨日</th><th>手術日</th><th>客戶</th><th>訂單</th></tr></thead>
      <tbody>${cands.map(c=>`<tr><td>${dEsc(c.product_no)}</td><td>${dEsc(c.qty)}</td><td>${dEsc(c.sale_date)}</td><td>${dEsc(c.surgery_date)}</td><td>${dEsc(c.customer)}</td><td>${dEsc(c.order_no)}</td></tr>`).join('')}</tbody></table></div></td></tr>`:'';
    return `<tr class="${m.res.status}">
      <td>${dEsc(m.item.material_code||'')}${m.res.hasMap?'':' <span class="dms-pill pending">無對照</span>'}</td>
      <td>${dEsc(m.item.item_name||m.map&&m.map.category_label||'')}</td>
      <td>${dEsc(m.item.qty)}</td>
      <td>${m.res.saleSum}</td><td>${m.res.surgerySum}</td>
      <td>${m.res.diff===0?'0':(m.res.diff>0?'+':'')+m.res.diff}</td>
      <td><span class="dms-pill ${m.res.status}">${m.res.status==='ok'?'吻合':m.res.status==='diff'?'差異':'待對'}</span>${cands.length?` <button class="dms-btn soft" style="padding:3px 9px" onclick="dmsToggleCand(${i})">候選 ${cands.length}</button>`:''}</td>
    </tr>${DSTATE._openCand===i?candHtml:''}`;
  }).join('');
  return picker+`<div class="dms-card dms-scroll"><table class="dms-tbl">
    <thead><tr><th>料號</th><th>品名/分類</th><th>對帳量</th><th>當期(銷貨日)</th><th>當期(手術日)</th><th>差異</th><th>狀態</th></tr></thead>
    <tbody>${body}</tbody></table></div>`;
}
function dmsToggleCand(i){ DSTATE._openCand = (DSTATE._openCand===i?null:i); renderDms(); }
async function dmsRunMatch(stmtId){
  if(!stmtId){ DSTATE.curStmt=null; DSTATE.matchRows=[]; renderDms(); return; }
  const stmt=DSTATE.statements.find(s=>s.id===stmtId); if(!stmt){ return; }
  DSTATE.curStmt=stmt; DSTATE._openCand=null;
  // 行項
  const { data:items } = await supa.from(DMS.itemTable).select('*').eq('statement_id',stmtId);
  // 期別:單據日的 yyyymm(無則本月)
  const period = dPeriodOf(stmt.statement_date) || dPeriodNow();
  // 當期 + 前後 45 天窗內的刀表(依 sale_date;surgery_date 另比)。這裡寬撈整個 vendor 的當期候選。
  const { data:sales } = await supa.from(DMS.csTable).select('*');   // Phase 1:全撈,前端依 pattern/期別過濾
  DSTATE.sales=sales||[];
  DSTATE.matchRows=(items||[]).map(it=>{
    const map=DSTATE.maps.find(mp => String(mp.material_code)===String(it.material_code) &&
      (!stmt.vendor_code || !mp.vendor_code || mp.vendor_code===stmt.vendor_code));
    it._period=period;
    const res=dMatchItem(it, DSTATE.sales, map);
    return { item:it, map, res };
  });
  renderDms();
}
async function dmsWriteBack(){
  if(!DSTATE.curStmt) return;
  let okAll=true;
  for(const m of DSTATE.matchRows){
    const { error } = await supa.from(DMS.itemTable).update({
      matched_qty:m.res.matched_qty, diff:m.res.diff, match_status:m.res.status,
    }).eq('id', m.item.id);
    if(error) okAll=false;
  }
  const anyDiff=DSTATE.matchRows.some(m=>m.res.status!=='ok');
  await supa.from(DMS.stmtTable).update({ status: anyDiff?'matched':'confirmed' }).eq('id', DSTATE.curStmt.id);
  dToast(okAll?'已寫回媒合結果':'部分寫回失敗', okAll?'ok':'err');
  await dmsLoadStatements(); await dmsRunMatch(DSTATE.curStmt.id);
}

// ---- 對帳單 modal(抬頭 + 動態行項)----
function dmsStatementSheet(){
  return new Promise(resolve=>{
    dInjectCss();
    const mask=document.createElement('div'); mask.className='stodo-mask'; mask.style.cssText='position:fixed;inset:0;background:rgba(15,23,42,.42);display:flex;align-items:center;justify-content:center;z-index:80';
    mask.innerHTML=`<div style="background:#fff;border-radius:14px;padding:22px;width:min(680px,94vw);max-height:90vh;overflow:auto;box-shadow:0 14px 44px rgba(0,0,0,.2)">
      <h3 style="margin:0 0 12px">新增對帳單</h3>
      <div class="dms-row">
        <input id="s-vc" class="dms-inp" placeholder="廠商代碼(如 R886)" style="width:150px">
        <input id="s-vn" class="dms-inp" placeholder="廠商名稱" style="width:170px">
        <input id="s-no" class="dms-inp" placeholder="對帳單號" style="width:150px">
        <input id="s-date" class="dms-inp" type="date" style="width:150px">
        <input id="s-hosp" class="dms-inp" placeholder="醫院" style="width:150px">
        <input id="s-order" class="dms-inp" placeholder="訂單號" style="width:150px">
      </div>
      <div style="font-weight:600;font-size:13px;margin:6px 0">行項</div>
      <div class="dms-scroll"><table class="dms-tbl" id="s-items"><thead><tr><th>料號</th><th>品名</th><th>規格</th><th>單位</th><th>數量</th><th></th></tr></thead><tbody></tbody></table></div>
      <button class="dms-btn soft" id="s-additem" style="margin-top:8px">＋ 加一行</button>
      <div class="dms-row" style="justify-content:flex-end;margin-top:16px">
        <button class="dms-btn soft" id="s-cancel">取消</button><button class="dms-btn primary" id="s-save">建立</button>
      </div></div>`;
    document.body.appendChild(mask);
    const tbody=mask.querySelector('#s-items tbody');
    const addRow=()=>{ const tr=document.createElement('tr'); tr.innerHTML=`<td><input class="dms-inp i-mc" style="width:100px"></td><td><input class="dms-inp i-name" style="width:120px"></td><td><input class="dms-inp i-spec" style="width:90px"></td><td><input class="dms-inp i-unit" style="width:60px"></td><td><input class="dms-inp i-qty" style="width:70px" inputmode="decimal"></td><td><button class="dms-btn soft i-del" style="padding:3px 8px">✕</button></td>`; tbody.appendChild(tr); tr.querySelector('.i-del').onclick=()=>tr.remove(); };
    addRow();
    mask.querySelector('#s-additem').onclick=addRow;
    let closed=false; const close=v=>{ if(closed)return; closed=true; document.body.removeChild(mask); resolve(v); };
    mask.querySelector('#s-cancel').onclick=()=>close(null);
    mask.querySelector('#s-save').onclick=()=>{
      const items=[...tbody.querySelectorAll('tr')].map(tr=>({
        material_code:tr.querySelector('.i-mc').value.trim(), item_name:tr.querySelector('.i-name').value.trim(),
        spec:tr.querySelector('.i-spec').value.trim(), unit:tr.querySelector('.i-unit').value.trim(), qty:tr.querySelector('.i-qty').value.trim(),
      })).filter(it=>it.material_code||it.qty);
      close({
        vendor_code:mask.querySelector('#s-vc').value.trim(), vendor_name:mask.querySelector('#s-vn').value.trim(),
        statement_no:mask.querySelector('#s-no').value.trim(), statement_date:mask.querySelector('#s-date').value,
        hospital:mask.querySelector('#s-hosp').value.trim(), order_no:mask.querySelector('#s-order').value.trim(), items,
      });
    };
    mask.addEventListener('mousedown',e=>{ if(e.target===mask) close(null); });
  });
}
