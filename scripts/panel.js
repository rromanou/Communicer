/* panel.js — panneau caché de Communicer! (chargé après app.js, partage ses variables globales).
   Débloqué par un code de flèches dans un jeu + un NIP de 8 lettres ; les deux sont vérifiés par le SERVEUR (3 essais de NIP, puis blocage).
   Tout ce qui agit sur les autres passe par des fonctions SQL qui revérifient le déblocage ET le rang : modifier ce fichier ne donne aucun pouvoir serveur.
   Les outils « locaux » (éditer le texte, variables, recadrage, règles d'affichage) ne touchent que l'écran de la personne. */
(function(){
'use strict';
if(window.__pnlLoaded)return;window.__pnlLoaded=1;
const KM={ArrowUp:'U',ArrowDown:'D',ArrowLeft:'L',ArrowRight:'R'};
let st={unlocked:false,rank:0,len:10,banned:false,vanish:false},buf='',tmr=null,busy=false,host=null,root=null,spy=[],clsCache={},rules=[],vanished=new Set();
const LS=(k,d)=>{try{const v=localStorage.getItem(k);return v==null?d:JSON.parse(v)}catch(e){return d}};
const LSset=(k,v)=>{try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}};
const BAD=/pass|pwd|secret|token|priv|jwt|apikey|api_key|cookie|session|email|phone|salt|hash|pin\b|ciffron|wrapped|cipher|key/i;
const esc2=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const ready=()=>typeof S!=='undefined'&&S&&S.me&&S.me.id&&typeof sb!=='undefined';
const blocked=()=>{try{return !!(S.sess&&S.sess.cfg&&+S.sess.cfg.nopanel)}catch(e){return false}};   // le créateur de la partie a interdit le panneau

/* ---------- 1) espion réseau local (ce que ce client envoie au serveur) ---------- */
function installSpy(){
  if(typeof sb==='undefined'||sb.__spy)return;sb.__spy=1;const o=sb.rpc.bind(sb);
  sb.rpc=function(fn,args,opt){
    const t0=performance.now(),b=o(fn,args,opt);
    try{const ot=b.then.bind(b);b.then=(res,rej)=>ot(r=>{spy.push({t:Date.now(),fn,ms:Math.round(performance.now()-t0),a:mask(args),err:r&&r.error?r.error.message:null});if(spy.length>200)spy.shift();return res?res(r):r},rej)}catch(e){}
    return b};
}
function mask(a){try{return JSON.stringify(a||{},(k,v)=>BAD.test(k)?'***':(typeof v==='string'&&v.length>80?v.slice(0,80)+'…':v)).slice(0,400)}catch(e){return ''}}

/* ---------- 2) code de flèches (dans un jeu) ---------- */
function onKey(e){
  if(!ready()||busy||st.banned)return;
  const k=KM[e.key];if(!k)return;
  const t=e.target;if(t&&(/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)||t.isContentEditable))return;   // pas pendant la saisie de texte
  if(blocked())return;
  buf=(buf+k).slice(-64);clearTimeout(tmr);
  if(buf.length>=Math.max(4,st.len||4))tmr=setTimeout(tryCode,900);
}
async function tryCode(){
  if(busy)return;const b=buf;busy=true;
  try{const ok=await rpcd('panel_seq',{p_seq:b});buf='';if(ok)askPin()}catch(e){}
  busy=false;
}
function askPin(){
  const m=modal(`<h3>Code d’accès</h3><p class="muted">Entrez le NIP de 8 lettres. Si aucun NIP n’existe encore, le commandant crée le sien ici.</p><input id="pnPin" maxlength="8" autocomplete="off" autocapitalize="off" spellcheck="false" style="letter-spacing:4px;text-transform:uppercase"><div class="row end"><button class="ghost" id="pnX">Annuler</button><button id="pnGo">Valider</button></div>`);
  const inp=m.querySelector('#pnPin');setTimeout(()=>inp.focus(),50);
  const go=async()=>{const v=inp.value.trim();if(!/^[A-Za-z]{8}$/.test(v))return toast('8 lettres exactement');
    try{const r=await rpcd('panel_pin',{p_pin:v});
      if(r.ok){m.close();await refresh();toast('Panneau débloqué : activez-le dans les paramètres');openPanel();return}
      if(r.banned){m.close();st.banned=true;return toast('Accès au panneau bloqué')}
      if(r.why==='seq'){m.close();return}
      if(r.why==='nopin'){m.close();return toast('Aucun NIP n’est encore défini : seul le commandant peut en créer un')}
      toast('NIP incorrect : '+r.left+' essai'+(r.left>1?'s':'')+' restant'+(r.left>1?'s':''));inp.value=''}catch(e){toast(errMsg(e))}};
  m.querySelector('#pnGo').onclick=go;m.querySelector('#pnX').onclick=()=>m.close();inp.onkeydown=ev=>{if(ev.key==='Enter')go()};
}
async function refresh(){try{const s=await rpcd('panel_state');st=Object.assign(st,s);window.dispatchEvent(new Event('pnlstate'));return true}catch(e){return false}}

/* ---------- 3) réglages : « Afficher le panneau » ---------- */
function hookSettings(){
  new MutationObserver(()=>{
    const m=document.querySelector('.modal #pnlSlot');if(!m||m.dataset.d)return;m.dataset.d='1';
    m.innerHTML='<div class="setblk"><label class="setchk"><input type="checkbox" id="pnlVol"><span><b>Autoriser les administrateurs à écrire en mon nom</b><small>Pour une raison justifiée seulement ; le message est étiqueté. Vous recevez 2 jetons de plus pour chaque jour où cette case est cochée.</small></span></label></div>'+
      (st.unlocked?'<div class="setblk"><div class="setrow"><span><b>Panneau</b><small>Affiche le panneau d’administration par-dessus l’écran.</small></span><button class="ghost" id="pnlOpen">Afficher le panneau sur l’écran</button></div></div>':'');
    const vb=m.querySelector('#pnlVol');rpcd('speak_vol_me').then(v=>{vb.checked=!!v}).catch(()=>{});
    vb.onchange=()=>rpcd('speak_vol_set',{p_on:vb.checked}).then(()=>{toast(vb.checked?'Vous vous êtes porté volontaire : 2 jetons par jour':'Volontariat retiré');try{balRefresh()}catch(e){}}).catch(e=>{vb.checked=!vb.checked;toast(errMsg(e))});
    const ob=m.querySelector('#pnlOpen');if(ob)ob.onclick=()=>{openPanel();const mm=m.closest('.modal-back');if(mm&&mm.close)mm.close()};
  }).observe(document.body,{childList:true,subtree:true});
}

