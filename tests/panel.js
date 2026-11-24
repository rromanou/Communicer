const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const R=process.argv[2];const srv=http.createServer((q,s)=>{let p=path.join(R,q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';fs.readFile(p,(e,d)=>{if(e){s.statusCode=404;return s.end()}s.setHeader('content-type',p.endsWith('.js')?'text/javascript':p.endsWith('.css')?'text/css':'text/html');s.end(d)})}).listen(0,async()=>{
const b=await chromium.launch();const pg=await b.newPage();const errs=[];pg.on('console',m=>console.log('C',m.text().slice(0,150)));pg.on('pageerror',e=>errs.push(e.message));
await pg.route(/\/rest\/v1\/rpc\//,r=>{const fn=r.request().url().split('/rpc/')[1].split('?')[0];const d=fn==='panel_state'?{unlocked:true,rank:4,len:10,vanish:false}:fn==='panel_cfg_info'?{seq:'UUDD',pin:true}:(fn==='panel_vanished'||fn==='ui_layout_get'||fn==='panel_users_list')?[]:null;r.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(d)})});
await pg.addInitScript(()=>{localStorage.setItem('cm_pnl_open','true');window.__c=[];const as=Element.prototype.attachShadow;Element.prototype.attachShadow=function(o){return as.call(this,{mode:'open'})}; const mk=()=>new Proxy(function(){},{get:(t,k)=>k==='then'?(r=>r({data:null,error:null})):k==='auth'?auth:mk(),apply:()=>mk()});
 const auth={getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({})};
 const D=fn=>fn==='panel_state'?{unlocked:true,rank:4,len:10,vanish:false}:fn==='panel_cfg_info'?{seq:'UUDD',pin:true}:(fn==='panel_vanished'||fn==='ui_layout_get'||fn==='panel_users_list')?[]:null;
 window.supabase={createClient:()=>new Proxy({},{get:(t,k)=>k==='rpc'?(fn=>{window.__c.push(fn);return Promise.resolve({data:D(fn),error:null})}):k==='auth'?auth:mk()})}});
await pg.goto('http://localhost:'+srv.address().port+'/index.html');await pg.waitForTimeout(800);
console.log('loaded',await pg.evaluate(()=>[window.__pnlLoaded,!!document.querySelector('script[src*=panel]')]));const r=await pg.evaluate(async()=>{
 window.S=window.S||{};try{S.me={id:'u1'};S.profile={username:'x'};S.profiles=new Map();}catch(e){return 'S: '+e.message}
  setInterval(()=>{S.me={id:'u1'};S.profile={username:'x'}},50);await new Promise(r=>setTimeout(r,3500));
 const h=document.getElementById('pnlHost');if(!h)return 'no host'+JSON.stringify(window.__c);const R=h.shadowRoot,out=[];for(const t of ['loc','jeu','net','adm','srv','cmd']){R.querySelector('[data-t='+t+']').click();await new Promise(r=>setTimeout(r,200));out.push(t+':'+R.getElementById('bd').innerText.length)}
 R.querySelector('[data-t=loc]').click();R.getElementById('tEd').click();R.getElementById('rAdd').click();const rl=R.getElementById('rL').innerText;document.designMode='off';
 return out.join(' ')+' | '+rl.slice(0,60)});
console.log(r,errs);await b.close();srv.close()});
