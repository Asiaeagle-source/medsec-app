// ============================================================
// scripts/verify_mail_reassign.mjs — 信件轉派驗收腳本(headless UI)
// 執行:node scripts/verify_mail_reassign.mjs(repo 根目錄)
// 需求:Node 18+ 與 Playwright + Chromium
//   - 雲端容器:預裝於 /opt/node22 與 /opt/pw-browsers,直接跑
//   - 本機:npm i -D playwright && npx playwright install chromium 後,
//     設環境變數 PW_IMPORT=playwright PW_EXEC=(留空用預設)再跑
// 全 mock supabase(不碰真環境);驗:按鈕權限、選單、RPC 參數、
// 樂觀更新與留痕、req5 視圖規則、失敗回滾、認領/完成迴歸。
// ============================================================
import { spawn } from 'node:child_process';

let chromium, execPath;
try {
  const mod = await import(process.env.PW_IMPORT || '/opt/node22/lib/node_modules/playwright/index.js');
  chromium = (mod.default ?? mod).chromium;
  execPath = process.env.PW_EXEC || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
} catch (e) {
  console.error('需要 Playwright:npm i -D playwright && npx playwright install chromium,再以 PW_IMPORT=playwright 執行');
  process.exit(2);
}

const PORT = 8811;
const srv = spawn('python3', ['-m', 'http.server', String(PORT)], { cwd: process.cwd(), stdio: 'ignore' });
await new Promise(r => setTimeout(r, 700));

const STUB = (role) => `
  const T=new Date().toISOString(); const D=T.slice(0,10);
  const base={flag_reason:null,deadline:null,claimed_by:null,claimed_by_name:null,claimed_at:null,done_by:null,done_at:null,erp_ref_no:null,received_at:T,digest_date:D,hospital_id:null,needs_reply:false,body_text:null,web_link:null,reassigned_by_name:null,reassigned_at:null};
  // u-me=登入者;u-b=另一位業祕
  const ROWS=[
    {...base,id:'m-mine',priority:'order',category:'訂單',subject:'我承辦的信(自動派給我)',sender_name:'甲',sender_email:'a@h.tw',ai_summary:'x',hospital_name_short:'甲院',effective_secretary_name:'阿測',effective_secretary_id:'u-me',assigned_to:null,status:'pending'},
    {...base,id:'m-assigned-me',priority:'amber',category:'醫院往來',subject:'手動指派給我的信',sender_name:'乙',sender_email:'b@h.tw',ai_summary:'y',hospital_name_short:'乙院',effective_secretary_name:'阿測',effective_secretary_id:'u-me',assigned_to:'u-me',status:'claimed',claimed_by:'u-me',claimed_by_name:'阿測',claimed_at:T},
    {...base,id:'m-other',priority:'amber',category:'醫院往來',subject:'別人分區的信',sender_name:'丙',sender_email:'c@h.tw',ai_summary:'z',hospital_name_short:'丙院',effective_secretary_name:'小飛',effective_secretary_id:'u-b',assigned_to:null,status:'pending'},
    {...base,id:'m-assigned-other',priority:'amber',category:'醫院往來',subject:'指派給別人的信(req5:業祕不該看到)',sender_name:'丁',sender_email:'d@h.tw',ai_summary:'w',hospital_name_short:'丁院',effective_secretary_name:'小飛',effective_secretary_id:'u-b',assigned_to:'u-b',status:'pending'},
    {...base,id:'m-done',priority:'amber',category:'醫院往來',subject:'已完成的信',sender_name:'戊',sender_email:'e@h.tw',ai_summary:'v',hospital_name_short:'戊院',effective_secretary_name:'阿測',effective_secretary_id:'u-me',assigned_to:'u-me',status:'done',done_by:'u-me',done_by_name:'阿測',done_at:T},
  ];
  const ASG=[{primary_secretary_id:'u-me',co_secretary_id:'u-b'},{primary_secretary_id:'u-c',co_secretary_id:null}];
  const PROFS=[{id:'u-me',name:'測試',nickname:'阿測',employee_id:'0007'},{id:'u-b',name:'飛',nickname:'小飛',employee_id:'0101'},{id:'u-c',name:'雅',nickname:'雅婷',employee_id:'0102'}];
  window.__rpc=[]; window.__failRpc=false;
  function q(t){ const st={t,f:{},inIds:null};
    const qq={select:()=>qq,eq:(c,v)=>{st.f[c]=v;return qq;},gte:()=>qq,order:()=>qq,limit:()=>qq,in:(c,v)=>{st.inIds=v;return qq;},
      then:(res)=>{ if(st.t==='v_mail_digest_assigned'){ if(st.f.status==='done')return res({data:[],error:null}); return res({data:ROWS,error:null}); }
        if(st.t==='medsec_secretary_assignments')return res({data:ASG,error:null});
        if(st.t==='profiles')return res({data:PROFS.filter(p=>!st.inIds||st.inIds.includes(p.id)),error:null});
        if(st.t==='mail_attachments')return res({data:[],error:null});
        return res({data:[],error:null}); }};
    return qq; }
  window.supa={from:q,
    rpc:(n,a)=>{ window.__rpc.push({n,a}); return Promise.resolve(window.__failRpc?{error:{message:'denied'}}:{error:null}); },
    storage:{from:()=>({createSignedUrl:()=>Promise.resolve({data:{signedUrl:'https://s/x'},error:null})})}};
  window.guardRole=async()=>({id:'u-me',name:'測試',nickname:'阿測',employee_id:'0007',medsec_role:'${role}',has_medsec_access:true});
  window.renderUserInfo=()=>{};window.hideLoading=()=>{const m=document.getElementById('loading-mask');if(m)m.remove();};window.handleLogout=()=>{};
`;