/* ---------- 4) mises en page (main magique) ---------- */
const SELOK=/^(#[A-Za-z][A-Za-z0-9_-]{0,40}|\.[A-Za-z][A-Za-z0-9_-]{0,40}|\[data-(mid|id|k)="[A-Za-z0-9_-]{1,40}"\])$/;
let layG=[],layL=LS('cm_pnl_lay',[]);
function layApply(){
  let t=document.getElementById('pnlLay');if(!t){t=document.createElement('style');t.id='pnlLay';document.head.appendChild(t)}
  const all=[...layG,...layL].filter(x=>SELOK.test(x.sel));
  t.textContent=all.map(x=>`${x.sel}{translate:${x.dx|0}px ${x.dy|0}px!important}`).join('\n');
}
async function layLoad(){try{layG=await rpcd('ui_layout_get');layApply()}catch(e){}}
function selOf(el){
  for(let n=el;n&&n!==document.body;n=n.parentElement){
    if(n.id&&SELOK.test('#'+n.id)&&n.id!=='pnlHost')return '#'+n.id;
    const d=n.dataset||{};for(const k of ['mid','id','k'])if(d[k]&&SELOK.test(`[data-${k}="${d[k]}"]`))return `[data-${k}="${d[k]}"]`;
  }return null;
}
let magic=false,drag=null;
function magicOn(on,glob){
  magic=on;document.documentElement.classList.toggle('pnl-magic',on);
  if(on){document.addEventListener('pointerdown',mdown,true)}else{document.removeEventListener('pointerdown',mdown,true)}
  magic.glob=glob;
}
function mdown(e){
  if(!magic||e.target.closest('#pnlHost'))return;
  const sel=selOf(e.target);if(!sel)return;e.preventDefault();e.stopPropagation();
  const cur=[...layG,...layL].filter(x=>x.sel===sel).reduce((a,x)=>({dx:a.dx+x.dx,dy:a.dy+x.dy}),{dx:0,dy:0});
  drag={sel,x:e.clientX,y:e.clientY,dx:cur.dx,dy:cur.dy,glob:!!window.__pnlGlob};
  const mv=ev=>{drag.ndx=drag.dx+ev.clientX-drag.x;drag.ndy=drag.dy+ev.clientY-drag.y;put(drag.sel,drag.ndx,drag.ndy,drag.glob,true)};
  const up=async()=>{document.removeEventListener('pointermove',mv,true);document.removeEventListener('pointerup',up,true);
    if(drag&&drag.ndx!=null){if(drag.glob){try{await rpcd('ui_layout_set',{p_sel:drag.sel,p_dx:Math.round(drag.ndx),p_dy:Math.round(drag.ndy)})}catch(x){toast(errMsg(x))}}else LSset('cm_pnl_lay',layL)}drag=null};
  document.addEventListener('pointermove',mv,true);document.addEventListener('pointerup',up,true);
}
function put(sel,dx,dy,glob,live){
  const L=glob?layG:layL;const i=L.findIndex(x=>x.sel===sel);const o={sel,dx:Math.round(dx),dy:Math.round(dy)};
  if(i<0)L.push(o);else L[i]=o;if(glob)layL=layL.filter(x=>x.sel!==sel);else layG=layG.filter(x=>x.sel!==sel);layApply();
}

/* ---------- 5) règles d'affichage locales ---------- */
rules=LS('cm_pnl_rules',[]);
async function rulesApply(){
  if(!ready()||!rules.length||!document.getElementById('msgs'))return;
  const c=cur();if(!c)return;const arr=S.msgs[c.id]||[];
  const needCls=rules.some(r=>/^(bidon|classe|biome)$/.test(r.w))&&st.rank>=2;
  if(needCls){const ids=[...new Set(arr.map(m=>m.sender_id))].filter(i=>!(i in clsCache)).slice(0,60);
    if(ids.length){try{Object.assign(clsCache,await rpcd('acct_class_batch',{p_users:ids}))}catch(e){ids.forEach(i=>clsCache[i]='?')}}}
  document.querySelectorAll('#msgs .mrow[data-mid]').forEach(row=>{
    const m=arr.find(x=>String(x.id)===row.dataset.mid);if(!m)return;
    const un=(S.profiles.get(m.sender_id)||{}).username,cl=clsCache[m.sender_id];
    row.querySelectorAll('.pnl-dot').forEach(x=>x.remove());
    for(const r of rules){
      const hit=r.w===cl||(r.w==='admin'&&typeof isOff==='function'&&isOff(m.sender_id))||(r.w.startsWith('user:')&&un===r.w.slice(5));
      if(!hit)continue;
      if(r.a==='bubble'){const b=row.querySelector('.bub');if(b)b.style.background=r.v}
      else if(r.a==='dot'){const b=row.querySelector('.bub')||row;const d=document.createElement('span');d.className='pnl-dot';d.style.cssText=`display:inline-block;width:8px;height:8px;border-radius:50%;background:${r.v};margin:0 4px;vertical-align:middle`;b.prepend(d)}
      else if(r.a==='frame'){const a=row.querySelector('.av');if(a&&/^[a-z0-9_]{2,30}$/i.test(r.v))a.classList.add(r.v)}
    }});
}
let rt=null;function rulesSoon(){clearTimeout(rt);rt=setTimeout(()=>{try{rulesApply()}catch(e){}},200)}

/* ---------- 6) explorateur de variables (sans les variables sensibles) ---------- */
function flat(o,out,path,depth,seen){
  if(out.length>4000||depth>6)return;
  if(o==null||typeof o==='function')return;
  if(typeof o!=='object'){out.push([path,String(o).slice(0,200)]);return}
  if(o instanceof Node||o instanceof Window||seen.has(o))return;seen.add(o);
  if(o instanceof Map){for(const [k,v] of o){const ks=String(k);if(BAD.test(ks))continue;flat(v,out,path+'/'+ks,depth+1,seen)}return}
  if(o instanceof Set){let i=0;for(const v of o){flat(v,out,path+'['+(i++)+']',depth+1,seen)}return}
  const ks=Array.isArray(o)?o.map((_,i)=>i):Object.keys(o);
  for(const k of ks.slice(0,300)){if(BAD.test(String(k)))continue;let v;try{v=o[k]}catch(e){continue}flat(v,out,path+'.'+k,depth+1,seen)}
}
function roots(){
  const r={'S.sess (jeu en cours)':()=>{const x=S.sess;if(!x)return null;return {jeu:x.game,phase:x.phase,cfg:x.cfg,joueurs:x.players,observateurs:x.specs?[...x.specs]:[],etat:x.state,secret_hote:x.hp,ma_main:x.mypriv,mains_de_tous:x.pall}},'S.profile':()=>S.profile,'S.profiles':()=>S.profiles,'S.convs':()=>S.convs,'TK (jetons)':()=>TK,'S.friends':()=>S.friends};
  document.querySelectorAll('iframe').forEach((f,i)=>{r['iframe '+(i+1)+(f.title?' · '+f.title:'')]=()=>{try{const w=f.contentWindow,o={};for(const k of Object.keys(w)){if(/^(on|webkit|chrome|\d)/.test(k))continue;try{if(typeof w[k]!=='function')o[k]=w[k]}catch(e){}}return o}catch(e){return {erreur:'iframe non lisible'}}}});
  return r;
}

/* ---------- 7) fenêtre flottante ---------- */
const WOLF="data:image/svg+xml;utf8,"+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><path fill="#fff" d="M18 22l42 34c13-6 27-6 40-6s27 0 40 6l42-34-8 62c6 12 8 24 6 38-4 26-22 44-46 52l-8 12h-52l-8-12c-24-8-42-26-46-52-2-14 0-26 6-38z"/><path fill="#000" d="M64 100l22 8-6 10zM136 100l-22 8 6 10zM88 150h24l-12 14z"/></svg>');
const CSS=`
:host{all:initial}
*{box-sizing:border-box;font-family:system-ui,sans-serif}
.w{position:fixed;left:16px;top:70px;width:min(460px,calc(100vw - 16px));height:min(540px,calc(100vh - 90px));min-width:260px;min-height:180px;resize:both;overflow:hidden;display:flex;flex-direction:column;color:#e7e9ee;
  background:linear-gradient(160deg,#0a0e1f 0,#101a38 55%,#1b0b10 100%);border:1px solid #6b1020;border-radius:12px;box-shadow:0 14px 44px rgba(0,0,0,.65),0 0 0 1px #000;z-index:2147483200;font-size:13px}
.w::before{content:"";position:absolute;inset:0;background:url("${WOLF}") center/62% no-repeat;opacity:.045;pointer-events:none}
.w.min{height:auto!important;min-height:0;resize:none}.w.min .bd,.w.min .tb{display:none}
.hd{display:flex;align-items:center;gap:6px;padding:6px 8px;background:linear-gradient(90deg,#3a0a14,#0b1230 70%,#1a1a1a);cursor:move;user-select:none;touch-action:none;border-bottom:1px solid #6b1020}
.hd b{flex:1;font-size:13px;letter-spacing:.5px}
.hd button{all:unset;cursor:pointer;padding:2px 8px;border-radius:6px;background:#1c2340;color:#e7e9ee}.hd button:hover{background:#6b1020}
.tb{display:flex;gap:2px;padding:4px 6px;background:#0a0d1a;border-bottom:1px solid #2a2f45;overflow-x:auto}
.tb button{all:unset;cursor:pointer;padding:4px 10px;border-radius:6px;color:#9aa3c7;white-space:nowrap}.tb button.on{background:#6b1020;color:#fff}
.bd{flex:1;overflow:auto;padding:10px;position:relative;-webkit-overflow-scrolling:touch}
h4{margin:10px 0 4px;color:#d94b5f;font-size:12px;text-transform:uppercase;letter-spacing:1px}
.r{display:flex;gap:6px;align-items:center;margin:4px 0;flex-wrap:wrap}
button.b,.bd button{cursor:pointer;background:#1c2340;color:#e7e9ee;border:1px solid #2f3a66;border-radius:7px;padding:5px 10px;font-size:12px}
.bd button:hover{background:#6b1020;border-color:#a1182f}.bd button.on{background:#a1182f;border-color:#d94b5f}
input,select,textarea{background:#070a16;color:#e7e9ee;border:1px solid #2f3a66;border-radius:6px;padding:5px 7px;font-size:12px;min-width:0}
input[type=text],input:not([type]),input[type=number],select,textarea{flex:1}
.m{color:#8f99bd;font-size:11.5px}
pre,.mono{background:#05070f;border:1px solid #20263f;border-radius:6px;padding:6px;margin:4px 0;font:11px/1.35 ui-monospace,monospace;white-space:pre-wrap;word-break:break-all;max-height:220px;overflow:auto}
.kv{display:flex;gap:6px;border-bottom:1px solid #151a2e;padding:2px 0;font:11px ui-monospace,monospace}.kv i{flex:0 0 46%;color:#d94b5f;font-style:normal;word-break:break-all}.kv span{flex:1;word-break:break-all}
.warn{color:#f0a;}
`;
function openPanel(){
  if(!st.unlocked)return;
  if(host){host.style.display='';LSset('cm_pnl_open',true);return}
  LSset('cm_pnl_open',true);
  host=document.createElement('div');host.id='pnlHost';document.body.appendChild(host);
  root=host.attachShadow({mode:'closed'});
  const tabs=[['loc','Joueur'],['out','Outils'],['jeu','Jeux'],['net','Réseau']];
  if(st.rank>=2)tabs.push(['adm','Admin'],['srv','Serveur']);
  if(st.rank>=4)tabs.push(['cmd','Commandant']);
  root.innerHTML=`<style>${CSS}</style><div class="w" id="w"><div class="hd" id="hd"><b>PANNEAU</b><button id="bm" title="Réduire">_</button><button id="bx" title="Fermer">x</button></div><div class="tb" id="tb">${tabs.map(t=>`<button data-t="${t[0]}">${t[1]}</button>`).join('')}</div><div class="bd" id="bd"></div></div>`;
  const w=root.getElementById('w'),hd=root.getElementById('hd');
  let dr=null;hd.addEventListener('pointerdown',e=>{if(e.target.closest('button'))return;const r=w.getBoundingClientRect();dr={x:e.clientX-r.left,y:e.clientY-r.top};hd.setPointerCapture(e.pointerId)});
  hd.addEventListener('pointermove',e=>{if(!dr)return;w.style.left=Math.max(0,Math.min(innerWidth-60,e.clientX-dr.x))+'px';w.style.top=Math.max(0,Math.min(innerHeight-30,e.clientY-dr.y))+'px'});
  hd.addEventListener('pointerup',()=>{dr=null});
  root.getElementById('bx').onclick=()=>{host.style.display='none';LSset('cm_pnl_open',false)};
  root.getElementById('bm').onclick=()=>w.classList.toggle('min');
  root.getElementById('tb').onclick=e=>{const b=e.target.closest('[data-t]');if(b)show(b.dataset.t)};
  show('loc');
}
function show(t){
  const bd=root.getElementById('bd');root.querySelectorAll('#tb button').forEach(b=>b.classList.toggle('on',b.dataset.t===t));
  bd.innerHTML='';(VIEWS[t]||(()=>{}))(bd);
}
const $r=(bd,s)=>bd.querySelector(s);
const VIEWS={
  loc(bd){
    const cropOn=document.documentElement.dataset.pnlCrop||'';
    bd.innerHTML=`<h4>Affichage (local)</h4>
      <div class="r"><button id="tEd" class="${document.designMode==='on'?'on':''}">Éditer tout le texte</button><button id="tRc" class="${window.__pnlRc?'on':''}">Clic droit normal</button><button id="tMg" class="${magic?'on':''}">Main magique</button></div>
      <div class="m">Éditer le texte : cliquez sur le texte du site pour le modifier (la police ne change pas). Rien n’est enregistré. Main magique : glissez un élément pour le déplacer${st.rank>=2?'. Case « pour tous » : le déplacement est enregistré pour tout le monde.':' (seulement pour vous).'}</div>
      ${st.rank>=2?'<div class="r"><label class="m"><input type="checkbox" id="mgG" '+(window.__pnlGlob?'checked':'')+'> déplacer pour tous</label><button id="mgR">Réinitialiser les déplacements</button></div>':'<div class="r"><button id="mgR">Réinitialiser mes déplacements</button></div>'}
      <h4>Recadrage de l’écran</h4><div class="r"><select id="crop"><option value="">Aucun</option><option value="360x640">Téléphone 360 x 640</option><option value="414x896">Téléphone 414 x 896</option><option value="768x1024">Tablette 768 x 1024</option><option value="1280x720">Ordinateur 1280 x 720</option><option value="640x360">Téléphone paysage</option></select></div>
      <h4>Jetons affichés (local)</h4><div class="r"><input type="number" id="bal" placeholder="Nombre de jetons"><button id="balGo">Afficher</button></div><div class="m">Seul l’affichage change ; le vrai solde reste sur le serveur.</div>
      <h4>Règles d’affichage (local)</h4><div class="r"><select id="rW"><option value="bidon">Compte bidon</option><option value="classe">Compte de classe</option><option value="biome">Compte de biome</option><option value="admin">Compte officiel</option><option value="user">Nom d’utilisateur…</option></select><input id="rU" placeholder="nom (si choisi)" style="max-width:120px"></div>
      <div class="r"><select id="rA"><option value="dot">Point coloré</option><option value="bubble">Couleur de bulle</option><option value="frame">Cadre (code)</option></select><input id="rV" value="#f59e0b" placeholder="couleur ou code"><button id="rAdd">Ajouter</button></div>
      <div id="rL"></div>
      <h4>Écrans</h4><div class="r"><button id="tCtl">Touches : Ctrl+F, Ctrl+Maj+C autorisées</button></div>`;
    const sel=$r(bd,'#crop');sel.value=cropOn;
    sel.onchange=()=>{const v=sel.value;const h=document.documentElement;let s=document.getElementById('pnlCrop');if(!s){s=document.createElement('style');s.id='pnlCrop';document.head.appendChild(s)}
      if(!v){delete h.dataset.pnlCrop;s.textContent='';return}h.dataset.pnlCrop=v;const [W,H]=v.split('x');s.textContent=`body{width:${W}px!important;height:${H}px!important;margin:8px auto!important;outline:2px solid #a1182f;overflow:hidden!important;position:relative}`};
    $r(bd,'#tEd').onclick=e=>{document.designMode=document.designMode==='on'?'off':'on';e.target.classList.toggle('on',document.designMode==='on')};
    $r(bd,'#tRc').onclick=e=>{window.__pnlRc=!window.__pnlRc;e.target.classList.toggle('on',window.__pnlRc)};
    $r(bd,'#tMg').onclick=e=>{const on=!magic;window.__pnlGlob=!!(root.getElementById('mgG')||{}).checked;magicOn(on);e.target.classList.toggle('on',on)};
    const g=$r(bd,'#mgG');if(g)g.onchange=()=>{window.__pnlGlob=g.checked};
    $r(bd,'#mgR').onclick=async()=>{layL=[];LSset('cm_pnl_lay',[]);if(st.rank>=2&&confirm('Réinitialiser aussi les déplacements enregistrés pour tout le monde ?')){try{await rpcd('ui_layout_reset');layG=[]}catch(e){toast(errMsg(e))}}layApply();toast('Déplacements réinitialisés')};
    $r(bd,'#balGo').onclick=()=>{const v=Number($r(bd,'#bal').value);if(isNaN(v))return;TK.bal=v;try{balRender()}catch(e){}};
    $r(bd,'#tCtl').onclick=()=>toast('Ces raccourcis du navigateur ne sont plus bloqués par le site');
    const list=()=>{$r(bd,'#rL').innerHTML=rules.map((r,i)=>`<div class="kv"><i>${esc2(r.w)}</i><span>${esc2(r.a)} · ${esc2(r.v)}</span><button data-i="${i}">x</button></div>`).join('')||'<div class="m">Aucune règle.</div>'};list();
    $r(bd,'#rL').onclick=e=>{const b=e.target.closest('[data-i]');if(!b)return;rules.splice(+b.dataset.i,1);LSset('cm_pnl_rules',rules);list();rulesSoon()};
    $r(bd,'#rAdd').onclick=()=>{let w=$r(bd,'#rW').value;if(w==='user'){const u=$r(bd,'#rU').value.trim().toLowerCase().replace(/^@/,'');if(!u)return;w='user:'+u}
      if(/^(bidon|classe|biome)$/.test(w)&&st.rank<2)return toast('Réservé aux administrateurs');
      rules.push({w,a:$r(bd,'#rA').value,v:$r(bd,'#rV').value.trim().slice(0,30)});LSset('cm_pnl_rules',rules);list();clsCache={};rulesSoon()};
  },
  out(bd){
    const css=(id,t)=>{let x=document.getElementById(id);if(!t){if(x)x.remove();return}if(!x){x=document.createElement('style');x.id=id;document.head.appendChild(x)}x.textContent=t};
    const tg=(k,on,off)=>{const b=document.createElement('button');b.textContent=k[0];let st2=!!window['__pt_'+k[1]];b.className=st2?'on':'';b.onclick=()=>{st2=!st2;window['__pt_'+k[1]]=st2;b.classList.toggle('on',st2);try{st2?on():off()}catch(e){toast(errMsg(e))}};return b};
    const add=(title,items)=>{const h=document.createElement('h4');h.textContent=title;bd.appendChild(h);const r=document.createElement('div');r.className='r';items.forEach(i=>r.appendChild(i));bd.appendChild(r);return r};
    const act=(label,fn)=>{const b=document.createElement('button');b.textContent=label;b.onclick=()=>{try{fn()}catch(e){toast(errMsg(e))}};return b};
    bd.innerHTML='<div class="m">Outils locaux : ils ne changent que votre écran et ne sont pas enregistrés.</div>';
    add('Apparence',[
      tg(['Sombre','dk'],()=>css('pnlDk','html{filter:invert(1) hue-rotate(180deg)}img,video,canvas,iframe{filter:invert(1) hue-rotate(180deg)}'),()=>css('pnlDk')),
      tg(['Niveaux de gris','gr'],()=>css('pnlGr','html{filter:grayscale(1)}'),()=>css('pnlGr')),
      tg(['Contraste élevé','hc'],()=>css('pnlHc','html{filter:contrast(1.4) saturate(1.3)}'),()=>css('pnlHc')),
      tg(['Flou','bl'],()=>css('pnlBl','#msgs,#list{filter:blur(4px)}'),()=>css('pnlBl')),
      tg(['Sans animations','na'],()=>css('pnlNa','*{animation:none!important;transition:none!important}'),()=>css('pnlNa')),
      tg(['Animations lentes','sl'],()=>css('pnlSl','*{animation-duration:3s!important;transition-duration:1.2s!important}'),()=>css('pnlSl')),
      tg(['Cacher les images','hi'],()=>css('pnlHi','img,video{visibility:hidden!important}'),()=>css('pnlHi')),
      tg(['Contours des éléments','ol'],()=>css('pnlOl','*{outline:1px solid rgba(217,75,95,.45)!important}'),()=>css('pnlOl')),
      tg(['Majuscules','up'],()=>css('pnlUp','#msgs{text-transform:uppercase}'),()=>css('pnlUp')),
      tg(['Texte retourné','fl'],()=>css('pnlFl','#msgs{transform:scaleX(-1)}'),()=>css('pnlFl')),
      tg(['Écran retourné','fv'],()=>css('pnlFv','body{transform:rotate(180deg)}'),()=>css('pnlFv'))]);
    const z=document.createElement('input');z.type='range';z.min=50;z.max=200;z.value=100;z.oninput=()=>{document.documentElement.style.zoom=(z.value/100)};
    const f=document.createElement('input');f.type='range';f.min=10;f.max=26;f.value=15;f.oninput=()=>css('pnlFs','body{font-size:'+f.value+'px!important}');
    const h=document.createElement('input');h.type='range';h.min=0;h.max=360;h.value=0;h.oninput=()=>css('pnlHue','html{filter:hue-rotate('+h.value+'deg)}');
    add('Curseurs : zoom, police, teinte',[z,f,h]);
    const cs=document.createElement('textarea');cs.rows=3;cs.placeholder='CSS à appliquer sur la page (local)';cs.oninput=()=>{const t=cs.value.replace(/@import|url\s*\(\s*['"]?\s*(https?:)?\/\//gi,'');css('pnlCss',t)};
    add('CSS libre',[cs]);
    add('Discussion ouverte',[
      tg(['Afficher les heures exactes','ts'],()=>{window.__pt_tsI=setInterval(()=>document.querySelectorAll('#msgs [data-mid]').forEach(r=>{if(r.querySelector('.pnl-ts'))return;const c=cur(),m=c&&(S.msgs[c.id]||[]).find(x=>String(x.id)===r.dataset.mid);if(!m)return;const t=document.createElement('small');t.className='pnl-ts';t.style.cssText='opacity:.6;margin:0 6px;font-size:10px';t.textContent=new Date(m.created_at).toLocaleString('fr-CA');r.appendChild(t)}),800)},()=>{clearInterval(window.__pt_tsI);document.querySelectorAll('.pnl-ts').forEach(x=>x.remove())}),
      tg(['Cacher les messages système','sy'],()=>css('pnlSy','.sys{display:none!important}'),()=>css('pnlSy')),
      tg(['Surligner les mentions','mn'],()=>css('pnlMn','.mention{background:#f59e0b!important;color:#000!important;padding:0 3px;border-radius:4px}'),()=>css('pnlMn')),
      act('Copier la discussion (texte)',()=>{const c=cur();if(!c)throw new Error('Ouvrez une discussion');const t=(S.msgs[c.id]||[]).map(m=>{const p=S.profiles.get(m.sender_id);return '['+new Date(m.created_at).toLocaleString('fr-CA')+'] '+((p&&p.username)||'?')+' : '+(((m._d&&m._d.t)||m.body)||'['+m.kind+']')}).join('\n');navigator.clipboard.writeText(t).then(()=>toast('Copié'),()=>toast('Copie refusée'))}),
      act('Exporter en fichier',()=>{const c=cur();if(!c)throw new Error('Ouvrez une discussion');const t=(S.msgs[c.id]||[]).map(m=>{const p=S.profiles.get(m.sender_id);return '['+new Date(m.created_at).toLocaleString('fr-CA')+'] '+((p&&p.username)||'?')+' : '+(((m._d&&m._d.t)||m.body)||'['+m.kind+']')}).join('\n');const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([t],{type:'text/plain'}));a.download='discussion.txt';a.click()}),
      act('Défiler en bas',()=>{const b=document.getElementById('msgs');if(b)b.scrollTop=b.scrollHeight}),
      act('Défiler en haut',()=>{const b=document.getElementById('msgs');if(b)b.scrollTop=0})]);
    add('Test d’affichage',[
      act('Fausse notification',()=>NT.push({title:'Test',text:'Notification de démonstration',detail:'Notification de démonstration'})),
      act('Message à l’écran',()=>toast('Message de démonstration')),
      act('Confettis',()=>{if(typeof confetti==='function')confetti(document.body)}),
      act('Afficher la taille de l’écran',()=>toast(innerWidth+' x '+innerHeight+' · ratio '+devicePixelRatio)),
      act('Fréquence d’images',()=>{let n=0,t0=performance.now();const f=()=>{n++;if(performance.now()-t0<1000)requestAnimationFrame(f);else toast(n+' images par seconde')};requestAnimationFrame(f)})]);
    add('Page',[
      tg(['Gomme (cliquer pour retirer)','gm'],()=>{window.__pt_gmH=e=>{if(e.target.closest('#pnlHost'))return;e.preventDefault();e.stopPropagation();e.target.remove()};document.addEventListener('click',window.__pt_gmH,true)},()=>document.removeEventListener('click',window.__pt_gmH,true)),
      tg(['Afficher les sélecteurs','sel'],()=>{window.__pt_selH=e=>{if(e.target.closest('#pnlHost'))return;const n=e.target;toast((n.id?'#'+n.id:'')+(n.className&&typeof n.className==='string'?'.'+n.className.trim().split(/\s+/).join('.'):'')+' <'+n.tagName.toLowerCase()+'>')};document.addEventListener('mouseover',window.__pt_selH,true)},()=>document.removeEventListener('mouseover',window.__pt_selH,true)),
      act('Recharger sans cache',()=>{try{caches.keys().then(k=>k.forEach(x=>caches.delete(x)))}catch(e){}location.reload()}),
      act('Vider mon cache local',()=>{if(!confirm('Vider le cache de ce navigateur pour le site ?'))return;try{caches.keys().then(k=>k.forEach(x=>caches.delete(x)))}catch(e){}toast('Cache vidé')}),
      act('Plein écran',()=>{document.documentElement.requestFullscreen&&document.documentElement.requestFullscreen()})]);
    const keys=Object.keys(localStorage).filter(k=>!BAD.test(k));
    add('Stockage local (sans les données sensibles)',[]);
    const pre=document.createElement('div');pre.className='mono';pre.textContent=keys.map(k=>k+' = '+String(localStorage.getItem(k)).slice(0,60)).join('\n')||'Vide';bd.appendChild(pre);
  },
  jeu(bd){
    const ss=S.sess;
    bd.innerHTML=`<h4>Jeu en cours</h4>${ss?`<div class="m">${esc2(ss.game)} · phase ${esc2(ss.phase)} · ${ss.players.length} joueur(s)</div>`:'<div class="m">Aucun jeu ou appel en cours.</div>'}
      <div class="r"><button id="jSt">Afficher les réponses et mains (état du jeu)</button><button id="jPv">Point de vue :</button><select id="jWho"><option value="">Tous</option>${ss?ss.players.map(p=>`<option value="${esc2(p)}">${esc2((S.profiles.get(p)||{}).username||'?')}</option>`).join(''):''}</select></div>
      <h4>Variables (sans les données sensibles)</h4><div class="r"><select id="vR">${Object.keys(roots()).map(k=>`<option>${esc2(k)}</option>`).join('')}</select><input id="vQ" placeholder="Rechercher un nom ou une valeur"><button id="vGo">Chercher</button></div>
      <div id="vOut" class="mono">…</div>`;
    const out=$r(bd,'#vOut');
    const run=who=>{const r=roots()[$r(bd,'#vR').value];if(!r)return;let o;try{o=r()}catch(e){o=null}const arr=[];flat(o,arr,'',0,new WeakSet());
      const q=($r(bd,'#vQ').value||'').toLowerCase();let L=arr.filter(([p,v])=>!q||p.toLowerCase().includes(q)||v.toLowerCase().includes(q));
      if(who)L=L.filter(([p])=>p.includes(who)||p.toLowerCase().includes(((S.profiles.get(who)||{}).username||'§').toLowerCase()));
      out.innerHTML=L.slice(0,500).map(([p,v])=>`<div class="kv"><i>${esc2(p)}</i><span>${esc2(v)}</span></div>`).join('')||'Aucun résultat';};
    $r(bd,'#vGo').onclick=()=>run('');
    $r(bd,'#jSt').onclick=()=>{if(blocked()){out.textContent='Le panneau est interdit dans cette partie.';return}if(!ss||!ss.state){out.textContent='Pas d’état de jeu (partie non commencée ou jeu entre pairs).';return}$r(bd,'#vR').value='S.sess (jeu en cours)';$r(bd,'#vQ').value='';run($r(bd,'#jWho').value)};
    $r(bd,'#jPv').onclick=()=>$r(bd,'#jSt').click();
    const bq=document.createElement('button');bq.textContent='Demander les mains privées (observateur)';bq.onclick=()=>{if(!S.sess)return toast('Aucun jeu en cours');if(blocked())return toast('Le panneau est interdit dans cette partie');try{rsend('privq',{u:S.me.id},S.sess);toast('Demande envoyée à l’hôte');setTimeout(()=>{$r(bd,'#vR').value='S.sess (jeu en cours)';$r(bd,'#vQ').value='pall';run('')},1800)}catch(e){toast(errMsg(e))}};
    $r(bd,'#jPv').parentNode.appendChild(bq);
    $r(bd,'#jWho').onchange=()=>$r(bd,'#jSt').click();
  },
  net(bd){
    const paint=()=>{bd.innerHTML=`<h4>Requêtes envoyées par ce client</h4><div class="r"><button id="nR">Rafraîchir</button><button id="nC">Vider</button></div><div class="mono">${spy.slice(-80).reverse().map(x=>`${new Date(x.t).toLocaleTimeString('fr-CA')} · ${esc2(x.fn)} · ${x.ms} ms${x.err?' · <span class="warn">'+esc2(x.err)+'</span>':''}\n  ${esc2(x.a)}`).join('\n')||'Rien pour l’instant.'}</div>`;
      $r(bd,'#nR').onclick=paint;$r(bd,'#nC').onclick=()=>{spy.length=0;paint()}};paint();
  },
  adm(bd){
    const TPL=['{u} a quitté le groupe','{u} a été retiré du groupe','{u} a été banni','{u} a rejoint le groupe','Erreur : action impossible pour le moment','Maintenance en cours : certaines fonctions sont temporairement indisponibles'];
    bd.innerHTML=`<div class="m">Le panneau sert au divertissement et à l’animation, jamais à nuire. Chaque action est consignée.</div>
      <h4>Message système (discussion ouverte)</h4>
      <div class="r"><select id="aT">${TPL.map(t=>`<option>${esc2(t)}</option>`).join('')}</select></div>
      <div class="r"><input id="aU" placeholder="nom d’utilisateur ({u})"><button id="aSend">Publier</button><input id="aFree" placeholder="ou texte libre"><button id="aFreeGo">Publier</button></div>
      <h4>Discussion ouverte : membres</h4>
      <div class="r"><input id="mU" placeholder="nom d’utilisateur"></div>
      <div class="r"><button id="mAdd">Ajouter</button><button id="mRem">Retirer du groupe</button><button id="mAdm">Promouvoir</button><button id="mMem">Rétrograder</button></div>
      <div class="r"><button id="mBan">Bannir</button><button id="mUnb">Lever le ban</button><button id="mRt">Donner les commandes des bots</button><button id="mRt0">Retirer ce droit</button><button id="mKick">Exclure de l’appel</button></div>
      <h4>Écrire à la place de quelqu’un (motif obligatoire, message étiqueté)</h4>
      <div class="r"><input id="sU" placeholder="nom d’utilisateur"></div><div class="r"><input id="sT" placeholder="message"></div><div class="r"><input id="sR" placeholder="motif justifié (10 caractères minimum)"><button id="sGo">Envoyer</button></div>
      <div class="r"><button id="vL">Regarder les consentants</button></div>
      <h4>Comptes de substitution (juste un surnom et un nom d’utilisateur)</h4>
      <div class="r"><input id="pU" placeholder="nom d’utilisateur"><input id="pN" placeholder="surnom"><button id="pNew">Créer</button><button id="pLs">Lister</button><button id="pDr">Supprimer (chefs)</button></div>
      <div class="r"><input id="pT" placeholder="message à envoyer dans la discussion ouverte"><input id="pR" placeholder="motif justifié (10 caractères minimum)"><button id="pSay">Envoyer</button></div>
      <h4>Écrire à un compte (nouvelle discussion, motif consigné)</h4>
      <div class="r"><input id="dU" placeholder="nom d’utilisateur"><input id="dR" placeholder="motif"><button id="dGo">Ouvrir</button></div>
      <h4>Commande de bot dans la discussion ouverte</h4><div class="r"><input id="cC" placeholder="!kick utilisateur"><button id="cGo">Envoyer</button></div>
      <h4>Jetons, badges, objets</h4>
      <div class="r"><input id="kU" placeholder="nom"><input id="kN" type="number" placeholder="montant (+/-)" style="max-width:110px"><input id="kR" placeholder="raison"><button id="kGo">Jetons</button><button id="kGoC">Jetons de casino</button></div>
      <div class="r"><input id="bC" placeholder="code du badge ou de l’objet"><button id="bG">Donner badge</button><button id="bR">Retirer badge</button><button id="iG">Donner objet</button><button id="iR">Retirer objet</button></div>
      <div class="r"><button id="wV">Voir le portefeuille</button></div>
      <h4>Sanctions du site</h4>
      <div class="r"><input id="xU" placeholder="nom d’utilisateur"><input id="xS" type="number" placeholder="secondes (0 = définitif)" style="max-width:120px"><input id="xR" placeholder="motif"></div>
      <div class="r"><button id="xB">Bannir le compte</button><button id="xU0">Lever le ban du compte</button><button id="xBI">Bannir aussi ses adresses IP</button><button id="xU1">Lever ban compte et IP</button></div>
      <div class="r"><button id="xW">Avertir</button><button id="xI">Qui est-ce ?</button><button id="xL">Liste des bannis</button></div>
      <div class="m">« Bannir le compte » ne touche pas aux adresses IP. Un compte banni est déconnecté en quelques secondes et ne peut plus se reconnecter.</div>
      <h4>Qui s’est connecté depuis cette adresse IP ?</h4><div class="r"><input id="ipQ" placeholder="adresse IP"><button id="ipGo">Chercher les comptes</button></div>
      <h4>Annonces et groupes</h4>
      <div class="r"><input id="nT" placeholder="annonce pour tous (chefs)"><button id="nGo">Annoncer</button></div>
      <div class="r"><input id="gQ" placeholder="chercher un groupe"><button id="gL">Lister</button></div>
      <div class="r"><input id="gN" type="number" placeholder="n° du groupe" style="max-width:110px"><input id="gUk" placeholder="nom"><button id="gK">Retirer du groupe</button><button id="gC">Vider le groupe</button></div>
      <div class="r"><input id="yU" placeholder="nom d’utilisateur"><button id="yI">IP</button><button id="yD">Appareils</button></div>
      <h4>Invisibilité</h4><div class="r"><button id="vG" class="${st.vanish?'on':''}">${st.vanish?'Invisible partout : activé':'Invisible partout'}</button><button id="vC">Invisible dans cette discussion</button><button id="vC0">Visible dans cette discussion</button></div>
      <div class="m">Invisible : vous disparaissez des listes de membres et des appels pour les autres ; dans un appel vous pouvez parler, et dans un jeu vous ne pouvez pas jouer.</div>
      <h4>Compte bidon / classe / biome</h4><div class="r"><input id="qU" placeholder="nom d’utilisateur"><button id="qGo">Évaluer</button></div>
      <div class="r"><label class="m"><input type="checkbox" id="oD"> Point orange sur les messages des comptes bidon (affichage local)</label></div>
      <div id="qO" class="mono" style="display:none"></div>`;
    const c=()=>{const x=cur();if(!x)throw new Error('Ouvrez une discussion');return x};
    const val=i=>$r(bd,i).value.trim();
    const go=(id,fn)=>{$r(bd,id).onclick=async()=>{try{await fn();}catch(e){toast(errMsg(e))}}};
    const out=t=>{const o=$r(bd,'#qO');o.style.display='';o.textContent=typeof t==='string'?t:JSON.stringify(t,null,1)};
    const reload=async()=>{try{const x=cur();if(x){await loadMsgs(x);renderMsgs(true)}}catch(e){}};
    go('#aSend',async()=>{let t=$r(bd,'#aT').value;const u=val('#aU').replace(/^@/,'');if(t.includes('{u}')){if(!u)throw new Error('Indiquez un nom');t=t.replace('{u}','@'+u)}await rpcd('panel_sysmsg',{p_conv:c().id,p_text:t});toast('Message publié');reload()});
    go('#aFreeGo',async()=>{const t=val('#aFree');if(!t)return;await rpcd('panel_sysmsg',{p_conv:c().id,p_text:t});$r(bd,'#aFree').value='';toast('Message publié');reload()});
    go('#mAdd',async()=>{await rpcd('panel_add',{p_conv:c().id,p_username:val('#mU')});toast('Ajouté');await loadConvs();renderList();reload()});
    go('#mRem',async()=>{await rpcd('panel_remove',{p_conv:c().id,p_username:val('#mU')});toast('Retiré du groupe');await loadConvs();renderList();reload()});
    go('#mAdm',async()=>{await rpcd('panel_rank',{p_conv:c().id,p_username:val('#mU'),p_admin:true});toast('Promu');loadConvs()});
    go('#mMem',async()=>{await rpcd('panel_rank',{p_conv:c().id,p_username:val('#mU'),p_admin:false});toast('Rétrogradé');loadConvs()});
    go('#mBan',async()=>{await rpcd('panel_cban',{p_conv:c().id,p_username:val('#mU'),p_secs:0});toast('Banni du groupe');await loadConvs();renderList();reload()});
    go('#mUnb',async()=>{await rpcd('panel_cunban',{p_conv:c().id,p_username:val('#mU')});toast('Ban levé')});
    go('#mRt',async()=>{await rpcd('panel_right',{p_conv:c().id,p_username:val('#mU'),p_on:true});toast('Droit accordé : la personne peut utiliser les commandes des bots ici')});
    go('#mRt0',async()=>{await rpcd('panel_right',{p_conv:c().id,p_username:val('#mU'),p_on:false});toast('Droit retiré')});
    go('#mKick',async()=>{const t=val('#mU').replace(/^@/,'').toLowerCase();if(!t)throw new Error('Indiquez un nom');const cv=c();
      const lv=await rpcd('live_list',{p_conv:cv.id});const l=lv.find(x=>x.kind==='call')||lv[0];if(!l)throw new Error('Aucun appel en cours dans ce groupe');
      const ch=sb.channel('room-'+l.session,{config:{broadcast:{self:false}}});
      await new Promise((res,rej)=>{const to=setTimeout(()=>rej(new Error('Connexion à l’appel impossible')),6000);ch.subscribe(s=>{if(s==='SUBSCRIBED'){clearTimeout(to);res()}})});
      await bcast(ch,'bot',cv,{b:'panel',k:'$kick',d:{u:t},f:S.profile.username});setTimeout(()=>{try{sb.removeChannel(ch)}catch(e){}},1500);toast('Exclusion envoyée')});
    go('#sGo',async()=>{await rpcd('speak_as',{p_conv:c().id,p_username:val('#sU'),p_text:val('#sT'),p_reason:val('#sR')});$r(bd,'#sT').value='';toast('Message envoyé');reload()});
    go('#dGo',async()=>{const id=await rpcd('panel_dm',{p_username:val('#dU'),p_reason:val('#dR')});await loadConvs();renderList();openConv(id)});
    go('#cGo',async()=>{const t=val('#cC');if(!t)return;await sendPayload(c(),{k:'text',t});$r(bd,'#cC').value=''});
    go('#kGo',async()=>{await rpcd('admin_tokens',{p_username:val('#kU'),p_amount:+$r(bd,'#kN').value,p_reason:val('#kR')||'panneau'});toast('Jetons modifiés')});
    go('#kGoC',async()=>{const d=await rpcd('admin_chips',{p_username:val('#kU'),p_amount:+$r(bd,'#kN').value,p_reason:val('#kR')||'panneau'});toast('Solde de casino : '+d)});
    go('#bG',async()=>{await rpcd('admin_badge',{p_username:val('#kU'),p_code:val('#bC'),p_give:true});toast('Badge donné')});
    go('#bR',async()=>{await rpcd('admin_badge',{p_username:val('#kU'),p_code:val('#bC'),p_give:false});toast('Badge retiré')});
    go('#iG',async()=>{await rpcd('admin_item',{p_username:val('#kU'),p_code:val('#bC'),p_give:true});toast('Objet donné')});
    go('#iR',async()=>{await rpcd('admin_item',{p_username:val('#kU'),p_code:val('#bC'),p_give:false});toast('Objet retiré')});
    go('#wV',async()=>out(await rpcd('admin_wallet',{p_username:val('#kU')})));
    go('#xB',async()=>{await rpcd('staff_ban',{p_username:val('#xU'),p_ip:null,p_secs:+$r(bd,'#xS').value||0,p_reason:val('#xR')||'panneau'});toast('Compte banni (sans les adresses IP)')});
    go('#xBI',async()=>{await rpcd('staff_ban_user_ips',{p_username:val('#xU'),p_secs:+$r(bd,'#xS').value||0,p_reason:val('#xR')||'panneau'});toast('Adresses IP bannies')});
    go('#xU0',async()=>{const n=await rpcd('staff_unban_user',{p_username:val('#xU'),p_ips:false});toast(n?'Ban levé':'Aucun ban actif')});
    go('#xU1',async()=>{const n=await rpcd('staff_unban_user',{p_username:val('#xU'),p_ips:true});toast(n?'Bans levés ('+n+')':'Aucun ban actif')});
    go('#ipGo',async()=>{const l=await rpcd('staff_ip_users',{p_ip:val('#ipQ')});out(l.length?l.map(x=>'@'+x.username+(x.nickname?' ('+x.nickname+')':'')+' · dernière connexion '+new Date(x.last).toLocaleString('fr-CA')).join('\n'):'Aucun compte connu pour cette adresse')});
    go('#vL',async()=>{const l=await rpcd('speak_vol_list');out(l.length?l.map(x=>'@'+x.username+(x.nickname?' ('+x.nickname+')':'')).join('\n'):'Aucun volontaire')});
    go('#pNew',async()=>{const u=await rpcd('panel_puppet_new',{p_username:val('#pU'),p_nickname:val('#pN')});toast('Compte créé : @'+u)});
    go('#pLs',async()=>{const l=await rpcd('panel_puppets_list');out(l.length?l.map(x=>'@'+x.username+(x.nickname?' ('+x.nickname+')':'')).join('\n'):'Aucun compte de substitution')});
    go('#pDr',async()=>{if(!confirm('Supprimer ce compte de substitution ?'))return;await rpcd('panel_puppet_drop',{p_username:val('#pU')});toast('Supprimé')});
    go('#pSay',async()=>{await rpcd('panel_puppet_say',{p_conv:c().id,p_username:val('#pU'),p_text:val('#pT'),p_reason:val('#pR')});$r(bd,'#pT').value='';toast('Message envoyé');reload()});
    go('#xW',async()=>{await rpcd('staff_warn',{p_username:val('#xU'),p_reason:val('#xR')||'avertissement'});toast('Avertissement envoyé')});
    go('#xI',async()=>out(await rpcd('staff_who',{p_username:val('#xU')})));
    go('#xL',async()=>out(await rpcd('staff_ban_list')));
    go('#nGo',async()=>{const t=val('#nT');if(!t)return;await rpcd('world_post',{p_users:null,p_body:t});toast('Annonce envoyée');$r(bd,'#nT').value=''});
    go('#gL',async()=>out(await rpcd('staff_group_list',{p_q:val('#gQ')||null})));
    go('#gK',async()=>{await rpcd('staff_group_kick',{p_num:+$r(bd,'#gN').value,p_username:val('#gUk')});toast('Retiré')});
    go('#gC',async()=>{if(!confirm('Vider ce groupe ?'))return;await rpcd('staff_group_clear',{p_num:+$r(bd,'#gN').value});toast('Groupe vidé')});
    go('#yI',async()=>out(await rpcd('staff_user_ips',{p_username:val('#yU')})));
    go('#yD',async()=>out(await rpcd('staff_user_devices',{p_username:val('#yU')})));
    go('#vG',async()=>{const on=!st.vanish;await rpcd('panel_vanish',{p_on:on});st.vanish=on;show('adm')});
    go('#vC',async()=>{await rpcd('panel_vanish',{p_on:true,p_conv:c().id});toast('Invisible dans cette discussion')});
    go('#vC0',async()=>{await rpcd('panel_vanish',{p_on:false,p_conv:c().id});toast('Visible dans cette discussion')});
    go('#qGo',async()=>{const r=await rpcd('acct_class',{p_username:val('#qU')});out(r.class.toUpperCase()+'  (bidon '+r.bad+' · classe '+r.good+')\n'+(r.details||[]).join('\n'))});
    const od=$r(bd,'#oD');od.checked=rules.some(r=>r.w==='bidon'&&r.a==='dot'&&r.v==='#f97316');
    od.onchange=()=>{rules=rules.filter(r=>!(r.w==='bidon'&&r.a==='dot'&&r.v==='#f97316'));if(od.checked)rules.push({w:'bidon',a:'dot',v:'#f97316'});LSset('cm_pnl_rules',rules);clsCache={};rulesSoon()};
  },
  srv(bd){
    bd.innerHTML=`<h4>Console du serveur (lecture)</h4><div class="r"><button id="sC">Charger</button></div><div id="sO" class="mono">…</div>`;
    $r(bd,'#sC').onclick=async()=>{try{const d=await rpcd('panel_console',{p_n:40});const f=a=>(a||[]).map(x=>Object.values(x).map(v=>esc2(typeof v==='string'&&/^\d{4}-/.test(v)?new Date(v).toLocaleString('fr-CA'):v)).join(' · ')).join('\n');
      $r(bd,'#sO').innerHTML='<b>Journal d’administration</b>\n'+f(d.admin)+'\n\n<b>Alertes de journaux</b>\n'+f(d.alerts)+'\n\n<b>Panneau</b>\n'+f(d.panel)}catch(e){toast(errMsg(e))}};
  },
  cmd(bd){
    bd.innerHTML=`<h4>Code de flèches et NIP</h4><div class="m">Le code (U haut, D bas, L gauche, R droite, 4 à 24) et le NIP (8 lettres) sont gardés par le serveur. Laissez le NIP vide pour le conserver.</div>
      <div class="r"><input id="cS" placeholder="Code"><input id="cP" placeholder="NIP (8 lettres)" maxlength="8"><button id="cSet">Enregistrer</button></div>
      <h4>Accès au panneau</h4><div class="r"><input id="cU" placeholder="nom d’utilisateur"><button id="cG">Donner</button><button id="cR">Retirer</button><button id="cX">Débloquer</button></div>
      <div class="r"><button id="cA">Retirer à tout le monde (sauf administrateurs)</button><button id="cL">Liste</button><button id="cV">Qui utilise le panneau maintenant</button></div><div id="cO" class="mono" style="display:none"></div>`;
    rpcd('panel_cfg_info').then(i=>{$r(bd,'#cS').value=i.seq;$r(bd,'#cP').placeholder=i.pin?'NIP défini (vide = inchangé)':'NIP (8 lettres)'}).catch(()=>{});
    const go=(id,fn)=>{$r(bd,id).onclick=async()=>{try{await fn()}catch(e){toast(errMsg(e))}}};
    go('#cSet',async()=>{await rpcd('panel_cfg_set',{p_seq:$r(bd,'#cS').value.trim().toUpperCase(),p_pin:$r(bd,'#cP').value.trim()||null});$r(bd,'#cP').value='';toast('Enregistré');refresh()});
    go('#cG',async()=>{await rpcd('panel_admin',{p_username:$r(bd,'#cU').value,p_action:'grant'});toast('Accès donné')});
    go('#cR',async()=>{await rpcd('panel_admin',{p_username:$r(bd,'#cU').value,p_action:'revoke'});toast('Accès retiré')});
    go('#cX',async()=>{await rpcd('panel_admin',{p_username:$r(bd,'#cU').value,p_action:'reset'});toast('Blocage levé')});
    go('#cA',async()=>{if(!confirm('Retirer l’accès à tous les non-administrateurs ?'))return;await rpcd('panel_admin',{p_username:null,p_action:'revoke_all'});toast('Accès retiré')});
    go('#cV',async()=>{const l=await rpcd('panel_active');const o=$r(bd,'#cO');o.style.display='';o.textContent=l.length?l.map(x=>`@${x.username} · rang ${x.rank} · il y a ${x.secs} s`).join('\n'):'Personne n’utilise le panneau en ce moment.'});
    go('#cL',async()=>{const l=await rpcd('panel_users_list');const o=$r(bd,'#cO');o.style.display='';o.textContent=l.map(x=>`@${x.username} · ${x.banned?'BLOQUÉ':x.revoked?'retiré':x.unlocked?'actif':'-'} · échecs ${x.fails} · rang ${x.rank}`).join('\n')||'Personne.'});
  }
};

/* ---------- 8) invisibilité : masque les comptes invisibles dans les listes et les appels ---------- */
function vanApply(){
  const c=(typeof cur==='function'&&cur())||null,ss=S.sess;
  const here=new Set([...vanList].filter(v=>!v.conv||(c&&v.conv===c.id)||(ss&&v.conv===ss.conv)).map(v=>v.id));
  const nm=new Set([...here].map(id=>(S.profiles.get(id)||{}).username).filter(Boolean));
  document.querySelectorAll('[data-u]').forEach(el=>{if(here.has(el.dataset.u)&&(el.classList.contains('tile')||el.classList.contains('lb-p')||el.classList.contains('mem')||el.closest('#rmTiles')))el.style.display='none'});
  document.querySelectorAll('.modal .row,.modal .mrow,.chips .chip,.members .row,#paneFriends .row,.lb-p').forEach(el=>{
    const a=el.querySelector('[data-un]');if(a&&nm.has(a.dataset.un)&&!el.querySelector('input,textarea'))el.style.display='none'});
  try{if(S.online)nm.forEach(n=>{if(S.profile&&n!==S.profile.username)S.online.delete(n)})}catch(e){}
}
let vanList=[];
window.PNLOK=()=>!!st.unlocked;
window.VANH=(cid,uid)=>{try{return !!S.me&&uid!==S.me.id&&vanList.some(v=>v.id===uid&&(!v.conv||v.conv===cid))}catch(e){return false}};
async function vanRefresh(){
  try{const vl=await rpcd('panel_vanished');vanList=Array.isArray(vl)?vl:[]}catch(e){return}
  vanApply();
}

function panelGate(){if(!host)return;if(blocked()){if(host.style.display!=='none'){host.dataset.gate='1';host.style.display='none'}}else if(host.dataset.gate){delete host.dataset.gate;host.style.display=''}}
function viaMark(){
  const mark=()=>{const c=(typeof cur==='function'&&cur())||null;if(!c||!S.msgs)return;const arr=S.msgs[c.id]||[];
    document.querySelectorAll('#msgs [data-mid]').forEach(r=>{if(r.dataset.via!=null)return;const m=arr.find(x=>String(x.id)===r.dataset.mid);if(m&&m.via)r.dataset.via=m.via==='A'?'panel-A':'volontaire-V'});};
  setInterval(mark,1500);
}
/* ---------- 9) démarrage ---------- */
function boot(){
  installSpy();
  document.addEventListener('keydown',onKey,true);
  document.addEventListener('contextmenu',e=>{if(window.__pnlRc)e.stopImmediatePropagation()},true);
  hookSettings();
  let tries=0;const iv=setInterval(async()=>{if(!ready()||busy)return;busy=true;const ok=await refresh();busy=false;if(!ok&&++tries<40)return;clearInterval(iv);layLoad();vanRefresh();rpcd('speak_vol_tick').then(g=>{if(+g>0){toast('+'+g+' jetons (volontariat)');try{balRefresh()}catch(e){}}}).catch(()=>{});setInterval(()=>{vanRefresh();layLoad()},60000);setInterval(()=>{vanApply();panelGate()},1200);setInterval(()=>{if(st.unlocked&&host&&host.style.display!=='none')sb.rpc('panel_ping')},45000);viaMark();
    if(st.unlocked&&LS('cm_pnl_open',false))openPanel();
    const msgs=document.getElementById('msgs');if(msgs)new MutationObserver(rulesSoon).observe(msgs,{childList:true,subtree:true});},1500);
  window.addEventListener('pnlstate',()=>{});
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
})();
