// Casino : table de roulette et de poker avec état simulé ; vérifie que les boutons du bas sont cliquables (aucun élément ne les couvre).
// Usage : node tests/casino.js [dossier=_site]
const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const R=path.resolve(process.argv[2]||'_site');
const T={'.html':'text/html','.js':'text/javascript','.css':'text/css','.txt':'text/plain','.png':'image/png'};
const srv=http.createServer((q,s)=>{let p=path.join(R,q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';fs.readFile(p,(e,d)=>{if(e){s.statusCode=404;return s.end()}s.setHeader('content-type',T[path.extname(p)]||'application/octet-stream');s.end(d)})}).listen(0,async()=>{
const b=await chromium.launch();const errs=[];let fail=0;
for(const vp of [{width:1200,height:800},{width:390,height:780}]){
const pg=await b.newPage({viewport:vp});pg.on('pageerror',e=>{if(!/reading 'find'/.test(e.message))errs.push(e.message)});
await pg.addInitScript(()=>{const auth={getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({})};
 const mk=()=>new Proxy(function(){},{get:(t,k)=>k==='then'?undefined:mk(),apply:()=>mk()});
 window.addEventListener('error',e=>window.__err=e.message+' '+(e.error&&e.error.stack||'').split('\n').slice(0,3).join('|'));window.supabase={createClient:()=>new Proxy({},{get:(t,k)=>k==='rpc'?((fn,a)=>Promise.resolve({data:window.__rpcH?window.__rpcH(fn,a):null,error:null})):k==='auth'?auth:mk()})}});
await pg.goto('http://localhost:'+srv.address().port+'/index.html');await pg.waitForTimeout(800);
const r=await pg.evaluate(async()=>{
 const seats=Array(10).fill(null);
 const base={ok:true,version:1,now_ms:Date.now(),table:{id:1,name:'T',min_bet:10,max_bet:100,buyin_min:100,buyin_max:1000,seats:10},phase:'betting',phase_left_ms:15000,phase_total_ms:20000,seats,dealer:{name:'Croupier',look:{},cards:[]},community:[],pot:0,log:[],history:[],hand_no:1};
 const me=seat=>({seat,wallet:500,stack:0,cards:[],to_act:false,peeks:[],bets:[],bot_vote:{voted:false,yes:0,needed:1},alarms:[],cheat:{cooldown_ms:0,blocked_seats:[],attempt:null}});
 let mine=null;
 window.__rpcH=(fn,a)=>{if(fn==='casino_state'){const s=JSON.parse(JSON.stringify(base));s.game=window.__g;s.me=me(mine);if(mine!=null)s.seats[mine]={seat:mine,kind:'human',name:'moi',look:{},stack:500,bet:0,status:'waiting',cards:[]};return s}
  if(fn==='casino_join'){mine=a.p_seat==null?2:a.p_seat;window.__joined=a;return{seat:mine}}if(fn==='casino_leave'){mine=null;window.__left=1;return{refunded:0}}if(fn==='casino_bot_vote'){window.__vote=1;return{added:false}}
  if(fn==='casino_chips_me')return{chips:500,tokens:100};if(fn==='casino_lobby')return{members:1,balance:500,medals:0,games:[],slots:[],lot:{}};return{}};
 window.S=window.S||{};try{S.me={id:'u1'};S.profile={username:'x'}}catch(e){}
 const out={};
 for(const g of ['roulette','poker']){window.__g=g;mine=null;window.__joined=null;if(window.CZ)window.CZ.close&&window.CZ.close();
  window.openCasino({go:g,arg:{id:1,name:'T'}});await new Promise(r=>setTimeout(r,1500));
  const find=sel=>{const e=document.querySelector(sel);if(!e)return 'absent';e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;const t=document.elementFromPoint(x,y);return e.contains(t)||t===e?'ok':'COUVERT par '+(t?t.className||t.tagName:'rien')};
  out[g+'_join']=g==='roulette'?find('[data-join]'):find('[data-sit]');
  const btn=document.querySelector(g==='roulette'?'[data-join]':'[data-sit]');if(btn){btn.click();await new Promise(r=>setTimeout(r,500));const ok=document.querySelector('.cz-dlg [data-ok]');if(ok)ok.click();await new Promise(r=>setTimeout(r,2200))}
  out[g+'_siege']=window.__joined?JSON.stringify(window.__joined):'non';
  out[g+'_vote']=find('[data-vote]');out[g+'_quitter']=find('[data-leave]');
  const v=document.querySelector('[data-vote]');if(v){v.click();await new Promise(r=>setTimeout(r,300))}out[g+'_voteclic']=window.__vote?'ok':'non';
  const l=document.querySelector('[data-leave]');if(l){l.click();await new Promise(r=>setTimeout(r,500))}out[g+'_quitterclic']=window.__left?'ok':'non';window.__left=0;
  out[g+'_siegesderriere']=[...document.querySelectorAll('[data-sit]')].map(e=>e.dataset.sit).join(',');
 }
 out.dbg=(document.querySelector('.cz-root')?'root ':'noroot ')+(document.querySelector('.cz-view')?document.querySelector('.cz-view').className:'noview')+' '+(window.__err||'');return out});
console.log(vp.width,JSON.stringify(r));for(const k in r){if(/COUVERT|absent|non$/.test(r[k])&&!/siegesd/.test(k)){fail++}}
await pg.close()}
console.log('erreurs JS:',errs.length?errs.join(' | '):'aucune');await b.close();srv.close();process.exit(fail||errs.length?1:0)});