const browser = await chromium.launch({ executablePath: execPath });
const results = []; const ok = (n, c, e = '') => results.push([c ? 'PASS' : 'FAIL', n, e]);

async function openAs(role) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errs = [];
  page.on('pageerror', e => errs.push(String(e)));
  await page.route('**/medsec-common.js', r => r.fulfill({ contentType: 'application/javascript; charset=utf-8', body: STUB(role) }));
  await page.route('**/@supabase/**', r => r.fulfill({ contentType: 'application/javascript', body: '' }));
  await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ contentType: 'text/css', body: '' }));
  await page.route('**/fonts.gstatic.com/**', r => r.fulfill({ contentType: 'font/woff2', body: '' }));
  await page.goto(`http://localhost:${PORT}/mail-triage.html`, { waitUntil: 'networkidle' });
  await page.waitForSelector('.mt-card');
  return { page, errs };
}
const hasReBtn = (page, id) => page.$eval(`[data-card="${id}"]`, c => [...c.querySelectorAll('.acts button')].some(b => /轉派/.test(b.textContent))).catch(() => false);

// ===== 業祕視角 =====
{
  const { page, errs } = await openAs('secretary');
  ok('祕: 無 JS 錯', errs.length === 0, errs.join('|'));
  ok('祕: req5 指派給別人的信不顯示', (await page.$('[data-card="m-assigned-other"]')) === null);
  ok('祕: 自己承辦的信有轉派鈕', await hasReBtn(page, 'm-mine'));
  ok('祕: 手動指派給我的信有轉派鈕', await hasReBtn(page, 'm-assigned-me'));
  ok('祕: 別人分區池信無轉派鈕', !(await hasReBtn(page, 'm-other')));
  // 轉派給小飛 → RPC + 樂觀移除(req5)
  await page.$eval('[data-card="m-mine"]', c => [...c.querySelectorAll('.acts button')].find(b => /轉派/.test(b.textContent)).click());
  await page.waitForSelector('#re-sel');
  const optTexts = await page.$$eval('#re-sel option', os => os.map(o => o.textContent));
  ok('祕: 選單=分區業祕(阿測/小飛/雅婷)', optTexts.join(',').includes('小飛') && optTexts.join(',').includes('雅婷') && optTexts.some(t => t.includes('(我)')), optTexts.join(','));
  await page.selectOption('#re-sel', 'u-b');
  await page.click('.mt-modal .ok');
  await page.waitForTimeout(450);
  const call = await page.evaluate(() => window.__rpc.find(r => r.n === 'medsec_reassign_mail'));
  ok('祕: RPC 參數正確', call && call.a.p_mail_id === 'm-mine' && call.a.p_to === 'u-b', JSON.stringify(call));
  ok('祕: 轉走 → 從自己視圖移除(req5)', (await page.$('[data-card="m-mine"]')) === null);
  // 失敗回滾
  await page.evaluate(() => { window.__failRpc = true; });
  await page.$eval('[data-card="m-assigned-me"]', c => [...c.querySelectorAll('.acts button')].find(b => /轉派/.test(b.textContent)).click());
  await page.waitForSelector('#re-sel');
  await page.selectOption('#re-sel', 'u-b');
  await page.click('.mt-modal .ok');
  await page.waitForTimeout(500);
  ok('祕: RPC 失敗 → 回滾(卡片仍在、無轉派痕)', (await page.$('[data-card="m-assigned-me"]')) !== null
    && await page.$eval('[data-card="m-assigned-me"]', c => !/由.*轉派/.test(c.textContent)));
  await page.close();
}
// ===== manager 視角 =====
{
  const { page, errs } = await openAs('manager');
  ok('管: 無 JS 錯', errs.length === 0, errs.join('|'));
  ok('管: 看得到指派給別人的信', (await page.$('[data-card="m-assigned-other"]')) !== null);
  ok('管: 任何非完成信都有轉派鈕', (await hasReBtn(page, 'm-other')) && (await hasReBtn(page, 'm-assigned-other')));
  ok('管: 已完成信無轉派鈕', !(await hasReBtn(page, 'm-done')));
  // manager 轉派:卡片留在視圖、承辦更新 + 留痕
  await page.$eval('[data-card="m-other"]', c => [...c.querySelectorAll('.acts button')].find(b => /轉派/.test(b.textContent)).click());
  await page.waitForSelector('#re-sel');
  await page.selectOption('#re-sel', 'u-c');
  await page.click('.mt-modal .ok');
  await page.waitForTimeout(450);
  ok('管: 轉派後卡片仍在、承辦=雅婷、🔁 留痕', await page.$eval('[data-card="m-other"]', c => /雅婷/.test(c.textContent) && /由/.test(c.textContent) && /轉派/.test(c.textContent)));
  // 迴歸
  ok('迴歸: 認領/完成鈕仍在', await page.$eval('[data-card="m-assigned-other"]', c => /認領/.test(c.textContent) && /完成/.test(c.textContent)));
  if (process.env.SHOTDIR) await page.screenshot({ path: process.env.SHOTDIR + '/reassign_manager.png', clip: { x: 260, y: 80, width: 1000, height: 700 } });
  await page.close();
}

await browser.close(); srv.kill();
let f = 0;
for (const [s, n, e] of results) { if (s === 'FAIL') f++; console.log(`${s === 'PASS' ? '✓' : '✗'} ${s}  ${n}${e ? '  [' + e + ']' : ''}`); }
console.log(`\n${results.length - f}/${results.length} passed`);
process.exit(f ? 1 : 0);
