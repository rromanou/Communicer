/* Casino Communicer! — front. Chargé après app.js (partage ses globales). Aucune globale sauf openCasino et CZ. */
(function(){
'use strict';
if(window.CZ&&window.CZ._loaded)return;
const D=document;
const $=(s,r)=>(r||D).querySelector(s),$$=(s,r)=>Array.from((r||D).querySelectorAll(s));
const ESC0=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const E=s=>(typeof esc==='function'?esc(s):ESC0(s));
const nf=n=>typeof nfmt==='function'?nfmt(n):String(Math.floor(+n||0));
const nfl=n=>typeof nfull==='function'?nfull(n):(Math.round((+n||0)*10)/10).toLocaleString('fr-CA');
const EM=e=>typeof errMsg==='function'?errMsg(e):((e&&e.message)||String(e));
const RPC=(fn,a)=>typeof rpcd==='function'?rpcd(fn,a||{}):Promise.reject(new Error('Hors ligne'));
const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
const rnd=(a,b)=>a+Math.random()*(b-a);
const pick=a=>a[Math.floor(Math.random()*a.length)];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const num=x=>{x=+x;return isFinite(x)?x:0};
const lsGet=k=>{try{return localStorage.getItem(k)}catch(e){return null}};
const lsSet=(k,v)=>{try{localStorage.setItem(k,v)}catch(e){}};
let lastSay={m:'',t:0};
const say=m=>{m=String(m||'');const n=Date.now();if(m===lastSay.m&&n-lastSay.t<2500)return;lastSay={m,t:n};if(typeof toast==='function')toast(m);else console.log(m)};
const mulberry=a=>()=>{a|=0;a=a+0x6D2B79F5|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296};
const hashStr=s=>{let h=2166136261;for(const c of String(s)){h^=c.charCodeAt(0);h=Math.imul(h,16777619)}return h>>>0};
const colOk=(c,d)=>/^#[0-9a-f]{3,8}$/i.test(c||'')?c:d;

/* ---------- portée : timers / listeners nettoyés d'un coup ---------- */
function scope(){
  const s={t:new Set(),i:new Set(),f:new Set(),l:[],d:[],dead:false};
  s.to=(fn,ms)=>{const id=setTimeout(()=>{s.t.delete(id);if(!s.dead)fn()},ms);s.t.add(id);return id};
  s.iv=(fn,ms)=>{const id=setInterval(()=>{if(!s.dead)fn()},ms);s.i.add(id);return id};
  s.clr=id=>{clearTimeout(id);clearInterval(id);s.t.delete(id);s.i.delete(id)};
  s.frame=fn=>{const h={id:0};const tick=t=>{if(s.dead){return}let r;try{r=fn(t)}catch(e){console.error(e);r=false}if(r===false){s.f.delete(h);return}h.id=requestAnimationFrame(tick);};h.id=requestAnimationFrame(tick);s.f.add(h);return h};
  s.stop=h=>{if(h){cancelAnimationFrame(h.id);s.f.delete(h)}};
  s.on=(el,ev,fn,o)=>{el.addEventListener(ev,fn,o);s.l.push([el,ev,fn,o])};
  s.onEnd=fn=>{s.d.push(fn)};
  s.dispose=()=>{if(s.dead)return;s.dead=true;s.t.forEach(clearTimeout);s.i.forEach(clearInterval);s.f.forEach(h=>cancelAnimationFrame(h.id));s.l.forEach(([el,ev,fn,o])=>el.removeEventListener(ev,fn,o));s.t.clear();s.i.clear();s.f.clear();s.l=[];const d=s.d;s.d=[];d.forEach(f=>{try{f()}catch(e){}})};
  return s;
}

/* ---------- action protégée (anti double-clic) ---------- */
const busy=new Set();
async function act(key,fn,btn){
  if(busy.has(key))return;busy.add(key);if(btn)btn.classList.add('busy');
  try{return await fn()}catch(e){say(EM(e))}finally{busy.delete(key);if(btn)btn.classList.remove('busy')}
}

/* ---------- données de base : symboles, jetons, cartes ---------- */
const SPRITE=`<svg class="cz-sprite" width="0" height="0" aria-hidden="true" style="position:absolute"><defs>
<radialGradient id="czg-red" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#ff8a80"/><stop offset=".45" stop-color="#e0262b"/><stop offset="1" stop-color="#7d0a14"/></radialGradient>
<radialGradient id="czg-gold" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#fff3b0"/><stop offset=".4" stop-color="#f5c542"/><stop offset="1" stop-color="#9a6a0b"/></radialGradient>
<radialGradient id="czg-silver" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#fff"/><stop offset=".5" stop-color="#c3c9d2"/><stop offset="1" stop-color="#6c7482"/></radialGradient>
<radialGradient id="czg-green" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#9af0a6"/><stop offset=".5" stop-color="#2faa4a"/><stop offset="1" stop-color="#0d5a22"/></radialGradient>
<radialGradient id="czg-blue" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#a6d8ff"/><stop offset=".5" stop-color="#2b7be0"/><stop offset="1" stop-color="#0b2f77"/></radialGradient>
<radialGradient id="czg-purple" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#e2b6ff"/><stop offset=".5" stop-color="#8a3fd3"/><stop offset="1" stop-color="#3b0f77"/></radialGradient>
<radialGradient id="czg-yellow" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#fffbb8"/><stop offset=".5" stop-color="#f6dc2a"/><stop offset="1" stop-color="#a98a05"/></radialGradient>
<radialGradient id="czg-orange" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#ffd09a"/><stop offset=".5" stop-color="#f08a1a"/><stop offset="1" stop-color="#8f4605"/></radialGradient>
<radialGradient id="czg-pink" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#ffd0e8"/><stop offset=".5" stop-color="#f05aa6"/><stop offset="1" stop-color="#8f1553"/></radialGradient>
<linearGradient id="czg-goldl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff0a8"/><stop offset=".5" stop-color="#e5b02c"/><stop offset="1" stop-color="#8d610a"/></linearGradient>
<linearGradient id="czg-chrome" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#6d7480"/><stop offset=".25" stop-color="#f4f6f9"/><stop offset=".5" stop-color="#9aa2ae"/><stop offset=".75" stop-color="#eef1f5"/><stop offset="1" stop-color="#5d6470"/></linearGradient>
<linearGradient id="czg-holo" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff4fd8"/><stop offset=".25" stop-color="#4fd2ff"/><stop offset=".5" stop-color="#7dff8a"/><stop offset=".75" stop-color="#ffe14f"/><stop offset="1" stop-color="#ff4fd8"/></linearGradient>
<radialGradient id="czg-shade" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>
<symbol id="czs-s" viewBox="0 0 24 24"><path d="M12 1C9 7 3 9 3 14.5a5 5 0 0 0 8.2 3.8C11 20.5 10 22 8 23h8c-2-1-3-2.500-3.200-4.700A5 5 0 0 0 21 14.500C21 9 15 7 12 1z"/></symbol>
<symbol id="czs-h" viewBox="0 0 24 24"><path d="M12 22C4 15.500 2 11.500 2 8a5.500 5.500 0 0 1 10-3 5.500 5.500 0 0 1 10 3c0 3.500-2 7.500-10 14z"/></symbol>
<symbol id="czs-d" viewBox="0 0 24 24"><path d="M12 1.500c3 4 7 7.500 9.500 10.500C19 15 15 18.500 12 22.500 9 18.500 5 15 2.500 12 5 9 9 5.500 12 1.500z"/></symbol>
<symbol id="czs-c" viewBox="0 0 24 24"><path d="M12 1.500a5 5 0 0 0-4.500 7.200A5.200 5.200 0 1 0 11 16.500C11 19.500 10 21.500 8 23h8c-2-1.500-3-3.500-3-6.500A5.200 5.200 0 1 0 16.500 8.700 5 5 0 0 0 12 1.500z"/></symbol>
</defs></svg>`;

const RED=new Set([1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
const WHEEL=[0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26];
const numCol=n=>n===0?'g':RED.has(n)?'r':'b';

/* jetons */
const DEN=[[10000,'#e04aa0'],[5000,'#8a8f99'],[1000,'#d4af37'],[500,'#7b3fc9'],[100,'#1d1d22'],[50,'#e8832a'],[25,'#1f9d55'],[10,'#2a6fd6'],[5,'#d33a3a'],[1,'#ececec']];
const chipI=(c,y,v)=>`<i class="cz-chip" style="--c:${c};--y:${y}px"${v!=null?` title="${v}"`:''}></i>`;
function chipStack(amount,maxCols){
  amount=Math.floor(num(amount));if(amount<=0)return '';maxCols=maxCols||3;
  const cols=[];let rest=amount;
  for(const [v,c] of DEN){const n=Math.floor(rest/v);if(n>0){cols.push([v,c,n]);rest-=n*v}}
  cols.sort((a,b)=>b[0]*b[2]-a[0]*a[2]);const top=cols.slice(0,maxCols);
  return `<span class="cz-stack">${top.map(([v,c,n])=>`<span class="cz-col">${Array.from({length:Math.min(n,6)},(_,i)=>chipI(c,-i*3.2)).join('')}</span>`).join('')}</span>`;
}
const chipBtn=(v)=>{const d=DEN.find(x=>x[0]===v);const c=d?d[1]:(v>1000?'#d4af37':'#2a6fd6');return `<span class="cz-bigchip" style="--c:${c}"><b>${v>=1000?v/1000+'k':v}</b></span>`};

/* cartes */
const SUITN={s:'s',h:'h',d:'d',c:'c'};
const RANKD=r=>r==='T'?'10':r;
function cardInner(code){
  if(!code||code==='??')return '';
  const r=code[0],s=code[1];const red=s==='h'||s==='d';const face='JQKA'.includes(r);
  const su=`<svg class="su"><use href="#czs-${s}"/></svg>`;
  return `<div class="f ${red?'red':'blk'}"><span class="cn"><b>${RANKD(r)}</b>${su}</span><span class="cn bt"><b>${RANKD(r)}</b>${su}</span><span class="mid ${face?'face':''}">${face?`<em>${r}</em>`:''}<svg class="su big"><use href="#czs-${s}"/></svg></span></div>`;
}
function cardEl(code,up,cls){
  const d=D.createElement('div');d.className='cz-card'+(up&&code&&code!=='??'?' up':'')+(cls?' '+cls:'');d.dataset.c=code||'??';
  d.innerHTML=`<div class="in"><div class="bk"></div>${cardInner(code)}</div>`;return d;
}
const cardHtml=(code,cls)=>{const up=code&&code!=='??';return `<div class="cz-card${up?' up':''}${cls?' '+cls:''}" data-c="${E(code||'??')}"><div class="in"><div class="bk"></div>${cardInner(code)}</div></div>`};
const POKERN={s:'Pique',h:'Coeur',d:'Carreau',c:'Trèfle'};

/* ---------- personnage fumeur (buste assis) ---------- */
const HAIRB=(h,c)=>({longs:`<path d="M14 46C10 70 12 92 22 96l10-30z M86 46c4 24 2 46-8 50L68 66z" fill="${c}"/><path d="M16 50C14 22 30 6 50 6s36 16 34 44z" fill="${c}"/>`,tresses:`<path d="M16 50C14 22 30 6 50 6s36 16 34 44z" fill="${c}"/><path d="M14 50c-8 10-8 26-2 40 6-4 10-14 12-30z M86 50c8 10 8 26 2 40-6-4-10-14-12-30z" fill="${c}"/>`,afro:`<circle cx="50" cy="38" r="40" fill="${c}"/>`,chignon:`<circle cx="50" cy="8" r="11" fill="${c}"/>`}[h]||'');
const HAIRF=(h,c)=>({court:`<path d="M17 46C14 20 30 8 50 8s36 12 33 38c-4-12-12-20-33-20S21 34 17 46z" fill="${c}"/>`,frange:`<path d="M16 48C13 20 30 7 50 7s37 13 34 41c-2-10-6-18-12-22-6 8-26 10-40 6-4 4-8 10-16 16z" fill="${c}"/>`,longs:`<path d="M17 48C16 22 32 9 50 9s34 13 33 39c-6-14-14-24-33-24S23 34 17 48z" fill="${c}"/>`,tresses:`<path d="M17 46C14 20 30 8 50 8s36 12 33 38c-4-12-12-20-33-20S21 34 17 46z" fill="${c}"/>`,chignon:`<path d="M17 46C14 20 30 10 50 10s36 10 33 36c-4-12-12-20-33-20S21 34 17 46z" fill="${c}"/>`,afro:`<path d="M17 44C20 24 34 16 50 16s30 8 33 28c-6-10-16-14-33-14S23 34 17 44z" fill="${c}"/>`,cret:`<path d="M42 22L40 0l8 12 2-14 4 14 6-12-2 22z" fill="${c}"/><path d="M17 40c4-6 10-10 12-10M83 40c-4-6-10-10-12-10" stroke="${c}" stroke-width="3" fill="none"/>`,chauve:`<ellipse cx="40" cy="18" rx="8" ry="3.5" fill="#fff" opacity=".25"/>`}[h]||HAIRF('court',c));
function eyesSvg(e,k){
  let rx=6,ry=6,ir=3;if(e==='fins')ry=3.6;if(e==='grands'){rx=7.5;ry=7.5;ir=4}if(e==='endormis')ry=2.6;
  if(e==='joyeux')return `<path d="M29 54q7-9 14 0M57 54q7-9 14 0" stroke="${k}" stroke-width="3.2" fill="none" stroke-linecap="round"/>`;
  return `<ellipse cx="36" cy="52" rx="${rx}" ry="${ry}" fill="#fff"/><ellipse cx="64" cy="52" rx="${rx}" ry="${ry}" fill="#fff"/><ellipse cx="37" cy="52" rx="${ir}" ry="${Math.min(ir,ry)}" fill="${k}"/><ellipse cx="65" cy="52" rx="${ir}" ry="${Math.min(ir,ry)}" fill="${k}"/><circle cx="38.2" cy="50.6" r="1" fill="#fff"/><circle cx="66.2" cy="50.6" r="1" fill="#fff"/>`;
}
const EMB=`<circle cx="0" cy="0" r="3" fill="#ff7a1a"><animate attributeName="opacity" values=".6;1;.7;1" dur=".6s" repeatCount="indefinite"/></circle>`;
function itemSvg(kind){
  if(kind==='vape')return `<g transform="translate(56 68) rotate(-14)"><rect x="0" y="-4" width="34" height="8" rx="4" fill="#2b2f36"/><rect x="0" y="-4" width="8" height="8" rx="3" fill="#161a1f"/><circle cx="22" cy="0" r="1.8" fill="#37c6ff"><animate attributeName="opacity" values="0.3;1;0.3" dur="1s" repeatCount="indefinite"/></circle></g>`;
  if(kind==='cigar')return `<g transform="translate(56 68) rotate(-12)"><rect x="0" y="-4.5" width="36" height="9" rx="3" fill="#6b3f1d"/><rect x="22" y="-4.5" width="4" height="9" fill="#d9b25a"/><g transform="translate(37 0)"><circle r="4.4" fill="#444"/>${EMB}</g></g>`;
  if(kind==='joint')return `<g transform="translate(56 68) rotate(-12)"><path d="M0 -1.6L36 -4.6V4.6L0 1.6z" fill="#efe6c9"/><path d="M6 -1.4L10 -1.8V1.8L6 1.4z" fill="#c7b98d"/><g transform="translate(36 0)"><circle r="3.6" fill="#6a5a2e"/>${EMB}</g></g>`;
  return `<g transform="translate(56 68) rotate(-12)"><rect x="0" y="-2.2" width="34" height="4.4" rx="1.5" fill="#f6f3ec"/><rect x="0" y="-2.2" width="9" height="4.4" rx="1.5" fill="#d98a3a"/><g transform="translate(35 0)"><circle r="2.7" fill="#555"/>${EMB}</g></g>`;
}
const SHIRTS=['#3c5a8a','#7a3b4a','#2f6a5a','#6a5a2f','#4a3a7a','#8a4a2a','#2f4a4a','#7a2f5a'];
const charCache=new Map();
function charSvg(look,o){
  o=o||{};look=look&&typeof look==='object'?look:{};
  const key=JSON.stringify([look.hair,look.hc,look.eyes,look.ec,look.skin,look.item,look.outfit,o.mood,o.name]);
  const hit=charCache.get(key);if(hit)return hit;
  const hair=look.hair||'court',hc=colOk(look.hc,'#3b2a1d'),ec=colOk(look.ec,'#2a1d12'),sk=colOk(look.skin,'#f1c9a5');
  const item=look.item||null,crou=look.outfit==='croupier';
  const shirt=SHIRTS[hashStr(o.name||hc+sk)%SHIRTS.length];
  const BD='M-4 134C-2 108 20 94 38 90h24c18 4 40 18 42 44z';
  let body;
  if(crou)body=`<path d="${BD}" fill="#f7f7f4" stroke="#00000030" stroke-width="1.2"/><path d="M38 90l12 22 12-22" fill="#e6e6e0"/><path d="M26 98c4-6 10-8 14-8l10 24-4 20H12C10 118 16 104 26 98zM74 98c-4-6-10-8-14-8l-10 24 4 20h28c2-16-4-30-8-36z" fill="#17171c" stroke="#000" stroke-width="1"/><circle cx="42" cy="124" r="1.6" fill="#d4af37"/><circle cx="58" cy="124" r="1.6" fill="#d4af37"/><path d="M42 96l8 6 8-6" stroke="#fff" stroke-width="1" fill="none" opacity=".4"/><path d="M50 94l-9-4v8zM50 94l9-4v8z" fill="#b3122a" stroke="#6e0c1a" stroke-width=".8"/><circle cx="50" cy="94" r="2.6" fill="#8a0e22"/>`;
  else body=`<path d="${BD}" fill="${shirt}" stroke="#00000030" stroke-width="1.2"/><path d="M40 90q10 9 20 0" stroke="#ffffff55" fill="none" stroke-width="2.4"/><path d="M-4 134C-2 108 20 94 38 90 28 104 26 120 28 134z" fill="#00000018"/>`;
  const neck=`<path d="M42 82h16v12q-8 7-16 0z" fill="${sk}"/><path d="M42 82h16v7q-8 4-16 0z" fill="#00000026"/>`;
  const visor=crou?`<path d="M10 38q40-22 80 0l-2 6q-38-18-76 0z" fill="#1f9a52" stroke="#0d5a2c" stroke-width="1.2"/><path d="M12 40q38-16 76 0" stroke="#7fe3a3" stroke-width="1.2" fill="none" opacity=".7"/><path d="M8 42q42-10 84 0-4 7-42 7T8 42z" fill="#27b862" opacity=".92" stroke="#0d5a2c" stroke-width="1"/><path d="M14 44q36-6 72 0" stroke="#fff" stroke-width="1.4" fill="none" opacity=".45"/>`:'';
  let arm='',hand='',smoke='';
  if(item){
    const sl=crou?'#f7f7f4':shirt;
    arm=`<path d="M92 128C96 110 86 96 70 84" stroke="${sl}" stroke-width="15" fill="none" stroke-linecap="round"/><path d="M92 128C96 110 86 96 70 84" stroke="#00000022" stroke-width="15" fill="none" stroke-linecap="round" stroke-dasharray="1 40" opacity=".0"/>`;
    hand=`<g><ellipse cx="66" cy="76" rx="8.5" ry="7" fill="${sk}" stroke="#00000030"/><path d="M60 72h12M60 76h12M61 80h10" stroke="#00000030" stroke-width="1.2" stroke-linecap="round"/></g>`;
    smoke=`<g class="cz-smk" transform="translate(88 58)"><circle r="3" fill="#e9eef5"/><circle r="3" fill="#e9eef5"/><circle r="3" fill="#e9eef5"/></g>`;
    if(item==='vape')smoke=smoke.replace('translate(88 58)','translate(86 61)');
  }
  const mouth=item?`<ellipse cx="53" cy="72" rx="4.6" ry="3.6" fill="#b4574f"/>`:`<path d="M42 72q8 5 16 0" stroke="#a24f48" stroke-width="2.8" fill="none" stroke-linecap="round"/>`;
  const html=`<svg class="cz-char" viewBox="-6 -8 112 142" preserveAspectRatio="xMidYMax meet" aria-hidden="true">${HAIRB(hair,hc)}${body}${neck}<ellipse cx="14" cy="56" rx="5" ry="8" fill="${sk}"/><ellipse cx="86" cy="56" rx="5" ry="8" fill="${sk}"/><ellipse cx="50" cy="54" rx="36" ry="40" fill="${sk}"/><ellipse cx="50" cy="54" rx="36" ry="40" fill="url(#czg-shade)" opacity=".16"/>${HAIRF(hair,hc)}<g class="cz-eyes">${eyesSvg(look.eyes||'ronds',ec)}</g><path d="M28 43q8-5 15-1M57 42q8-4 15 1" stroke="#00000066" stroke-width="2.4" fill="none" stroke-linecap="round"/><path d="M50 54q-3 8 0 11" stroke="#00000033" stroke-width="2.2" fill="none" stroke-linecap="round"/>${mouth}<circle cx="27" cy="66" r="6" fill="#ff8a8a" opacity=".2"/><circle cx="73" cy="66" r="6" fill="#ff8a8a" opacity=".2"/>${visor}${arm}${item?itemSvg(item):''}${hand}${smoke}</svg>`;
  if(charCache.size>300)charCache.clear();
  charCache.set(key,html);return html;
}

/* ---------- symboles de machines à sous & icônes du billet ---------- */
const SY={
 cerise:`<path d="M50 20c-6 20-14 32-22 44M50 20c6 22 12 34 20 44" stroke="#2f7a2a" stroke-width="4" fill="none"/><path d="M50 20c10-10 24-8 30 0-10 2-22 2-30 0z" fill="#3ea23a"/><circle cx="28" cy="70" r="16" fill="url(#czg-red)"/><circle cx="72" cy="70" r="16" fill="url(#czg-red)"/><circle cx="23" cy="64" r="4" fill="#fff" opacity=".7"/><circle cx="67" cy="64" r="4" fill="#fff" opacity=".7"/>`,
 citron:`<path d="M12 56C12 36 32 24 52 26c20 0 36 12 36 28s-18 22-38 22S12 72 12 56z" fill="url(#czg-yellow)" stroke="#a98a05" stroke-width="2"/><path d="M8 56l10-4v8zM92 54l-10-3v8z" fill="#e6c818"/><path d="M30 40c10-6 26-8 38-2" stroke="#fff" stroke-width="4" fill="none" opacity=".6" stroke-linecap="round"/>`,
 orange:`<circle cx="50" cy="56" r="32" fill="url(#czg-orange)"/><path d="M50 24c-2-8 4-14 12-14-1 8-5 12-12 14z" fill="#3ea23a"/><ellipse cx="38" cy="44" rx="9" ry="5" fill="#fff" opacity=".45" transform="rotate(-30 38 44)"/>`,
 cloche:`<path d="M20 74c0-6 6-8 6-26 0-16 10-28 24-28s24 12 24 28c0 18 6 20 6 26z" fill="url(#czg-gold)" stroke="#8d610a" stroke-width="2"/><circle cx="50" cy="16" r="5" fill="url(#czg-gold)" stroke="#8d610a"/><circle cx="50" cy="82" r="8" fill="url(#czg-gold)" stroke="#8d610a"/><path d="M34 34c4-8 10-12 18-12" stroke="#fff" stroke-width="4" stroke-linecap="round" fill="none" opacity=".7"/>`,
 bar:`<rect x="10" y="28" width="80" height="44" rx="6" fill="#16161c" stroke="url(#czg-goldl)" stroke-width="4"/><text x="50" y="62" text-anchor="middle" font-family="Georgia,serif" font-weight="900" font-size="30" fill="url(#czg-goldl)" letter-spacing="2">BAR</text>`,
 sept:`<text x="50" y="82" text-anchor="middle" font-family="Georgia,serif" font-weight="900" font-size="92" fill="url(#czg-red)" stroke="#fff" stroke-width="3" paint-order="stroke">7</text><text x="50" y="82" text-anchor="middle" font-family="Georgia,serif" font-weight="900" font-size="92" fill="none" stroke="#5a0710" stroke-width="1">7</text>`,
 diamant:`<path d="M26 18h48l20 24-44 48L6 42z" fill="url(#czg-blue)" stroke="#0b2f77" stroke-width="2"/><path d="M6 42h88M38 18L30 42l20 48 20-48-8-24M30 42h40" stroke="#cfe9ff" stroke-width="1.6" fill="none" opacity=".8"/><path d="M30 24l10 0-8 14z" fill="#fff" opacity=".7"/>`,
 etoile:`<path d="M50 8l12 28 30 3-23 20 7 30-26-16-26 16 7-30L8 39l30-3z" fill="url(#czg-gold)" stroke="#8d610a" stroke-width="2.4" stroke-linejoin="round"/><path d="M50 20l7 18" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".7"/>`,
 joker:`<path d="M14 80L22 28l18 22 10-34 10 34 18-22 8 52z" fill="url(#czg-purple)" stroke="#2a0a52" stroke-width="2.4" stroke-linejoin="round"/><circle cx="22" cy="26" r="6" fill="url(#czg-gold)"/><circle cx="50" cy="14" r="6" fill="url(#czg-gold)"/><circle cx="78" cy="26" r="6" fill="url(#czg-gold)"/><circle cx="40" cy="58" r="3.4" fill="#fff"/><circle cx="60" cy="58" r="3.4" fill="#fff"/><path d="M38 70q12 10 24 0" stroke="#fff" stroke-width="3" fill="none" stroke-linecap="round"/>`,
 raisin:`<path d="M50 8c0 8 8 10 14 8" stroke="#3a7a2a" stroke-width="4" fill="none"/>${[[34,30],[56,30],[24,48],[46,48],[68,48],[34,66],[56,66],[46,84]].map(p=>`<circle cx="${p[0]}" cy="${p[1]}" r="11" fill="url(#czg-purple)"/><circle cx="${p[0]-3}" cy="${p[1]-4}" r="3" fill="#fff" opacity=".6"/>`).join('')}`,
 pasteque:`<path d="M8 36h84c0 32-18 52-42 52S8 68 8 36z" fill="#2c8a3a"/><path d="M14 38h72c-1 26-16 42-36 42S15 64 14 38z" fill="url(#czg-red)"/>${[[34,52],[50,60],[66,52],[42,44],[58,44]].map(p=>`<ellipse cx="${p[0]}" cy="${p[1]}" rx="2.4" ry="3.6" fill="#111"/>`).join('')}`,
 trefle:`<g fill="url(#czg-green)" stroke="#0d5a22" stroke-width="1.6"><circle cx="38" cy="36" r="18"/><circle cx="62" cy="36" r="18"/><circle cx="38" cy="60" r="18"/><circle cx="62" cy="60" r="18"/></g><path d="M50 56c2 14 8 24 16 30" stroke="#0d5a22" stroke-width="5" fill="none" stroke-linecap="round"/>`,
 couronne:`<path d="M12 74L8 30l22 20 20-34 20 34 22-20-4 44z" fill="url(#czg-gold)" stroke="#8d610a" stroke-width="2.4" stroke-linejoin="round"/><rect x="12" y="74" width="76" height="10" rx="2" fill="url(#czg-gold)" stroke="#8d610a" stroke-width="2"/><circle cx="50" cy="56" r="5" fill="url(#czg-red)"/><circle cx="30" cy="62" r="3.6" fill="url(#czg-blue)"/><circle cx="70" cy="62" r="3.6" fill="url(#czg-green)"/>`,
 fer:`<path d="M26 82V44C26 22 38 12 50 12s24 10 24 32v38h-14V44c0-12-4-18-10-18s-10 6-10 18v38z" fill="url(#czg-silver)" stroke="#505866" stroke-width="2"/>${[34,46,58,70].map(y=>`<circle cx="33" cy="${y}" r="2" fill="#333"/><circle cx="67" cy="${y}" r="2" fill="#333"/>`).join('')}`,
 piece:`<circle cx="50" cy="50" r="38" fill="url(#czg-gold)" stroke="#8d610a" stroke-width="3"/><circle cx="50" cy="50" r="30" fill="none" stroke="#8d610a" stroke-width="2" stroke-dasharray="3 3"/><text x="50" y="63" text-anchor="middle" font-family="Georgia,serif" font-weight="900" font-size="38" fill="#8d610a">$</text><path d="M26 34c8-10 20-14 32-12" stroke="#fff" stroke-width="3.6" fill="none" stroke-linecap="round" opacity=".7"/>`,
 coeur:`<path d="M50 88C16 60 8 40 8 28a20 20 0 0 1 42-6 20 20 0 0 1 42 6c0 12-8 32-42 60z" fill="url(#czg-red)" stroke="#5a0710" stroke-width="2"/>`,
 lune:`<path d="M62 8A42 42 0 1 0 90 62 34 34 0 0 1 62 8z" fill="url(#czg-yellow)" stroke="#a98a05" stroke-width="2"/>`,
 fusee:`<path d="M50 6c14 14 18 36 14 58H36C32 42 36 20 50 6z" fill="url(#czg-silver)" stroke="#505866" stroke-width="2"/><circle cx="50" cy="34" r="7" fill="url(#czg-blue)"/><path d="M36 50L22 72l16-6zM64 50l14 22-16-6z" fill="url(#czg-red)"/><path d="M42 66h16l-8 24z" fill="url(#czg-orange)"/>`,
 coffre:`<rect x="12" y="38" width="76" height="46" rx="6" fill="#7a4a1a" stroke="#3a220a" stroke-width="2.4"/><path d="M12 56C12 30 88 30 88 56z" fill="#92591f" stroke="#3a220a" stroke-width="2.4"/><rect x="12" y="52" width="76" height="8" fill="url(#czg-goldl)"/><rect x="44" y="50" width="12" height="16" rx="2" fill="url(#czg-gold)" stroke="#8d610a"/>`
};
const SYMALIAS=[[/cerise|cherry/,'cerise'],[/citron|lemon/,'citron'],[/orange/,'orange'],[/cloche|bell/,'cloche'],[/\bbar\b|^bar/,'bar'],[/sept|seven|^7$/,'sept'],[/diamant|diamond|gemme/,'diamant'],[/etoile|star/,'etoile'],[/joker|wild|sauvage/,'joker'],[/raisin|grape/,'raisin'],[/pasteque|melon|watermelon/,'pasteque'],[/trefle|clover/,'trefle'],[/couronne|crown/,'couronne'],[/fer|horse/,'fer'],[/piece|coin|pepite|or$/,'piece'],[/coeur|heart/,'coeur'],[/lune|moon/,'lune'],[/fusee|rocket|cosmos/,'fusee'],[/coffre|tresor|chest/,'coffre']];
function symKey(code){
  const c=String(code==null?'':code).normalize('NFD').replace(/[̀-ͯ]/g,'').toLowerCase();
  if(SY[c])return c;for(const [re,k] of SYMALIAS)if(re.test(c))return k;return null;
}
function symSvg(code,cls){
  const k=symKey(code);
  const inner=k?SY[k]:`<circle cx="50" cy="50" r="38" fill="url(#czg-silver)" stroke="#505866" stroke-width="3"/><text x="50" y="62" text-anchor="middle" font-family="Georgia,serif" font-weight="900" font-size="34" fill="#2a2f3a">${E(String(code||'?').slice(0,2).toUpperCase())}</text>`;
  return `<svg class="cz-sym ${cls||''}" viewBox="0 0 100 100" aria-hidden="true">${inner}</svg>`;
}

/* ---------- icônes d'interface (SVG maison, sans emoji) ---------- */
const IC={
 close:'<path d="M5 5l14 14M19 5L5 19"/>',back:'<path d="M15 5l-7 7 7 7"/>',mute:'<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M17 9l5 6M22 9l-5 6"/>',sound:'<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M16.500 8.500a5 5 0 0 1 0 7M19 6a8.500 8.500 0 0 1 0 12"/>',
 coin:'<circle cx="12" cy="12" r="9"/><path d="M12 6v12M15 9c0-1-1.300-1.800-3-1.800S9 8 9 9c0 2.800 6 1.200 6 4 0 1-1.300 1.800-3 1.800s-3-.8-3-1.800"/>',
 ticket:'<path d="M3 8a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-2a2 2 0 0 0 0-4z"/><path d="M14 6v12" stroke-dasharray="2 2"/>',
 eye:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
 user:'<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',bot:'<rect x="5" y="8" width="14" height="11" rx="3"/><path d="M12 8V4M9 13h.01M15 13h.01M9 17h6"/>',
 leave:'<path d="M9 4H5v16h4M16 8l4 4-4 4M20 12H9"/>',check:'<path d="M5 12l5 5 9-10"/>',warn:'<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18h.01"/>',
 info:'<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',log:'<path d="M4 6h16M4 12h16M4 18h10"/>',trash:'<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
 scan:'<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M4 12h16"/>',
 bank:'<path d="M3 10l9-6 9 6M5 10v8M9 10v8M15 10v8M19 10v8M3 20h18"/>',plus:'<path d="M12 5v14M5 12h14"/>',
 star:'<path d="M12 3l2.700 5.800 6.300.7-4.700 4.300 1.300 6.200L12 17l-5.600 3 1.300-6.200L3 9.500l6.300-.7z"/>'
};
const ico=(n,s)=>`<svg class="cz-ic" viewBox="0 0 24 24" width="${s||18}" height="${s||18}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${IC[n]||''}</svg>`;

/* ---------- son : tout est synthétisé avec WebAudio ---------- */
const AU=(function(){
  let down=false,ctx=null,master=null,muted=lsGet('cz_mute')==='1',ambT=null,ambOn=false,ambGain=null,nbuf=null;
  const live=new Set();
  function ensure(){
    if(!ctx){const C=window.AudioContext||window.webkitAudioContext;if(!C)return null;try{ctx=new C()}catch(e){return null}
      master=ctx.createGain();master.gain.value=muted?0:.55;const comp=ctx.createDynamicsCompressor();master.connect(comp);comp.connect(ctx.destination);
      nbuf=ctx.createBuffer(1,ctx.sampleRate,ctx.sampleRate);const d=nbuf.getChannelData(0);for(let i=0;i<d.length;i++)d[i]=Math.random()*2-1}
    if(ctx.state==='suspended')ctx.resume().catch(()=>{});return ctx;
  }
  const ok=()=>!muted&&!down&&ensure();
  function tone(f,dur,o){o=o||{};const c=ctx,t=c.currentTime+(o.at||0);const os=c.createOscillator(),g=c.createGain();os.type=o.type||'sine';os.frequency.setValueAtTime(f,t);if(o.to)os.frequency.exponentialRampToValueAtTime(Math.max(20,o.to),t+dur);
    const v=(o.v==null?.3:o.v),a=o.a||.005;g.gain.setValueAtTime(0.0001,t);g.gain.exponentialRampToValueAtTime(v,t+a);g.gain.exponentialRampToValueAtTime(0.0001,t+dur);
    os.connect(g);g.connect(o.dest||master);os.start(t);os.stop(t+dur+.05);return os}
  function noise(dur,o){o=o||{};const c=ctx,t=c.currentTime+(o.at||0);const s=c.createBufferSource();s.buffer=nbuf;s.loop=true;const f=c.createBiquadFilter();f.type=o.ft||'bandpass';f.frequency.setValueAtTime(o.f||2000,t);if(o.fto)f.frequency.exponentialRampToValueAtTime(o.fto,t+dur);f.Q.value=o.q||1;
    const g=c.createGain();g.gain.setValueAtTime(0.0001,t);g.gain.exponentialRampToValueAtTime(o.v||.2,t+(o.a||.003));g.gain.exponentialRampToValueAtTime(0.0001,t+dur);s.connect(f);f.connect(g);g.connect(o.dest||master);s.start(t,Math.random()*.5);s.stop(t+dur+.05);return s}
  const S={
    unlock(){down=false;ensure()},
    chip(){if(!ok())return;noise(.05,{f:5200,q:5,v:.25});tone(2400+Math.random()*500,.07,{type:'triangle',v:.12});tone(3300,.05,{v:.07,at:.02})},
    chips(n){n=Math.min(n||4,9);for(let i=0;i<n;i++)setTimeout(S.chip,i*55+Math.random()*30)},
    card(){if(!ok())return;noise(.09,{f:1400,fto:5200,q:.8,v:.22,ft:'bandpass'})},
    flip(){if(!ok())return;noise(.07,{f:3000,fto:900,q:.7,v:.18});tone(190,.06,{type:'triangle',v:.1})},
    click(){if(!ok())return;tone(900,.04,{type:'square',v:.06})},
    tick(){if(!ok())return;tone(1400,.03,{type:'square',v:.05})},
    warn(){if(!ok())return;tone(520,.12,{type:'square',v:.08});tone(520,.12,{type:'square',v:.08,at:.18})},
    err(){if(!ok())return;tone(220,.18,{type:'sawtooth',v:.09,to:150})},
    pop(){if(!ok())return;tone(500,.08,{type:'sine',v:.16,to:900})},
    win(big){if(!ok())return;const n=[784,988,1175,1568];n.forEach((f,i)=>{tone(f,.35,{type:'triangle',v:.18,at:i*.075});tone(f*2,.25,{v:.05,at:i*.075})});S.chips(big?9:5)},
    lose(){if(!ok())return;tone(330,.35,{type:'triangle',v:.14,to:200});tone(247,.45,{type:'triangle',v:.12,at:.18,to:150})},
    jackpot(){if(!ok())return;const m=[523,659,784,1047,784,1047,1319,1568];m.forEach((f,i)=>{tone(f,.28,{type:'square',v:.1,at:i*.11});tone(f/2,.3,{type:'triangle',v:.12,at:i*.11})});for(let i=0;i<24;i++)setTimeout(S.chip,300+i*70);tone(1568,1.2,{type:'triangle',v:.16,at:.95});tone(2093,1.2,{v:.08,at:.95})},
    coin(){if(!ok())return;tone(1976,.09,{type:'square',v:.07});tone(2637,.35,{type:'square',v:.07,at:.07})},
    lever(){if(!ok())return;tone(120,.2,{type:'sawtooth',v:.12,to:60});noise(.15,{f:400,q:1,v:.18});setTimeout(()=>{if(ok())tone(70,.1,{type:'square',v:.15})},180)},
    reelStart(d){if(!ok())return;const n=Math.floor(d/70);for(let i=0;i<n;i++)setTimeout(()=>{if(ok())tone(300+(i%3)*90,.035,{type:'square',v:.035})},i*70)},
    reelStop(){if(!ok())return;tone(160,.08,{type:'square',v:.16,to:90});noise(.06,{f:900,q:2,v:.14})},
    spin(){if(!ok())return;noise(1.2,{f:300,fto:1200,q:.8,v:.1,a:.4});tone(110,1.2,{type:'sawtooth',v:.03,to:180})},
    ball(durMs){if(!ok())return;let t=0,gap=45;const run=()=>{if(t>durMs||muted||down)return;if(ctx){tone(2200+Math.random()*1200,.03,{type:'triangle',v:.1});noise(.02,{f:6000,v:.07})}const p=t/durMs;gap=40+Math.pow(p,2.4)*330;t+=gap;setTimeout(run,gap)};run()},
    ballDrop(){if(!ok())return;for(let i=0;i<5;i++){setTimeout(()=>{if(ok()){tone(1500-i*180,.05,{type:'triangle',v:.16});noise(.03,{f:5000,v:.1})}},i*(90+i*40))}},
    scratch(v){if(!ok())return;noise(.07,{f:2500+Math.random()*2000,q:.6,v:.05+Math.min(.12,(v||.5)*.12),ft:'highpass'})},
    printer(sec){if(!ok())return;const n=Math.floor(sec*16);for(let i=0;i<n;i++)setTimeout(()=>{if(ok()){noise(.03,{f:1800,q:2,v:.1});tone(1200+((i*37)%5)*120,.025,{type:'square',v:.03})}},i*62)},
    bag(){if(!ok())return;noise(.4,{f:2400,fto:600,q:.5,v:.14});noise(.3,{f:3500,fto:1500,q:.5,v:.1,at:.25})},
    fold(){if(!ok())return;noise(.12,{f:1800,fto:600,q:.7,v:.14})},
    beep(){if(!ok())return;tone(1568,.09,{type:'square',v:.07});tone(2093,.12,{type:'square',v:.07,at:.1})},
    sirenStart(){if(!ok())return null;const c=ctx,o=c.createOscillator(),g=c.createGain(),l=c.createOscillator(),lg=c.createGain();o.type='sawtooth';o.frequency.value=900;l.frequency.value=2.2;lg.gain.value=320;l.connect(lg);lg.connect(o.frequency);g.gain.value=.07;o.connect(g);g.connect(master);o.start();l.start();const h={stop(){try{g.gain.setTargetAtTime(0,c.currentTime,.05);o.stop(c.currentTime+.3);l.stop(c.currentTime+.3)}catch(e){}live.delete(h)}};live.add(h);return h},
    ambient(on){
      if(!on){ambOn=false;clearTimeout(ambT);if(ambGain){try{ambGain.gain.setTargetAtTime(0,ctx.currentTime,.3)}catch(e){}ambGain=null}return}
      if(ambOn)return;ambOn=true;
      const chords=[[220,277.2,329.6,415.3],[196,246.9,293.7,370],[174.6,220,261.6,329.6],[196,246.9,293.7,392]];let k=0,step=0;
      const loop=()=>{if(!ambOn)return;if(!muted&&ensure()){if(!ambGain){ambGain=ctx.createGain();ambGain.gain.value=.0001;ambGain.gain.setTargetAtTime(.5,ctx.currentTime,1);ambGain.connect(master)}
          const ch=chords[k%4],t=ctx.currentTime;
          ch.forEach((f,i)=>tone(f/2,3.4,{type:'sine',v:.022,a:.8,at:i*.04,dest:ambGain}));
          for(let i=0;i<3;i++){const f=ch[Math.floor(Math.random()*4)]*(Math.random()<.5?2:1);tone(f,1.4,{type:'triangle',v:.03,a:.02,at:.5+i*.95+Math.random()*.2,dest:ambGain})}
          step++;if(step%2===0)k++}
        ambT=setTimeout(loop,3300)};
      loop()},
    mute(b){muted=!!b;lsSet('cz_mute',muted?'1':'0');if(master)master.gain.setTargetAtTime(muted?0:.55,ctx.currentTime,.05);if(muted)live.forEach(h=>h.stop())},
    isMuted:()=>muted,
    shutdown(){down=true;S.ambient(false);live.forEach(h=>h.stop());live.clear()}
  };
  return S;
})();

/* ---------- coque : couche plein écran, routeur de vues, effets, dialogues ---------- */
const Z={root:null,main:null,fx:null,sc:null,view:null,lobby:null,bal:null,med:0,open:false,busyGo:false};
const V={};
const fmtMs=ms=>{ms=Math.max(0,Math.ceil(ms/1000));const m=Math.floor(ms/60),s=ms%60;return m+':'+String(s).padStart(2,'0')};
const fmtLong=ms=>{ms=Math.max(0,Math.floor(ms/1000));const d=Math.floor(ms/86400),h=Math.floor(ms%86400/3600),m=Math.floor(ms%3600/60),s=ms%60,p=x=>String(x).padStart(2,'0');return (d?d+' j ':'')+p(h)+':'+p(m)+':'+p(s)};
const symbolCoin=`<svg class="cz-ic" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5.500" stroke-dasharray="2 2"/></svg>`;

function syncApp(b,m){/* les jetons de casino sont séparés du solde du compte : rien à synchroniser */}
function setBal(b,m){
  if(b==null||!isFinite(+b))return;b=+b;
  const old=Z.bal;Z.bal=b;if(m!=null&&isFinite(+m))Z.med=+m;
  if(Z.root){const e=$('.cz-balnum',Z.root);if(e){e.textContent=nfl(b);e.title=nfl(b)+' jetons';
      if(old!=null&&Math.abs(b-old)>=.05){const d=D.createElement('span');d.className='cz-delta '+(b>old?'up':'dn');d.textContent=(b>old?'+':'')+nf(b-old);$('.cz-bal',Z.root).appendChild(d);d.addEventListener('animationend',()=>d.remove());
        const bx=$('.cz-bal',Z.root);bx.classList.remove('bump');void bx.offsetWidth;bx.classList.add('bump')}}
    const md=$('.cz-medal',Z.root);if(md){md.hidden=!(Z.med>0);md.querySelector('b').textContent=nf(Z.med)}}
  syncApp(b,Z.med);
}
async function refreshBal(){
  try{const r=await RPC('casino_chips_me');setBal(r.chips,TK&&TK.med!=null?TK.med:null);Z.tok=r.tokens}catch(e){}
}
/* échange entre le compte (jetons du compte) et le casino (jetons de casino), 1 pour 1 */
async function xchg(){
  let r;try{r=await RPC('casino_chips_me')}catch(e){return say(EM(e))}
  const d=dlg(`<h3>Échanger des jetons</h3><p>Compte : <b>${nfl(r.tokens)}</b> jetons du compte<br>Casino : <b>${nfl(r.chips)}</b> jetons de casino<br><span class="cz-muted">Taux : 1 pour 1. Il faut d’abord convertir vos jetons du compte pour jouer ; vous pouvez ensuite les reconvertir.</span></p>
    <div class="cz-buy"><select id="czXd"><option value="in">Du compte vers le casino</option><option value="out">Du casino vers le compte</option></select> <input id="czXn" type="number" min="1" step="1" value="${Math.max(1,Math.min(1000,Math.floor(r.tokens)))}"></div>
    <div class="cz-dlg-btn"><button class="cz-btn ghost" data-x type="button">Fermer</button><button class="cz-btn gold" data-ok type="button">Échanger</button></div>`);
  if(!d)return;
  d.querySelector('[data-ok]').onclick=()=>act('xchg',async()=>{const n=Math.floor(+d.querySelector('#czXn').value);const x=await RPC('casino_exchange',{p_dir:d.querySelector('#czXd').value,p_amount:n});setBal(x.chips);Z.tok=x.tokens;try{if(typeof balRefresh==='function')balRefresh()}catch(e){}AU.chips&&AU.chips(3);say('Échange effectué');d.close()});
}
const getLobby=async()=>{const l=await RPC('casino_lobby');if(l){Z.lobby=l;setBal(l.balance,l.medals)}return l};

/* ---------- effets visuels ---------- */
const FX={
  layer(){return Z.fx},
  add(el,ms){const L=Z.fx;if(!L)return;if(L.childElementCount>160)L.firstChild.remove();L.appendChild(el);el.addEventListener('animationend',()=>el.remove(),{once:true})},
  coinRain(n,amp){n=Math.min(n||40,90);for(let i=0;i<n;i++){const c=D.createElement('i');c.className='cz-fxcoin';c.style.cssText=`left:${rnd(0,100)}%;--s:${rnd(16,34)|0}px;--d:${rnd(1.6,3.2).toFixed(2)}s;--dl:${rnd(0,1.4).toFixed(2)}s;--r:${rnd(-540,540)|0}deg;--dx:${rnd(-60,60)|0}px`;FX.add(c)}},
  flash(col){const f=D.createElement('div');f.className='cz-flash';f.style.setProperty('--fc',col||'#fff');FX.add(f)},
  burst(from,n,col){if(!Z.fx||!from)return;const r=from.getBoundingClientRect(),R=Z.fx.getBoundingClientRect();n=n||14;for(let i=0;i<n;i++){const c=D.createElement('i');c.className='cz-spark';const a=Math.random()*6.283,d=rnd(40,140);c.style.cssText=`left:${r.left+r.width/2-R.left}px;top:${r.top+r.height/2-R.top}px;--dx:${Math.cos(a)*d|0}px;--dy:${Math.sin(a)*d-40|0}px;--c:${col||'#ffd24a'}`;FX.add(c)}},
  float(el,text,cls){if(!Z.fx||!el)return;const r=el.getBoundingClientRect(),R=Z.fx.getBoundingClientRect();const t=D.createElement('div');t.className='cz-float '+(cls||'');t.textContent=text;t.style.left=(r.left+r.width/2-R.left)+'px';t.style.top=(r.top-R.top)+'px';FX.add(t)},
  confetti(n){n=Math.min(n||50,90);const cols=['#ff4fd8','#4fd2ff','#7dff8a','#ffe14f','#ff6a3d','#fff'];for(let i=0;i<n;i++){const c=D.createElement('i');c.className='cz-conf';c.style.cssText=`left:${rnd(0,100)}%;--c:${pick(cols)};--d:${rnd(2,4).toFixed(2)}s;--dl:${rnd(0,.9).toFixed(2)}s;--dx:${rnd(-120,120)|0}px;--r:${rnd(-720,720)|0}deg`;FX.add(c)}}
};

/* ---------- dialogues dans la couche casino ---------- */
function dlg(html,o){
  o=o||{};if(!Z.root)return null;
  const b=D.createElement('div');b.className='cz-dlg-back';b.innerHTML=`<div class="cz-dlg ${o.cls||''}" role="dialog">${html}</div>`;
  b.close=()=>{if(b._c)return;b._c=1;b.classList.add('out');setTimeout(()=>b.remove(),180)};
  b.addEventListener('mousedown',e=>{if(e.target===b&&!o.lock)b.close()});
  b.addEventListener('click',e=>{if(e.target.closest('[data-x]'))b.close()});
  Z.root.appendChild(b);return b;
}
function ask(title,msg,okLabel,o){
  o=o||{};
  return new Promise(res=>{
    const d=dlg(`<h3>${E(title)}</h3><p>${msg}</p><div class="cz-dlg-btn"><button class="cz-btn ghost" data-x data-n>Annuler</button><button class="cz-btn ${o.danger?'red':'gold'}" data-ok>${E(okLabel||'Confirmer')}</button></div>`,{lock:o.lock});
    if(!d)return res(false);let done=false;const fin=v=>{if(done)return;done=true;res(v)};
    d.querySelector('[data-ok]').addEventListener('click',()=>{fin(true);d.close()});
    const mo=new MutationObserver(()=>{if(!d.isConnected){fin(false);mo.disconnect()}});mo.observe(Z.root,{childList:true});
    d.addEventListener('click',e=>{if(e.target.closest('[data-x]'))fin(false)});
  });
}

/* ---------- routeur ---------- */
function setTitle(t){const e=$('.cz-title',Z.root);if(e)e.textContent=t||''}
async function leaveView(){
  const v=Z.view;Z.view=null;if(!v)return;
  v.sc.dispose();
  if(v.leave){try{const p=v.leave();if(p&&p.catch)p.catch(()=>{})}catch(e){}}
}
function go(name,arg){
  if(!Z.root||!V[name])return;
  leaveView();
  const el=D.createElement('div');el.className='cz-view cz-v-'+name;
  Z.main.textContent='';Z.main.appendChild(el);
  const sc=scope();const ctx={el,sc,arg,name,leave:null,back:'hall',title:''};Z.view=ctx;
  const bk=$('.cz-back',Z.root);bk.hidden=(name==='hall');
  setTitle('');el.scrollTop=0;
  try{V[name](ctx)}catch(e){console.error(e);say('Erreur d’affichage')}
  if(ctx.title)setTitle(ctx.title);
}
const back=()=>{const v=Z.view;if(v)go(v.back||'hall')};

const LOGO=`<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.500"/><circle cx="12" cy="12" r="5"/><path d="M12 2.500v4M12 17.500v4M2.500 12h4M17.500 12h4"/></svg>`;
function openCasino(arg){
  if(Z.open){if(arg&&arg.go)go(arg.go,arg.arg);return}
  if(typeof S==='undefined'||!S||!S.me){say('Connectez-vous pour accéder au casino');return}
  Z.open=true;D.body.classList.add('cz-lock');
  const r=D.createElement('div');r.className='cz-root';r.id='czRoot';
  r.innerHTML=`<div class="cz-top"><button class="cz-ib cz-back" type="button" hidden title="Retour au hall">${ico('back',20)}</button><div class="cz-brand">${LOGO}<span>Casino</span></div><div class="cz-title"></div><span class="cz-sp"></span>
   <div class="cz-medal" hidden title="Médaillons">${ico('star',16)}<b>0</b></div>
   <button class="cz-ib cz-xchg" type="button" title="Échanger des jetons">${ico('coin',18)||'Échange'}</button>
   <div class="cz-bal" title="Vos jetons de casino">${symbolCoin}<span class="cz-balnum">${Z.bal==null?'…':nfl(Z.bal)}</span></div>
   <button class="cz-ib cz-mutebtn" type="button" title="Son">${ico(AU.isMuted()?'mute':'sound',20)}</button>
   <button class="cz-ib cz-closebtn" type="button" title="Fermer">${ico('close',20)}</button></div>
   <div class="cz-main"></div><div class="cz-fxl"></div>${SPRITE}`;
  D.body.appendChild(r);Z.root=r;Z.main=$('.cz-main',r);Z.fx=$('.cz-fxl',r);Z.sc=scope();
  $('.cz-xchg',r).onclick=()=>{AU.click();xchg()};
  $('.cz-back',r).onclick=()=>{AU.click();back()};
  $('.cz-closebtn',r).onclick=closeCasino;
  $('.cz-mutebtn',r).onclick=()=>{AU.mute(!AU.isMuted());AU.unlock();$('.cz-mutebtn',r).innerHTML=ico(AU.isMuted()?'mute':'sound',20);if(!AU.isMuted()){AU.ambient(true);AU.pop()}};
  Z.sc.on(D,'keydown',e=>{if(e.key!=='Escape')return;const d=$$('.cz-dlg-back',r).pop();if(d){d.close()}else if(Z.view&&Z.view.name!=='hall')back();else closeCasino()});
  const un=()=>{AU.unlock()};Z.sc.on(r,'pointerdown',un,{capture:true});
  AU.unlock();if(!AU.isMuted())AU.ambient(true);
  go(arg&&arg.go?arg.go:'hall',arg&&arg.arg);
  refreshBal();
}
function closeCasino(){
  if(!Z.open)return;Z.open=false;
  leaveView();if(Z.sc)Z.sc.dispose();AU.shutdown();
  if(Z.root)Z.root.remove();Z.root=Z.main=Z.fx=null;D.body.classList.remove('cz-lock');
  refreshBal();
}

/* ---------- entrée : petite icône à côté de la pastille de solde / médaillons (en haut, dans #meBox) ---------- */
const CZ_ICON=`<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><circle cx="12" cy="12" r="5"/><path d="M12 2.5v4M12 17.5v4M2.5 12h4M17.5 12h4"/></svg>`;
function injectEntry(){
  const c=$('#meBox .balchip');if(!c||typeof S==='undefined'||!S||!S.me)return;
  let anchor=c;const n=c.nextElementSibling;if(n&&n.classList.contains('medchip'))anchor=n;
  let b=$('#meBox .cz-entry');
  if(b){if(b.previousElementSibling===anchor)return;b.remove()}
  b=D.createElement('button');b.type='button';b.className='cz-entry';b.title='Casino';b.setAttribute('aria-label','Casino');b.innerHTML=CZ_ICON;
  anchor.insertAdjacentElement('afterend',b);
}
let injQ=0;const injSoon=()=>{if(injQ)return;injQ=requestAnimationFrame(()=>{injQ=0;try{injectEntry()}catch(e){}})};
D.addEventListener('click',e=>{const b=e.target.closest&&e.target.closest('.cz-entry');if(b){e.preventDefault();e.stopPropagation();e.stopImmediatePropagation();openCasino()}},true);
try{new MutationObserver(injSoon).observe(D.body||D.documentElement,{childList:true,subtree:true})}catch(e){}
if(D.readyState==='loading')D.addEventListener('DOMContentLoaded',injSoon);else injSoon();

/* ---------- illustrations partagées ---------- */
function wheelSvg(o){
  o=o||{};const N=37,A=360/N,nums=!!o.nums;let w='';
  const pt=(r,a)=>{const t=(a-90)*Math.PI/180;return [(r*Math.cos(t)).toFixed(2),(r*Math.sin(t)).toFixed(2)]};
  WHEEL.forEach((n,i)=>{const a0=(i-.5)*A,a1=(i+.5)*A,p1=pt(92,a0),p2=pt(92,a1),p3=pt(60,a1),p4=pt(60,a0);const c={g:'#0e7a3b',r:'#c4122f',b:'#14141a'}[numCol(n)];
    w+=`<path d="M${p1}A92 92 0 0 1 ${p2}L${p3}A60 60 0 0 0 ${p4}z" fill="${c}" stroke="#d4af37" stroke-width=".7"/>`;
    if(nums){const tp=pt(76,i*A);w+=`<text x="${tp[0]}" y="${tp[1]}" transform="rotate(${i*A} ${tp[0]} ${tp[1]})" text-anchor="middle" dominant-baseline="central" font-family="Georgia,serif" font-weight="700" font-size="9" fill="#fff">${n}</text>`}});
  return `<svg class="cz-wheel" viewBox="-100 -100 200 200"><defs><radialGradient id="cwood" cx=".5" cy=".5" r=".5"><stop offset=".86" stop-color="#5a3414"/><stop offset=".93" stop-color="#8a5a24"/><stop offset="1" stop-color="#3a200a"/></radialGradient><radialGradient id="chub" cx=".4" cy=".35" r=".8"><stop offset="0" stop-color="#fff6c0"/><stop offset=".5" stop-color="#d4a72c"/><stop offset="1" stop-color="#6e4c05"/></radialGradient></defs><circle r="99" fill="url(#cwood)"/><circle r="94" fill="#1a0f06" stroke="#d4af37" stroke-width="1.2"/><g class="cz-wh-rot">${w}<circle r="60" fill="#0b2a18" stroke="#d4af37" stroke-width="1"/><circle r="50" fill="#1b1209" stroke="#d4af37" stroke-width=".8"/><g stroke="#d4af37" stroke-width="2" opacity=".8"><path d="M0-50V50M-50 0H50"/></g><circle r="14" fill="url(#chub)" stroke="#6e4c05"/><circle r="4" fill="#fff6c0"/></g></svg>`;
}
const PH={waiting:'En attente',preflop:'Pré-flop',flop:'Flop',turn:'Turn',river:'River',showdown:'Abattage',between:'Entre deux mains',betting:'Mises ouvertes',dealing:'Distribution',playing:'En cours',dealer:'Croupier',payout:'Paiements',spinning:'La roue tourne',result:'Résultat'};
const phName=p=>PH[p]||(p?String(p):'');
const GN={poker:'Poker Texas Hold’em',blackjack:'21 (Blackjack)',roulette:'Roulette européenne'};

const ILL={
 poker:`<svg viewBox="0 0 220 130"><defs><radialGradient id="hp1" cx=".5" cy=".4" r=".7"><stop offset="0" stop-color="#18a05a"/><stop offset="1" stop-color="#074a26"/></radialGradient></defs><ellipse cx="110" cy="70" rx="104" ry="54" fill="#2b170b" stroke="#6b3d1b" stroke-width="3"/><ellipse cx="110" cy="70" rx="92" ry="44" fill="url(#hp1)" stroke="#d4af37" stroke-width="1.2" stroke-opacity=".6"/><g transform="translate(78 52)">${[0,1,2,3,4].map(i=>`<rect x="${i*13}" y="0" width="11" height="16" rx="1.6" fill="#fff" stroke="#0004"/>`).join('')}<rect x="39" y="0" width="11" height="16" rx="1.6" fill="#fff"/><text x="44.500" y="12" font-size="9" fill="#c4122f" text-anchor="middle" font-family="Georgia" font-weight="700">A</text></g><g>${[[40,82],[180,82],[60,106],[160,106],[110,112],[60,32],[160,32],[110,24]].map(p=>`<circle cx="${p[0]}" cy="${p[1]}" r="9" fill="#e8c9a3" stroke="#0005"/><path d="M${p[0]-9} ${p[1]+14}q9-12 18 0z" fill="#7a3b4a"/>`).join('')}</g><g transform="translate(95 82)"><ellipse cx="14" cy="8" rx="10" ry="4" fill="#d33a3a"/><ellipse cx="14" cy="5" rx="10" ry="4" fill="#e84a4a"/><ellipse cx="30" cy="9" rx="10" ry="4" fill="#1d1d22"/><ellipse cx="30" cy="6" rx="10" ry="4" fill="#2d2d36"/></g></svg>`,
 blackjack:`<svg viewBox="0 0 220 130"><defs><radialGradient id="hb1" cx=".5" cy=".2" r=".9"><stop offset="0" stop-color="#16984f"/><stop offset="1" stop-color="#06411f"/></radialGradient></defs><path d="M6 20h208v10c0 60-48 96-104 96S6 90 6 30z" fill="#2b170b" stroke="#6b3d1b" stroke-width="3"/><path d="M14 26h192v6c0 52-44 86-96 86S14 84 14 32z" fill="url(#hb1)" stroke="#d4af37" stroke-opacity=".6"/><text x="110" y="72" text-anchor="middle" font-family="Georgia,serif" font-style="italic" font-weight="900" font-size="30" fill="#d4af37" opacity=".85">21</text><g transform="translate(88 28)"><rect width="18" height="25" rx="2.5" fill="#fff" stroke="#0004"/><text x="9" y="17" text-anchor="middle" font-size="13" font-family="Georgia" font-weight="800" fill="#111">A</text><rect x="22" width="18" height="25" rx="2.500" fill="#fff" stroke="#0004"/><text x="31" y="17" text-anchor="middle" font-size="13" font-family="Georgia" font-weight="800" fill="#c4122f">K</text></g>${[34,62,90,118,146,174].map((x,i)=>`<circle cx="${x+4}" cy="${96+Math.abs(2.5-i)*-4+8}" r="7" fill="#e8c9a3" stroke="#0005"/>`).join('')}</svg>`,
 roulette:`<div class="cz-ill-wheel">${wheelSvg()}</div>`,
 slots:`<svg viewBox="0 0 110 150"><defs><linearGradient id="hs1" x1="0" x2="1"><stop offset="0" stop-color="#6d7480"/><stop offset=".3" stop-color="#f4f6f9"/><stop offset=".6" stop-color="#9aa2ae"/><stop offset="1" stop-color="#4d5460"/></linearGradient></defs><rect x="10" y="10" width="90" height="132" rx="12" fill="url(#hs1)" stroke="#333" stroke-width="2"/><rect x="16" y="16" width="78" height="22" rx="6" fill="#7d0a14"/><text x="55" y="32" text-anchor="middle" font-size="13" font-weight="900" fill="#ffd24a" font-family="Georgia">JACKPOT</text><rect x="18" y="44" width="74" height="46" rx="5" fill="#111"/><g fill="#fff"><rect x="21" y="47" width="22" height="40" rx="3"/><rect x="45" y="47" width="22" height="40" rx="3"/><rect x="69" y="47" width="22" height="40" rx="3"/></g><text x="32" y="75" font-size="22" text-anchor="middle" fill="#c4122f" font-weight="900" font-family="Georgia">7</text><text x="56" y="75" font-size="22" text-anchor="middle" fill="#c4122f" font-weight="900" font-family="Georgia">7</text><text x="80" y="75" font-size="22" text-anchor="middle" fill="#c4122f" font-weight="900" font-family="Georgia">7</text><rect x="22" y="98" width="66" height="30" rx="6" fill="#16161c"/><circle cx="55" cy="113" r="8" fill="#d4a72c"/><path d="M104 60v-34" stroke="#999" stroke-width="4"/><circle cx="104" cy="24" r="7" fill="#d02235" stroke="#600"/></svg>`
};

/* ---------- le cochon Tanhgokrom ---------- */
let pigUid=0;
function pigSvg(fill,cls){
  const lvl=clamp(fill,0,1),id='pg'+(++pigUid);
  /* tas de pièces vu à travers le hublot : lignes décalées, positions pseudo-aléatoires fixes */
  const rnd2=mulberry(77);let coins='';
  for(let r=0;r<11;r++){const y=160-r*6.4,n=r%2?6:7;for(let i=0;i<n;i++){const x=(r%2?100:94)+i*10.8+(rnd2()-.5)*3,yy=y+(rnd2()-.5)*2.4,rot=(rnd2()-.5)*26;
    coins+=`<g transform="translate(${x.toFixed(1)} ${yy.toFixed(1)}) rotate(${rot.toFixed(0)})"><ellipse rx="8.6" ry="4.8" fill="#7a520a"/><ellipse ry="4.4" rx="8.4" cy="-.9" fill="url(#${id}c)" stroke="#9a6a0b" stroke-width=".5"/><ellipse ry="2.4" rx="5.2" cy="-.9" fill="none" stroke="#b9871a" stroke-width=".5"/><path d="M-4.5 -2.2q3-1.8 7-.6" stroke="#fffbe0" stroke-width=".9" fill="none" stroke-linecap="round" opacity=".85"/></g>`}}
  const off=((1-lvl)*72).toFixed(1);
  return `<svg class="cz-pig ${cls||''}" viewBox="0 0 270 230" aria-label="Cochon Tanhgokrom">
<defs>
<radialGradient id="${id}b" cx=".32" cy=".26" r=".95"><stop offset="0" stop-color="#ffe3ec"/><stop offset=".28" stop-color="#ffb3cc"/><stop offset=".68" stop-color="#ee7ba4"/><stop offset="1" stop-color="#b9457a"/></radialGradient>
<radialGradient id="${id}s" cx=".4" cy=".35" r=".8"><stop offset="0" stop-color="#ffc4d8"/><stop offset=".7" stop-color="#f08fb0"/><stop offset="1" stop-color="#c8567f"/></radialGradient>
<radialGradient id="${id}c" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#fff6b8"/><stop offset=".5" stop-color="#f5c542"/><stop offset="1" stop-color="#b57d0d"/></radialGradient>
<linearGradient id="${id}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff3b0"/><stop offset=".45" stop-color="#e5b02c"/><stop offset="1" stop-color="#8d610a"/></linearGradient>
<radialGradient id="${id}w" cx=".5" cy=".4" r=".7"><stop offset="0" stop-color="#4a1a2e"/><stop offset="1" stop-color="#1a0610"/></radialGradient>
<linearGradient id="${id}r" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#c9a15a"/><stop offset="1" stop-color="#7a5a22"/></linearGradient>
<clipPath id="${id}p"><circle cx="132" cy="128" r="35"/></clipPath>
<clipPath id="${id}body"><path d="M52 126C48 84 92 62 136 62c48 0 86 24 82 66-3 36-38 58-84 58S56 164 52 126z"/></clipPath>
</defs>
<ellipse cx="136" cy="214" rx="86" ry="9" fill="#000" opacity=".28"/>
<g class="cz-pig-rope"><path d="M135 0V26" stroke="#b8924a" stroke-width="6" stroke-dasharray="4 2.2"/><path d="M135 26L96 70M135 26L176 70" stroke="#b8924a" stroke-width="4.5" stroke-linecap="round" stroke-dasharray="4 2.2"/><circle cx="135" cy="24" r="8" fill="none" stroke="url(#${id}g)" stroke-width="4"/><circle cx="96" cy="70" r="4.5" fill="url(#${id}g)" stroke="#6e4c05" stroke-width="1"/><circle cx="176" cy="70" r="4.5" fill="url(#${id}g)" stroke="#6e4c05" stroke-width="1"/></g>
<g class="cz-pig-tail"><path d="M216 112c20-8 34 6 22 16s-22-6-8-10" fill="none" stroke="#c8567f" stroke-width="7" stroke-linecap="round"/><path d="M216 112c20-8 34 6 22 16s-22-6-8-10" fill="none" stroke="#ff9fc0" stroke-width="3.4" stroke-linecap="round"/></g>
<g><path d="M92 176h30v26q0 7-7 7h-16q-7 0-7-7z" fill="url(#${id}s)" stroke="#a63b6a" stroke-width="2"/><path d="M92 198h30v4q0 7-7 7h-16q-7 0-7-7z" fill="#5a2a3f"/><path d="M164 176h30v26q0 7-7 7h-16q-7 0-7-7z" fill="url(#${id}s)" stroke="#a63b6a" stroke-width="2"/><path d="M164 198h30v4q0 7-7 7h-16q-7 0-7-7z" fill="#5a2a3f"/></g>
<path d="M52 126C48 84 92 62 136 62c48 0 86 24 82 66-3 36-38 58-84 58S56 164 52 126z" fill="url(#${id}b)" stroke="#a63b6a" stroke-width="3"/>
<g clip-path="url(#${id}body)"><path d="M40 168C80 196 190 200 230 160V200H40z" fill="#8a2c58" opacity=".35"/><path d="M70 92C96 70 160 64 206 84" stroke="#fff" stroke-width="9" stroke-linecap="round" fill="none" opacity=".4"/><ellipse cx="186" cy="150" rx="22" ry="30" fill="#ffd0e0" opacity=".16"/></g>
<g class="cz-pig-ear"><path d="M92 74C84 44 112 34 128 60z" fill="url(#${id}s)" stroke="#a63b6a" stroke-width="2.4" stroke-linejoin="round"/><path d="M98 68C94 52 108 48 117 62z" fill="#ff8fb4" opacity=".85"/></g>
<g><path d="M118 63C140 56 168 58 182 66l-3 8C165 68 142 66 122 72z" fill="#1d0812" stroke="url(#${id}g)" stroke-width="2.2" stroke-linejoin="round"/><path d="M121 66c20-5 42-4 58 1" stroke="#ffd24a" stroke-width="1.2" fill="none" opacity=".7"/></g>
<g class="cz-pig-slotcoin"><g transform="translate(150 20) rotate(-14)"><ellipse rx="14" ry="14" fill="url(#${id}c)" stroke="#8d610a" stroke-width="1.6"/><ellipse rx="9.6" ry="9.6" fill="none" stroke="#b9871a" stroke-width="1.2"/><path d="M-3 -6.5v13M3.2 -4.4c0-1.8-2-2.4-3.2-2.4s-3.2.9-3.2 2.4c0 3.4 6.4 1.6 6.4 5 0 1.6-1.8 2.4-3.2 2.4s-3.2-.8-3.2-2.4" stroke="#8d610a" stroke-width="1.6" fill="none" stroke-linecap="round"/><path d="M-8 -8q5-6 12-5" stroke="#fffbe0" stroke-width="2" fill="none" stroke-linecap="round" opacity=".8"/></g></g>
<g><circle cx="132" cy="128" r="41" fill="url(#${id}g)" stroke="#6e4c05" stroke-width="2"/><circle cx="132" cy="128" r="36" fill="url(#${id}w)"/><g clip-path="url(#${id}p)"><g class="cz-pile" style="transform:translateY(${off}px)">${coins}</g></g><circle cx="132" cy="128" r="35" fill="none" stroke="#000" stroke-opacity=".5" stroke-width="3"/><path d="M104 114c8-14 26-20 40-17" stroke="#fff" stroke-width="4" stroke-linecap="round" fill="none" opacity=".55"/><circle cx="132" cy="128" r="41" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="1"/>${[0,60,120,180,240,300].map(a=>`<circle cx="${(132+41*Math.cos(a*Math.PI/180)).toFixed(1)}" cy="${(128+41*Math.sin(a*Math.PI/180)).toFixed(1)}" r="2" fill="#6e4c05"/>`).join('')}</g>
<g><ellipse cx="42" cy="124" rx="24" ry="21" fill="url(#${id}s)" stroke="#a63b6a" stroke-width="2.6"/><ellipse cx="30" cy="124" rx="11" ry="16" fill="#f07da6" stroke="#a63b6a" stroke-width="2"/><ellipse cx="29" cy="117" rx="3.2" ry="5.2" fill="#6b1d3f"/><ellipse cx="29" cy="132" rx="3.2" ry="5.2" fill="#6b1d3f"/><path d="M26 112c4-4 9-3 11 1" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" opacity=".6"/></g>
<g class="cz-pig-eye"><ellipse cx="78" cy="102" rx="7.2" ry="8.4" fill="#1b0b12"/><ellipse cx="80" cy="99" rx="2.8" ry="3.2" fill="#fff"/><circle cx="76" cy="106" r="1.3" fill="#fff" opacity=".8"/><path d="M68 94q8-7 16-2" stroke="#6b1d3f" stroke-width="2.4" fill="none" stroke-linecap="round"/></g>
<ellipse cx="80" cy="130" rx="11" ry="7" fill="#ff6f9f" opacity=".42"/>
<path d="M66 150q10 6 22 2" stroke="#a63b6a" stroke-width="2.2" fill="none" stroke-linecap="round" opacity=".7"/>
<path d="M104 70C100 54 112 48 124 52" stroke="#fff" stroke-width="2" fill="none" opacity=".45" stroke-linecap="round"/>
</svg>`;
}
/* met à jour le niveau de pièces sans recréer le dessin (l'animation ne redémarre pas) */
function pigMount(host,fill){
  if(!host)return;const s=host.querySelector('svg.cz-pig');
  if(!s){host.innerHTML=pigSvg(fill);return}
  const p=s.querySelector('.cz-pile');if(p)p.style.transform='translateY('+((1-clamp(fill,0,1))*72).toFixed(1)+'px)';
}
const pigFill=pot=>{pot=num(pot);return pot<=0?0:clamp(Math.log10(1+pot)/6,.07,1)};
function nextMonthMs(){const n=new Date();return Date.UTC(n.getUTCFullYear(),n.getUTCMonth()+1,1,0,0,0)}
const lotEnd=lot=>{const t=lot&&lot.period_end?Date.parse(lot.period_end):NaN;return isFinite(t)&&t>Date.now()?t:nextMonthMs()};

/* horloge Zimemberg locale */
function zimNow(){
  const l=Z.lobby&&Z.lobby.lot;if(!l)return {code:'',left:0,slot:213000};
  return {code:l.zim_code||'',left:Math.max(0,num(l.zim_left_ms)-(performance.now()-(Z.lobbyAt||0))),slot:num(l.zim_slot_ms)||213000};
}
const codeGroups=c=>String(c||'').replace(/(.{4})/g,'$1 ').trim();
function ringHtml(frac,size,cls){const r=size/2-4,C=2*Math.PI*r;return `<svg class="cz-ring ${cls||''}" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><circle cx="${size/2}" cy="${size/2}" r="${r}" fill="none" stroke="#ffffff22" stroke-width="4"/><circle class="cz-ring-v" cx="${size/2}" cy="${size/2}" r="${r}" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-dasharray="${C.toFixed(1)}" stroke-dashoffset="${(C*(1-clamp(frac,0,1))).toFixed(1)}" transform="rotate(-90 ${size/2} ${size/2})"/></svg>`}
function setRing(el,frac){const c=el&&el.querySelector('.cz-ring-v');if(!c)return;const C=+c.getAttribute('stroke-dasharray');c.setAttribute('stroke-dashoffset',(C*(1-clamp(frac,0,1))).toFixed(1))}

/* ---------- vue : hall ---------- */
V.hall=function(ctx){
  const {el,sc}=ctx;ctx.title='';
  el.innerHTML=`<div class="cz-hall"><div class="cz-ceil"></div>
   <div class="cz-sign"><div class="cz-sign-in"><span class="cz-neon n1">Casino</span><span class="cz-neon n2">Communicer!</span></div><div class="cz-bulbs"></div></div>
   <div class="cz-hall-grid">
    <section class="cz-zone cz-zpig"><h4>Tanhgokrom</h4><button class="cz-pigbtn" data-go="pig" type="button"><div class="cz-pigw"></div></button><div class="cz-pigtxt"><div class="cz-pot"><span>Cagnotte</span><b class="pot">…</b></div><div class="cz-cd"><span>Tirage dans</span><b class="cd">…</b></div></div></section>
    <section class="cz-zone cz-ztv"><h4>Télé Zimemberg</h4><button class="cz-tvmini" data-go="tv" type="button"><div class="cz-tvscr"><div class="cz-tvlbl">Code en cours</div><div class="cz-tvcode">…</div><div class="cz-tvcd">…</div></div><div class="cz-tvfoot"></div></button></section>
    <section class="cz-zone cz-zgames"><h4>Tables</h4><div class="cz-games"><div class="cz-spinner"></div></div></section>
    <section class="cz-zone cz-zslots"><h4>Machines à sous</h4><div class="cz-slotrow"></div></section>
    <section class="cz-zone cz-zlot"><h4>Lot-Au-MAX!</h4><div class="cz-lotrow">
      <button class="cz-st" data-go="guichet" type="button" style="--n:#ffb83d"><div class="cz-sti"><svg viewBox="0 0 90 70"><rect x="4" y="4" width="82" height="62" rx="6" fill="#5a1a24" stroke="#d4af37" stroke-width="2"/><rect x="14" y="16" width="62" height="30" rx="3" fill="#0c0305" stroke="#d4af37"/><rect x="10" y="48" width="70" height="8" rx="2" fill="#d4af37"/><rect x="26" y="8" width="38" height="8" rx="2" fill="#ffb83d"/><text x="45" y="14.500" text-anchor="middle" font-size="6.500" font-weight="800" fill="#4a0d17" font-family="Georgia">GUICHET</text><rect x="30" y="30" width="30" height="14" rx="2" fill="#f4ead0"/><path d="M34 35h22M34 39h14" stroke="#c4122f" stroke-width="2"/></svg></div><b>Guichet</b><span class="sub gprice">Acheter un billet</span></button>
      <button class="cz-st" data-go="tickets" type="button" style="--n:#ff4fd8"><div class="cz-sti"><svg viewBox="0 0 90 70"><g transform="rotate(-8 45 35)"><rect x="12" y="14" width="66" height="42" rx="5" fill="#f4ead0" stroke="#b88a2a" stroke-width="2"/><rect x="12" y="14" width="66" height="10" fill="#c4122f"/><rect x="60" y="14" width="10" height="42" fill="url(#czg-holo)" opacity=".8"/><circle cx="34" cy="40" r="8" fill="#c0c6d0"/></g></svg></div><b>Mes billets</b><span class="sub ntk">Sac et grattage</span></button>
      <button class="cz-st" data-go="scanner" type="button" style="--n:#3dd6ff"><div class="cz-sti"><svg viewBox="0 0 90 70"><rect x="14" y="10" width="62" height="40" rx="6" fill="#222a36" stroke="#6d7480" stroke-width="2"/><rect x="20" y="16" width="50" height="22" rx="3" fill="#06141c"/><path d="M22 27h46" stroke="#3dd6ff" stroke-width="2.500" class="cz-laser"/><rect x="30" y="52" width="30" height="10" rx="2" fill="#6d7480"/></svg></div><b>Scanner</b><span class="sub">Vérifier un code</span></button>
      <button class="cz-st" data-go="bank" type="button" style="--n:#7dff8a"><div class="cz-sti"><svg viewBox="0 0 90 70"><path d="M6 24L45 6l39 18z" fill="#d4af37" stroke="#8d6a12"/><rect x="12" y="26" width="8" height="30" fill="#f4ead0"/><rect x="28" y="26" width="8" height="30" fill="#f4ead0"/><rect x="54" y="26" width="8" height="30" fill="#f4ead0"/><rect x="70" y="26" width="8" height="30" fill="#f4ead0"/><rect x="6" y="58" width="78" height="8" rx="2" fill="#d4af37"/></svg></div><b>Banque de ticket</b><span class="sub">Réclamer vos gains</span></button>
    </div></section>
    <section class="cz-zone cz-zxch"><h4>Échange de jetons</h4>
      <div class="cz-xinfo">Compte : <b id="czXt">…</b> jetons · Casino : <b id="czXc">…</b> jetons de casino · Taux 1 pour 1</div>
      <div class="cz-xrow"><select id="czXd2" aria-label="Sens de l’échange"><option value="in">Du compte vers le casino</option><option value="out">Du casino vers le compte</option></select>
      <input id="czXn2" type="number" inputmode="numeric" min="1" step="1" value="100" aria-label="Montant"><button class="cz-btn gold" id="czXg" type="button">Échanger</button></div>
    </section>
   </div></div>`;
  const xRef=async()=>{try{const r=await RPC('casino_chips_me');const t=$('#czXt',el),c=$('#czXc',el);if(t)t.textContent=nfl(r.tokens);if(c)c.textContent=nfl(r.chips);setBal(r.chips)}catch(e){}};
  xRef();
  $('#czXg',el).onclick=function(){act('xchg2',async()=>{const n=Math.floor(+$('#czXn2',el).value);if(!(n>=1))return say('Entrez un montant d’au moins 1');const x=await RPC('casino_exchange',{p_dir:$('#czXd2',el).value,p_amount:n});setBal(x.chips);try{if(typeof balRefresh==='function')balRefresh()}catch(e){}AU.chips&&AU.chips(3);say('Échange effectué');xRef()},this)};
  const pigW=$('.cz-pigw',el),potE=$('.pot',el),cdE=$('.cd',el),tvC=$('.tvcode',el)||$('.cz-tvcode',el),tvD=$('.cz-tvcd',el);
  let lastFill=-1;
  const drawLobby=()=>{
    const L=Z.lobby;if(!L)return;
    const g=$('.cz-games',el);
    g.innerHTML=(L.games||[]).map(gm=>`<div class="cz-game"><div class="cz-gill">${ILL[gm.game]||''}</div><div class="cz-ginfo"><h5>${E(GN[gm.game]||gm.label)}</h5><div class="cz-tlist">${(gm.tables||[]).map(t=>`<button class="cz-tb" type="button" data-go="${E(gm.game)}" data-id="${t.id}" data-n="${E(t.name)}"><b>${E(t.name)}</b><span class="cz-tm">${ico('user',13)}${t.humans||0} ${ico('bot',13)}${t.bots||0}</span><span class="cz-tp">${E(phName(t.phase))}</span><span class="cz-tmin">${nf(t.min_bet)}${t.max_bet?' à '+nf(t.max_bet):''}</span></button>`).join('')||'<span class="cz-muted">Aucune table</span>'}</div></div></div>`).join('');
    $('.cz-slotrow',el).innerHTML=(L.slots||[]).map(m=>`<button class="cz-mach" type="button" data-go="slots" data-id="${m.id}" data-n="${E(m.name)}" style="--h:${hashStr(m.theme||m.name)%360}">${ILL.slots}<b>${E(m.name)}</b><span>${nf(m.min_bet)} - ${nf(m.max_bet)}</span></button>`).join('');
    const lot=L.lot||{};const f=pigFill(lot.pot);
    if(Math.abs(f-lastFill)>.005){lastFill=f;pigMount(pigW,f)}
    potE.textContent=nfl(lot.pot||0);$('.gprice',el).textContent='Billet : '+nf(lot.price||0)+' jetons';
    const wb=$('.ntk',el);wb.textContent=lot.pending_win?'Gain à réclamer !':'Sac et grattage';
  };
  const tick=()=>{
    const L=Z.lobby;if(!L)return;const lot=L.lot||{};
    cdE.textContent=fmtLong(lotEnd(lot)-Date.now());
    const z=zimNow();tvC.textContent=codeGroups(z.code)||'…';tvD.textContent=z.code?fmtMs(z.left):'';
    if(z.code&&z.left<=0&&!tick.w){tick.w=1;load().finally(()=>{tick.w=0})}
  };
  const load=async()=>{if(D.hidden||!Z.root)return;try{const l=await getLobby();Z.lobbyAt=performance.now();if(sc.dead)return;drawLobby();tick()}catch(e){if(!load.e){load.e=1;say(EM(e))}}};
  // bulbes
  $('.cz-bulbs',el).innerHTML=Array.from({length:26},(_,i)=>`<i style="--i:${i}"></i>`).join('');
  el.addEventListener('click',e=>{
    const b=e.target.closest('[data-go]');if(!b)return;AU.unlock();AU.click();
    const g=b.dataset.go;if(b.dataset.id)go(g,{id:+b.dataset.id,name:b.dataset.n});else go(g);
  });
  if(Z.lobby){Z.lobbyAt=Z.lobbyAt||performance.now();drawLobby()}
  load();sc.iv(load,10000);sc.iv(tick,250);
};

/* ---------- infrastructure commune des tables (poker, 21, roulette) ---------- */
const PHN={waiting:'En attente de joueurs',between:'Prochaine main',preflop:'Avant le flop',flop:'Flop',turn:'Turn',river:'River',showdown:'Abattage',betting:'Les mises sont ouvertes',dealing:'Distribution',playing:'Tour des joueurs',dealer:'Tour du croupier',payout:'Résultats',spinning:'La bille tourne',result:'Résultat'};
function seatXY(rel,wide){const a=(90+rel*36)*Math.PI/180;const rx=wide?41:39,ry=wide?37:41;return [50+rx*Math.cos(a),50+ry*Math.sin(a)]}
function betXY(rel,wide){const [x,y]=seatXY(rel,wide);return [x+(50-x)*.40,y+(52-y)*.40]}
const avatar=(look,name,cls)=>`<div class="cz-av ${cls||''}">${charSvg(look,{name})}</div>`;

/* ne réécrit le DOM d'une zone que si son contenu change : sinon les boutons bougent et les clics se perdent à chaque rafraîchissement */
function guardTbl(el){
  const d=Object.getOwnPropertyDescriptor(Element.prototype,'innerHTML');
  ['.cz-seats','.cz-center','.cz-ctl','.cz-sidew','.cz-logw','.cz-rbets'].forEach(q=>{const e=el.querySelector(q);if(!e||e.__g)return;e.__g=1;
    Object.defineProperty(e,'innerHTML',{configurable:true,get(){return d.get.call(this)},set(v){if(this.__h===v)return;this.__h=v;d.set.call(this,v)}})});
}
/* Poll + rendu d'une table. hooks.render(st,prev) est appelé à chaque nouvel état ; hooks.light(st) quand rien n'a changé. */
function tableBase(ctx,game,hooks){
  const {el,sc}=ctx;const id=ctx.arg&&ctx.arg.id;
  if(!id){go('hall');return null}
  const T={id,name:(ctx.arg&&ctx.arg.name)||'Table',game,st:null,ver:0,at:0,wide:true,fetching:false,dead:false};
  ctx.title=T.name;ctx.back='hall';
  const measure=()=>{T.wide=el.clientWidth>=720};
  measure();sc.on(window,'resize',()=>{const w=T.wide;measure();if(w!==T.wide&&T.st)hooks.render(T.st,T.st)});
  T.leftMs=()=>{const s=T.st;if(!s||s.phase_left_ms==null)return null;return Math.max(0,s.phase_left_ms-(performance.now()-T.at))};
  T.poll=async(force)=>{
    if(T.fetching||sc.dead||(D.hidden&&!force))return;T.fetching=true;
    try{
      const st=await RPC('casino_state',{p_table:id,p_since:force?-1:T.ver});
      if(sc.dead)return;T.at=performance.now();
      if(st&&st.unchanged){if(T.st){T.st.me=Object.assign({},T.st.me,st.me||{});T.st.now_ms=st.now_ms}hooks.light&&hooks.light(T.st)}
      else if(st){const prev=T.st;T.st=st;T.ver=st.version;if(st.me)setBal(st.me.wallet);hooks.render(st,prev)}
      T.err=0;
    }catch(e){if(sc.dead)return;console.error(e);T.err=(T.err||0)+1;if(T.err===1||T.err%20===0)say(EM(e));if(/introuvable/i.test(EM(e))){go('hall')}}
    finally{T.fetching=false}
  };
  T.act=(key,fn,btn)=>act(key,async()=>{const r=await fn();await T.poll(true);return r},btn);
  T.sit=async(seat,min,max,need)=>{
    let buy=null;
    if(need){
      const bal=Math.floor(Z.bal||0);const hi=Math.min(max,bal);
      if(hi<min){say('Il vous faut au moins '+nf(min)+' jetons pour vous asseoir');return}
      buy=await new Promise(res=>{
        const d=dlg(`<h3>S’asseoir à ${E(T.name)}</h3><p>Choisissez votre quitte-ou-double d’entrée (retiré de votre solde, rendu à votre départ).</p><div class="cz-buy"><input type="range" min="${min}" max="${hi}" step="${min>=100?10:1}" value="${Math.min(hi,Math.max(min,Math.round(hi/4/10)*10))}"><b class="cz-buyv"></b></div><div class="cz-dlg-btn"><button class="cz-btn ghost" data-x>Annuler</button><button class="cz-btn gold" data-ok>S’asseoir</button></div>`);
        if(!d)return res(null);const r=$('input',d),v=$('.cz-buyv',d);const up=()=>{v.textContent=nfl(+r.value)};r.oninput=up;up();let ok=false;
        $('[data-ok]',d).onclick=()=>{ok=true;res(+r.value);d.close()};d.addEventListener('click',e=>{if(e.target.closest('[data-x]')&&!ok)res(null)});
      });
      if(buy==null)return;
    }
    await T.act('sit',()=>RPC('casino_join',{p_table:id,p_seat:seat,p_buyin:buy}));AU.pop();
  };
  T.leave=async()=>{await act('leave',async()=>{const r=await RPC('casino_leave',{p_table:id});if(r&&r.refunded>0)say('Jetons rendus : '+nfl(r.refunded));await refreshBal();await T.poll(true)})};
  T.vote=async(yes)=>{await T.act('vote',async()=>{const r=await RPC('casino_bot_vote',{p_table:id,p_yes:yes});if(r&&r.added){say('Un bot s’assoit à la table');AU.chips(3)}else AU.click()})};
  ctx.leave=async()=>{T.dead=true;AU.sirenStop&&AU.sirenStop();if(T.siren){try{T.siren.stop()}catch(e){}T.siren=null};try{await RPC('casino_leave',{p_table:id});refreshBal()}catch(e){}};
  T.poll(true);sc.iv(()=>T.poll(false),game==='poker'?700:900);
  sc.on(D,'visibilitychange',()=>{if(!D.hidden)T.poll(true)});
  return T;
}
/* barre d'actions secondaires (bot / quitter) */
function sideBar(T,st){
  const me=st.me||{},bv=me.bot_vote||{};const seated=me.seat!=null;
  if(!seated)return '';
  return `<div class="cz-side"><button class="cz-btn ghost sm" data-vote type="button" title="70 % des joueurs doivent être d’accord">${ico('bot',16)} ${bv.voted?'Retirer mon vote':'Ajouter un bot'} <b>${bv.yes||0}/${bv.needed||1}</b></button><button class="cz-btn ghost sm" data-leave type="button">${ico('leave',16)} Quitter</button></div>`;
}
function bindSide(T,root){
  root.addEventListener('click',e=>{
    const v=e.target.closest('[data-vote]');if(v){const bv=(T.st.me||{}).bot_vote||{};T.vote(!bv.voted);return}
    const l=e.target.closest('[data-leave]');if(l){T.leave()}
  });
}
const logHtml=st=>'';   /* journal sous la table désactivé */

/* ================= POKER ================= */
V.poker=function(ctx){
  const {el,sc}=ctx;
  el.innerHTML=`<div class="cz-tview"><div class="cz-tinfo"><span class="ph"></span><span class="tm"></span></div><div class="cz-tbl cz-poker"><div class="cz-rail"></div><div class="cz-felt"></div><div class="cz-seats"></div><div class="cz-center"></div><div class="cz-alarmL"></div></div><div class="cz-ctl"></div><div class="cz-tfoot"><div class="cz-hint">${ico('eye',15)} Astuce : cliquez en rafale sur un joueur en main pour l’observer discrètement.</div><div class="cz-sidew"></div></div><div class="cz-logw"></div></div>`;
  guardTbl(el);
  const seatsE=$('.cz-seats',el),centerE=$('.cz-center',el),ctlE=$('.cz-ctl',el),alE=$('.cz-alarmL',el),phE=$('.ph',el),tmE=$('.tm',el),sideE=$('.cz-sidew',el),logE=$('.cz-logw',el);
  let seen=new Set(),lastHand=-1,lastWin=null,cheat=null,lastComm=0,lastTurn=false,raiseV=0,alarmIds='';
  const cardsH=(arr,key,cw,peek)=>{
    arr=arr||[];return arr.map((c,i)=>{const k=key+i+':'+c;const fresh=!seen.has(k);seen.add(k);const pk=peek&&peek[i];
      return cardHtml(pk&&c==='??'?pk:c,(fresh?'fresh ':'')+(pk&&c==='??'?'peek ':'')).replace('class="cz-card','style="--cw:'+cw+'px" class="cz-card')}).join('');
  };
  let T=null;
  const cheatBar=(s)=>cheat&&cheat.seat===s?`<div class="cz-chbar"><i style="width:${Math.min(100,cheat.clicks/cheat.need*100)}%"></i><span>Clic clic clic !</span></div>`:'';
  const render=(st)=>{
    const me=st.me||{},base=0,wide=T.wide,hand=st.hand_no;
    if(hand!==lastHand){seen=new Set();lastHand=hand}
    phE.textContent=PHN[st.phase]||st.phase;
    const bb=st.table.min_bet;
    const inHand=['preflop','flop','turn','river'].includes(st.phase);
    const peeks={};(me.peeks||[]).forEach(p=>{peeks[p.seat]=p.cards});
    const sp=st.to_act;
    let h='';
    for(let i=0;i<10;i++){
      const s=st.seats[i],rel=(i-base+10)%10,[x,y]=seatXY(rel,wide),[bx,by]=betXY(rel,wide);
      if(!s){if(i===5){continue}h+=me.seat==null?`<button class="cz-seat empty" style="left:${x}%;top:${y}%" data-sit="${i}" type="button"><span>S’asseoir</span></button>`:`<div class="cz-seat empty ghostseat" style="left:${x}%;top:${y}%"></div>`;continue}
      const mine=i===me.seat,turn=sp===i,win=s.winner&&st.phase!=='preflop';
      const cards=(s.cards&&s.cards.length)?cardsH(s.cards,'s'+i,mine?(wide?46:40):(wide?32:26),peeks[i]):'';
      const canWatch=!mine&&inHand&&(s.status==='active'||s.status==='allin');
      h+=`<div class="cz-seat ${mine?'mine':''} ${turn?'turn':''} ${win?'win':''} ${s.status==='folded'?'folded':''} ${canWatch?'watch':''} ${s.kind==='bot'?'isbot':''}" style="left:${x}%;top:${y}%" data-seat="${i}">
        ${s.last?`<div class="cz-bub">${E(s.last)}</div>`:''}${s.button?'<i class="cz-btnD">D</i>':''}<div class="cz-hole">${cards}</div>${avatar(s.look,s.name)}${cheatBar(i)}
        <div class="cz-nm">${E(s.name)}${s.kind==='bot'?' <em>bot</em>':''}</div><div class="cz-stk">${symbolCoin}${nf(s.stack)}</div>${s.hand&&st.phase==='showdown'?`<div class="cz-hn">${E(s.hand)}</div>`:''}</div>
        ${s.bet>0?`<div class="cz-betspot" style="left:${bx}%;top:${by}%">${chipStack(s.bet,2)}<b>${nf(s.bet)}</b></div>`:''}`;
    }
    // croupier
    const d=st.dealer||{};const dTurn=sp==='dealer';
    h+=`<div class="cz-seat dealer ${dTurn?'turn':''} ${d.winner?'win':''} ${d.status==='folded'?'folded':''} " style="left:50%;top:${wide?9:8}%" data-seat="10">
      ${d.last?`<div class="cz-bub">${E(d.last)}</div>`:''}${d.button?'<i class="cz-btnD">D</i>':''}<div class="cz-hole">${cardsH(d.cards,'d',wide?34:28,null)}</div>${avatar(st.dealer.look,st.dealer.name)}${cheatBar(10)}
      <div class="cz-nm">${E(d.name||'Croupier')} <em>croupier</em></div><div class="cz-stk">${symbolCoin}${nf(d.stack||0)}</div>${d.hand&&st.phase==='showdown'?`<div class="cz-hn">${E(d.hand)}</div>`:''}</div>
      ${d.bet>0?`<div class="cz-betspot" style="left:50%;top:${wide?27:24}%">${chipStack(d.bet,2)}<b>${nf(d.bet)}</b></div>`:''}`;
    seatsE.innerHTML=h;
    // centre
    const comm=st.community||[];
    if(comm.length>lastComm){AU.flip();if(comm.length===3)AU.card()}lastComm=comm.length;
    let cc='';for(let i=0;i<5;i++){const c=comm[i];cc+=c?cardsH([c],'c'+i,wide?56:42).replace(/<div class="cz-card/,'<div class="cz-card cc'):`<div class="cz-cslot" style="--cw:${wide?56:42}px"></div>`}
    const lh=st.last_hand&&st.last_hand.winners;
    centerE.innerHTML=`<div class="cz-comm">${cc}</div><div class="cz-pot">${chipStack(st.pot,3)}<span>Pot <b>${nfl(st.pot||0)}</b></span></div>${lh&&lh.length&&(st.phase==='showdown'||st.phase==='between')?`<div class="cz-win">${lh.map(w=>`<div><b>${E(w.name)}</b> remporte ${nf(w.amount)}${w.hand?' — '+E(w.hand):''}</div>`).join('')}</div>`:''}`;
    // gains : effets
    const wk=lh&&lh.length&&st.phase==='showdown'?hand+':'+lh.map(w=>w.name+w.amount).join():null;
    if(wk&&wk!==lastWin){lastWin=wk;const iWon=lh.some(w=>me.seat!=null&&String(w.seat)===String(me.seat));
      if(iWon){AU.win(true);FX.coinRain(50);FX.flash('#ffd24a')}else{AU.chips(4)}}
    // actions
    sideE.innerHTML=sideBar(T,st);
    logE.innerHTML=logHtml(st);
    drawCtl(st);
    drawAlarms(st);
    if(me.to_act&&!lastTurn){AU.beep()}lastTurn=!!me.to_act;
  };
  const drawCtl=(st)=>{
    const me=st.me||{};
    if(me.seat==null){ctlE.innerHTML=`<div class="cz-msg">Choisissez une place libre pour rejoindre la table. Blindes ${nf(st.table.min_bet/2)} / ${nf(st.table.min_bet)}.</div>`;return}
    if(me.stack<st.table.min_bet&&!['preflop','flop','turn','river'].includes(st.phase)){
      ctlE.innerHTML=`<div class="cz-msg">Votre pile est vide. <button class="cz-btn gold sm" data-rebuy type="button">Racheter des jetons</button></div>`;return}
    if(!me.to_act){
      const inHand=['preflop','flop','turn','river'].includes(st.phase);
      ctlE.innerHTML=`<div class="cz-msg">${inHand?(st.to_act==null?'Les cartes sont distribuées…':'En attente des autres joueurs…'):(PHN[st.phase]||'')}</div>`;return}
    const call=me.call_amt||0,mn=me.min_raise_to||0,mx=me.max_raise_to||0;
    if(!raiseV||raiseV<mn||raiseV>mx)raiseV=Math.min(mx,mn);
    ctlE.innerHTML=`<div class="cz-acts"><div class="cz-turnring">${ringHtml(1,46,'cz-ring-turn')}</div>
      <button class="cz-btn red" data-a="fold" type="button">Se coucher</button>
      ${call>0?`<button class="cz-btn blue" data-a="call" type="button">Suivre ${nf(call)}</button>`:`<button class="cz-btn blue" data-a="check" type="button">Checker</button>`}
      ${mx>0&&mx>call+ (me.bet||0)-0.001&&mn<=mx?`<span class="cz-raise"><button class="cz-btn green" data-a="raise" type="button">${call>0?'Relancer':'Miser'} à <b id="czRv">${nf(raiseV)}</b></button><input type="range" id="czRs" min="${mn}" max="${mx}" step="${Math.max(1,Math.floor(st.table.min_bet/2))}" value="${raiseV}"><span class="cz-pre"><button data-pre="0.5" class="cz-btn ghost sm" type="button">½ pot</button><button data-pre="1" class="cz-btn ghost sm" type="button">Pot</button></span></span>`:''}
      <button class="cz-btn gold" data-a="allin" type="button">Tapis ${nf(mx)}</button></div>`;
  };
  ctlE.addEventListener('click',e=>{
    const rb=e.target.closest('[data-rebuy]');if(rb){T.sit(null,T.st.table.buyin_min,Math.min(T.st.table.buyin_max,Math.floor(Z.bal||0)),true);return}
    const p=e.target.closest('[data-pre]');if(p){const st=T.st,me=st.me,mn=me.min_raise_to,mx=me.max_raise_to;raiseV=clamp(Math.round((me.bet||0)+(st.current_bet||0)+(st.pot||0)*(+p.dataset.pre)),mn,mx);const s=$('#czRs',ctlE);if(s)s.value=raiseV;const v=$('#czRv',ctlE);if(v)v.textContent=nf(raiseV);AU.click();return}
    const b=e.target.closest('[data-a]');if(!b)return;const a=b.dataset.a;AU.click();
    T.act('pk',()=>RPC('poker_action',{p_table:T.id,p_action:a,p_amount:a==='raise'?raiseV:0}),b).then(()=>{if(a==='fold')AU.fold();else AU.chip()});
  });
  ctlE.addEventListener('input',e=>{if(e.target.id==='czRs'){raiseV=+e.target.value;const v=$('#czRv',ctlE);if(v)v.textContent=nf(raiseV)}});

  /* ---- triche : le clic sur le personnage lance l'observation, puis on spamme ---- */
  const endCheat=async(kind)=>{
    const c=cheat;if(!c||c.done)return;c.done=true;sc.clr(c.iv);
    let res=null;try{res=await RPC('casino_cheat_result',{p_attempt:c.id})}catch(e){}
    cheat=null;if(sc.dead)return;
    if(res&&res.status==='success'){AU.win(false);FX.flash('#7dd6ff');const nm=(T.st.seats[c.seat]||T.st.dealer||{}).name||'ce joueur';say('Vous voyez une carte de '+nm+' : '+cardName(res.card));}
    else if(res&&res.status==='caught'||kind==='caught'){AU.err();FX.flash('#ff2a2a');say('Pris sur le fait ! Plus d’observation sur cette personne pour cette partie.')}
    else{AU.lose();say('Observation ratée : trop peu de clics.')}
    T.poll(true);
  };
  const flush=async()=>{
    const c=cheat;if(!c||c.done||c.busy)return;const n=Math.min(12,c.pending);if(n<=0&&Date.now()<c.end)return;
    c.pending-=n;c.busy=true;
    try{const r=await RPC('casino_cheat_click',{p_attempt:c.id,p_n:n});c.busy=false;if(!cheat||cheat.done)return;
      if(r.status==='caught'){endCheat('caught');return}
      if(r.left_ms<=0||Date.now()>=c.end+300){endCheat();return}
    }catch(e){c.busy=false;say(EM(e));cheat=null}
  };
  const startCheat=async(seat)=>{
    if(cheat){cheat.clicks++;cheat.pending++;AU.tick();bar();return}
    const st=T.st,me=st.me||{},ch=me.cheat||{};
    if(me.seat==null){say('Asseyez-vous d’abord à la table');return}
    if(ch.cooldown_ms>0){say('Observation en recharge : '+Math.ceil(ch.cooldown_ms/1000)+' s');return}
    if((ch.blocked_seats||[]).includes(seat)){say('Vous ne pouvez plus observer cette personne pendant cette partie');return}
    await act('cheat',async()=>{
      const r=await RPC('casino_cheat_start',{p_table:T.id,p_seat:seat});
      cheat={id:r.attempt,seat,need:r.need,clicks:1,pending:1,end:Date.now()+r.secs*1000,busy:false,done:false};
      cheat.iv=sc.iv(flush,500);sc.to(()=>{if(cheat&&!cheat.done)endCheat()},r.secs*1000+700);AU.tick();render(T.st);
    });
  };
  const bar=()=>{const b=$('.cz-chbar i',seatsE);if(b&&cheat)b.style.width=Math.min(100,cheat.clicks/cheat.need*100)+'%'};
  seatsE.addEventListener('click',e=>{
    const sit=e.target.closest('[data-sit]');if(sit){const st=T.st;T.sit(+sit.dataset.sit,st.table.buyin_min,st.table.buyin_max,true);return}
    const rb=e.target.closest('[data-rebuy]');
    const s=e.target.closest('.cz-seat[data-seat]');if(!s)return;const i=+s.dataset.seat;if(!s.classList.contains('watch'))return;startCheat(i);
  });
  /* ---- alarme (la cible voit le point rouge et doit cliquer dessus) ---- */
  const drawAlarms=(st)=>{
    const al=(st.me&&st.me.alarms)||[];const key=al.map(a=>a.attempt).join();
    if(key===alarmIds){al.forEach(a=>{const e=$('[data-al="'+a.attempt+'"]',alE);if(e)e.style.setProperty('--left',Math.max(0,a.left_ms)/1000)});return}
    alarmIds=key;
    if(!al.length){alE.innerHTML='';if(T.siren){try{T.siren.stop()}catch(e){}T.siren=null}return}
    const base=0,wide=T.wide;
    alE.innerHTML=al.map(a=>{const [x,y]=a.seat>=0?seatXY(((a.seat-base)+10)%10,wide):[50,18];
      return `<button class="cz-dot" type="button" data-al="${a.attempt}" style="left:${x}%;top:${Math.max(4,y-12)}%" title="Cliquez pour l’arrêter"><i></i><span>${E(a.username)} vous observe !</span></button>`}).join('')+`<div class="cz-alarmbn">ALARME — quelqu’un regarde vos cartes. Cliquez le point rouge !</div>`;
    if(!T.siren)T.siren=AU.sirenStart();
  };
  alE.addEventListener('click',e=>{const b=e.target.closest('[data-al]');if(!b)return;act('catch',async()=>{const r=await RPC('casino_cheat_catch',{p_attempt:+b.dataset.al});if(r&&r.caught){AU.win(false);FX.burst(b,18,'#ff3b3b');say('Tricheur repéré !')}T.poll(true)})});
  /* ---- horloge locale : anneau du temps de jeu ---- */
  const light=(st)=>{drawAlarms(st);const ch=(st.me||{}).cheat;if(ch&&!cheat)ch.cooldown_ms=ch.cooldown_ms};
  T=tableBase(ctx,'poker',{render,light});if(!T)return;bindSide(T,sideE);
  sc.iv(()=>{
    const l=T.leftMs(),st=T.st;if(!st)return;tmE.textContent=l!=null&&st.phase_total_ms?fmtMs(l):'';
    const r=$('.cz-ring-turn',ctlE);if(r&&st.phase_total_ms)setRing(r.parentNode,l/st.phase_total_ms);
    if(st.me&&st.me.to_act&&l!=null&&l<5000&&Math.floor(l/1000)!==T.tk){T.tk=Math.floor(l/1000);AU.tick()}
  },200);
};
const cardName=c=>{if(!c)return '?';const r=c[0],s=c[1];const rn={T:'10',J:'Valet',Q:'Dame',K:'Roi',A:'As'}[r]||r;return rn+' de '+({s:'pique',h:'cœur',d:'carreau',c:'trèfle'}[s]||'')};

/* ================= BLACKJACK ================= */
const BJRES={win:'Gagné',lose:'Perdu',push:'Égalité',blackjack:'Blackjack !'};
const chipValues=(mn,mx)=>[1,5,10,25,50,100,500,1000,5000].filter(v=>v>=Math.min(mn,5)&&v<=mx*2).slice(0,7);
V.blackjack=function(ctx){
  const {el,sc}=ctx;
  el.innerHTML=`<div class="cz-tview"><div class="cz-tinfo"><span class="ph"></span><span class="tm"></span></div><div class="cz-tbl cz-bj"><div class="cz-rail"></div><div class="cz-felt"></div><div class="cz-arc">Le croupier tire sous 17 — Blackjack paie 3 pour 2</div><div class="cz-seats"></div></div><div class="cz-ctl"></div><div class="cz-tfoot"><div class="cz-hint"></div><div class="cz-sidew"></div></div><div class="cz-logw"></div></div>`;
  guardTbl(el);
  const seatsE=$('.cz-seats',el),ctlE=$('.cz-ctl',el),phE=$('.ph',el),tmE=$('.tm',el),sideE=$('.cz-sidew',el),logE=$('.cz-logw',el);
  let seen=new Set(),lastRound='',lastPh='',chipSel=0,T=null,lastTurn=false;
  const cardsH=(arr,key,cw)=>(arr||[]).map((c,i)=>{const k=key+i+':'+c;const f=!seen.has(k);seen.add(k);if(f)AU.card();return cardHtml(c,f?'fresh':'').replace('class="cz-card','style="--cw:'+cw+'px" class="cz-card')}).join('');
  const handH=(h,key,cw)=>{if(!h)return '';return `<div class="cz-hand">${cardsH(h.cards,key,cw)}</div>${h.total!=null&&h.cards&&h.cards.length?`<div class="cz-tot ${h.total>21?'bust':''}">${h.total>21?'Bust ':''}${h.total}</div>`:''}`};
  const render=(st)=>{
    const me=st.me||{},base=0,wide=T.wide;
    const round=st.hand_no+':'+(st.round||'');if(st.phase==='betting'&&lastPh!=='betting'){seen=new Set()}
    if(lastPh!==st.phase){if(st.phase==='dealer')AU.flip();lastPh=st.phase}
    phE.textContent=PHN[st.phase]||st.phase;
    let h='';
    for(let i=0;i<10;i++){
      const s=st.seats[i],rel=(i-base+10)%10,[x,y]=seatXY(rel,wide);
      if(!s){if(i===5){continue}h+=me.seat==null?`<button class="cz-seat empty" style="left:${x}%;top:${y}%" data-sit="${i}" type="button"><span>S’asseoir</span></button>`:`<div class="cz-seat empty ghostseat" style="left:${x}%;top:${y}%"></div>`;continue}
      const mine=i===me.seat,hd=s.hand,r=hd&&hd.result;
      h+=`<div class="cz-seat ${mine?'mine':''} ${s.status==='playing'?'turn':''} ${r==='win'||r==='blackjack'?'win':''} ${r==='lose'||s.status==='bust'?'folded':''} ${s.kind==='bot'?'isbot':''}" style="left:${x}%;top:${y}%">
        ${s.last&&!r?`<div class="cz-bub">${E(s.last)}</div>`:''}${r?`<div class="cz-bub res ${r}">${BJRES[r]||''}${hd.payout>0?' +'+nf(hd.payout):''}</div>`:''}
        <div class="cz-bjh">${handH(hd,'p'+i,wide?38:30)}</div>${avatar(s.look,s.name)}<div class="cz-nm">${E(s.name)}${s.kind==='bot'?' <em>bot</em>':''}</div>
        ${hd&&hd.bet>0?`<div class="cz-bjbet">${chipStack(hd.bet,2)}<b>${nf(hd.bet)}${hd.doubled?' x2':''}</b></div>`:''}</div>`;
    }
    const d=st.dealer||{};
    h+=`<div class="cz-seat dealer ${st.phase==='dealer'?'turn':''}" style="left:50%;top:${wide?9:8}%"><div class="cz-bjh up">${d.cards&&d.cards.length?`<div class="cz-hand">${cardsH(d.cards,'d',wide?44:34)}</div>${d.total!=null?`<div class="cz-tot ${d.total>21?'bust':''}">${d.total>21?'Bust ':''}${d.total}</div>`:''}`:''}</div>${avatar(d.look,d.name)}<div class="cz-nm">${E(d.name||'Croupier')} <em>croupier</em></div></div>`;
    seatsE.innerHTML=h;
    sideE.innerHTML=sideBar(T,st);logE.innerHTML=logHtml(st);
    // gains
    if(st.phase==='payout'){const k=st.hand_no+':'+(me.seat);const hd=me.seat!=null&&st.seats[me.seat]&&st.seats[me.seat].hand;
      if(hd&&hd.result&&lastRound!==k){lastRound=k;if(hd.result==='win'||hd.result==='blackjack'){AU.win(hd.result==='blackjack');FX.coinRain(hd.result==='blackjack'?60:30);if(hd.result==='blackjack')FX.confetti(40)}else if(hd.result==='lose')AU.lose();else AU.click()}}
    drawCtl(st);
    if(me.to_act&&!lastTurn)AU.beep();lastTurn=!!me.to_act;
  };
  const drawCtl=(st)=>{
    const me=st.me||{},tb=st.table;
    if(me.seat==null){ctlE.innerHTML=`<div class="cz-msg">Prenez place à la table. Mise ${nf(tb.min_bet)} à ${nf(tb.max_bet)}.</div>`;return}
    const hd=st.seats[me.seat]&&st.seats[me.seat].hand;
    if(st.phase==='betting'){
      const vals=chipValues(tb.min_bet,tb.max_bet);if(!vals.includes(chipSel))chipSel=vals.find(v=>v>=tb.min_bet)||vals[0];
      ctlE.innerHTML=`<div class="cz-acts"><div class="cz-chbtns">${vals.map(v=>`<button type="button" class="cz-chipb ${v===chipSel?'on':''}" data-chip="${v}">${chipBtn(v)}</button>`).join('')}</div><button class="cz-btn gold" data-bet type="button">Miser ${nf(chipSel)}</button><span class="cz-msg2">Mise actuelle : <b>${nf(hd?hd.bet:0)}</b></span></div>`;return}
    if(st.phase==='playing'&&me.to_act){
      const can2=hd&&hd.cards&&hd.cards.length===2&&!hd.doubled;
      ctlE.innerHTML=`<div class="cz-acts"><div class="cz-turnring">${ringHtml(1,46,'cz-ring-turn')}</div><button class="cz-btn green" data-a="hit" type="button">Tirer</button><button class="cz-btn red" data-a="stand" type="button">Rester</button>${can2?`<button class="cz-btn gold" data-a="double" type="button">Doubler</button>`:''}</div>`;return}
    ctlE.innerHTML=`<div class="cz-msg">${st.phase==='playing'?'Les autres joueurs jouent…':(PHN[st.phase]||'')}</div>`;
  };
  ctlE.addEventListener('click',e=>{
    const c=e.target.closest('[data-chip]');if(c){chipSel=+c.dataset.chip;AU.chip();drawCtl(T.st);return}
    if(e.target.closest('[data-bet]')){const b=e.target.closest('[data-bet]');T.act('bj',()=>RPC('bj_bet',{p_table:T.id,p_amount:chipSel}),b).then(()=>AU.chips(2));return}
    const a=e.target.closest('[data-a]');if(a){AU.click();T.act('bja',()=>RPC('bj_action',{p_table:T.id,p_action:a.dataset.a}),a)}
  });
  seatsE.addEventListener('click',e=>{const sit=e.target.closest('[data-sit]');if(sit)T.sit(+sit.dataset.sit,0,0,false)});
  T=tableBase(ctx,'blackjack',{render,light:()=>{}});if(!T)return;bindSide(T,sideE);
  sc.iv(()=>{const l=T.leftMs(),st=T.st;if(!st)return;tmE.textContent=l!=null&&st.phase_total_ms?fmtMs(l):'';const r=$('.cz-ring-turn',ctlE);if(r&&st.phase_total_ms)setRing(r.parentNode,l/st.phase_total_ms)},250);
};

/* ================= ROULETTE ================= */
const RLBET={straight:'Plein',red:'Rouge',black:'Noir',odd:'Impair',even:'Pair',low:'Manque 1-18',high:'Passe 19-36',dozen:'Douzaine',column:'Colonne',split:'Cheval'};
const betLabel=b=>{const k=RLBET[b.kind]||b.kind;return ['straight','dozen','column','split'].includes(b.kind)?k+' '+b.value:k};
V.roulette=function(ctx){
  const {el,sc}=ctx;
  const cells=[];for(let c=0;c<12;c++)for(let r=0;r<3;r++){const n=c*3+(3-r);cells.push(`<button type="button" class="cz-rn ${numCol(n)}" data-k="straight" data-v="${n}" style="grid-column:${c+2};grid-row:${r+1}"><span>${n}</span></button>`)}
  el.innerHTML=`<div class="cz-tview cz-rlv"><div class="cz-tinfo"><span class="ph"></span><span class="tm"></span></div>
   <div class="cz-rlwrap"><div class="cz-rlwheel"><div class="cz-wheelbox">${wheelSvg({nums:true})}<i class="cz-ball"></i></div><div class="cz-rlres"></div><div class="cz-rlhist"></div></div>
   <div class="cz-rlboard"><div class="cz-rgrid"><button type="button" class="cz-rn g zero" data-k="straight" data-v="0"><span>0</span></button>${cells.join('')}
     ${[1,2,3].map(c=>`<button type="button" class="cz-rn out" data-k="column" data-v="${c}" style="grid-column:14;grid-row:${4-c}"><span>2:1</span></button>`).join('')}
     ${[1,2,3].map(d=>`<button type="button" class="cz-rn out" data-k="dozen" data-v="${d}" style="grid-column:${(d-1)*4+2}/span 4;grid-row:4"><span>${['1re','2e','3e'][d-1]} 12</span></button>`).join('')}
     <button type="button" class="cz-rn out" data-k="low" style="grid-column:2/span 2;grid-row:5"><span>1-18</span></button><button type="button" class="cz-rn out" data-k="even" style="grid-column:4/span 2;grid-row:5"><span>Pair</span></button><button type="button" class="cz-rn out red" data-k="red" style="grid-column:6/span 2;grid-row:5"><span>Rouge</span></button><button type="button" class="cz-rn out blk" data-k="black" style="grid-column:8/span 2;grid-row:5"><span>Noir</span></button><button type="button" class="cz-rn out" data-k="odd" style="grid-column:10/span 2;grid-row:5"><span>Impair</span></button><button type="button" class="cz-rn out" data-k="high" style="grid-column:12/span 2;grid-row:5"><span>19-36</span></button>
     </div><div class="cz-rbets"></div></div></div>
   <div class="cz-ctl"></div><div class="cz-tfoot"><div class="cz-hint"></div><div class="cz-sidew"></div></div><div class="cz-logw"></div></div>`;
  guardTbl(el);
  const ctlE=$('.cz-ctl',el),phE=$('.ph',el),tmE=$('.tm',el),sideE=$('.cz-sidew',el),logE=$('.cz-logw',el),resE=$('.cz-rlres',el),histE=$('.cz-rlhist',el),boxE=$('.cz-wheelbox',el),ballE=$('.cz-ball',el),rotE=$('.cz-wh-rot',el),betsE=$('.cz-rbets',el),boardE=$('.cz-rlboard',el);
  let T=null,chipSel=0,split=null,splitMode=false,lastSpin=0,anim=null,lastPay='',idleRot=0,lastPh='';
  const rotSet=a=>rotE&&rotE.setAttribute('transform','rotate('+a.toFixed(2)+')');
  const ballSet=(ang,rad)=>{const t=(ang-90)*Math.PI/180;ballE.style.left=(50+rad*50*Math.cos(t))+'%';ballE.style.top=(50+rad*50*Math.sin(t))+'%'};
  /* roue au repos : rotation lente ; pendant le tour : bille qui ralentit puis tombe dans la case du résultat */
  const spinAnim=(result,dur,elapsed)=>{
    if(anim)sc.stop(anim);const idx=WHEEL.indexOf(result),A=360/37,w0=idleRot,W=14;const pocket=idx*A;
    const wT=w0+W*(dur/1000);const aT=((pocket+wT)%360+360)%360;const rev=6,a0=0;const total=aT-a0-360*rev;
    const t0=performance.now()-elapsed;let dropped=false,last=0;AU.ball(Math.max(1000,dur-elapsed));
    anim=sc.frame(now=>{const t=clamp((now-t0)/dur,0,1);const ease=1-Math.pow(1-t,2.6);
      idleRot=w0+W*(t*dur/1000);rotSet(idleRot);
      const ang=a0+total*ease;const rad=t<.72?.88:(.88-(.88-.76)*Math.pow((t-.72)/.28,1.6));
      const wob=t>.72&&t<.97?Math.sin(t*140)*(1-t)*2.2:0;
      ballSet(ang+wob,rad);const tk=Math.floor(ang/A);if(tk!==last&&t>.55&&t<.98){last=tk;AU.tick&&AU.tick()}
      if(t>.93&&!dropped){dropped=true;AU.ballDrop()}
      if(t>=1){ballSet(aT,.76);anim=null;idleLoop();return false}});
  };
  const idleLoop=()=>{if(anim)return;anim=sc.frame(()=>{if(sc.dead)return false;idleRot+=.12;rotSet(idleRot);if(lastBallRest!=null)ballSet(((WHEEL.indexOf(lastBallRest)*360/37+idleRot)%360),.76)});};
  let lastBallRest=null;
  const render=(st)=>{
    const me=st.me||{};phE.textContent=PHN[st.phase]||st.phase;
    histE.innerHTML=(st.history||[]).slice(-14).reverse().map(n=>`<i class="${numCol(n)}">${n}</i>`).join('');
    if(st.phase==='betting'){ballE.style.opacity=0;lastBallRest=null;if(!anim)idleLoop()}else ballE.style.opacity=1;
    const sp=st.spin;
    if(st.phase==='spinning'&&sp&&sp.id!==lastSpin&&st.result!=null){lastSpin=sp.id;lastBallRest=st.result;resE.textContent='';spinAnim(st.result,sp.duration_ms,Math.max(0,sp.duration_ms-(st.phase_left_ms==null?sp.duration_ms:st.phase_left_ms)))}
    if(st.phase==='result'&&st.result!=null){
      if(lastBallRest!==st.result){lastBallRest=st.result;if(anim){sc.stop(anim);anim=null}ballSet(((WHEEL.indexOf(st.result)*360/37+idleRot)%360),.76);idleLoop()}
      resE.innerHTML=`<span class="${numCol(st.result)}">${st.result}</span>`;
      const k=st.round+':'+st.result;if(lastPay!==k){lastPay=k;const lp=num(st.last_payout);if(me.seat!=null&&lp>0){AU.win(lp>=num(st.totals&&st.totals.mine)*10);FX.coinRain(Math.min(70,20+lp/(st.table.min_bet||1)));FX.float(resE,'+'+nf(lp),'win')}else if(me.seat!=null&&num(st.totals&&st.totals.mine)>0)AU.lose()}
    }else if(st.phase!=='spinning')resE.textContent='';
    if(lastPh!==st.phase&&st.phase==='betting'){AU.chip()}lastPh=st.phase;
    // mises posées
    const mb=me.bets||[];const by={};mb.forEach(b=>{const key=b.kind+':'+(b.value||'');by[key]=(by[key]||0)+num(b.amount)});
    $$('.cz-rn',boardE).forEach(b=>{const key=b.dataset.k+':'+(b.dataset.v||'');const a=by[key];let m=b.querySelector('.cz-mk');if(a){if(!m){m=D.createElement('i');m.className='cz-mk';b.appendChild(m)}m.textContent=nf(a);m.style.setProperty('--c',(DEN.find(d=>d[0]<=a)||DEN[9])[1])}else if(m)m.remove();b.classList.toggle('hit',st.result!=null&&st.phase==='result'&&((b.dataset.k==='straight'&&+b.dataset.v===st.result)))});
    const splits=mb.filter(b=>b.kind==='split');betsE.innerHTML=`<div class="cz-rtot">Vos mises : <b>${nfl(num(st.totals&&st.totals.mine))}</b> · Table : ${nf(num(st.totals&&st.totals.table))}</div>${splits.length?`<div class="cz-rsp">${splits.map(b=>`<span>${betLabel(b)} <b>${nf(b.amount)}</b></span>`).join('')}</div>`:''}`;
    sideE.innerHTML=sideBar(T,st);logE.innerHTML=logHtml(st);drawCtl(st);
  };
  const drawCtl=(st)=>{
    const me=st.me||{},tb=st.table;
    if(me.seat==null){ctlE.innerHTML=`<div class="cz-msg"><button class="cz-btn gold" data-join type="button">Prendre place à la table</button> Mise ${nf(tb.min_bet)} à ${nf(tb.max_bet)}</div>`;return}
    const vals=chipValues(tb.min_bet,tb.max_bet);if(!vals.includes(chipSel))chipSel=vals.find(v=>v>=tb.min_bet)||vals[0];
    const open=st.phase==='betting';
    ctlE.innerHTML=`<div class="cz-acts"><div class="cz-chbtns">${vals.map(v=>`<button type="button" class="cz-chipb ${v===chipSel?'on':''}" data-chip="${v}">${chipBtn(v)}</button>`).join('')}</div>
     <button class="cz-btn ghost sm ${splitMode?'on':''}" data-split type="button" ${open?'':'disabled'}>Cheval${split?' : '+split+' + ?':''}</button><button class="cz-btn ghost sm" data-clear type="button" ${open?'':'disabled'}>Retirer mes mises</button><span class="cz-msg2">${open?'Cliquez sur la table pour miser':(PHN[st.phase]||'')}</span></div>`;
  };
  const adj=(a,b)=>{if(a===0||b===0)return a!==b&&Math.max(a,b)<=3;const ra=Math.floor((a-1)/3),rb=Math.floor((b-1)/3),ca=(a-1)%3,cb=(b-1)%3;return (ra===rb&&Math.abs(ca-cb)===1)||(ca===cb&&Math.abs(ra-rb)===1)};
  boardE.addEventListener('click',e=>{
    const b=e.target.closest('.cz-rn');if(!b||!T.st||T.st.me.seat==null)return;if(T.st.phase!=='betting'){say('Les mises sont fermées');return}
    let k=b.dataset.k,v=b.dataset.v||'';
    if(splitMode&&k==='straight'){const n=+v;if(split==null){split=n;AU.click();drawCtl(T.st);return}if(split===n){split=null;drawCtl(T.st);return}
      if(!adj(split,n)){say('Ces deux numéros ne sont pas voisins');return}k='split';v=Math.min(split,n)+'-'+Math.max(split,n);split=null;splitMode=false}
    AU.chip();const amt=chipSel;
    T.act('rlb',()=>RPC('roulette_bet',{p_table:T.id,p_kind:k,p_value:v,p_amount:amt}));
  });
  ctlE.addEventListener('click',e=>{
    if(e.target.closest('[data-join]')){T.sit(null,0,0,false);return}
    const c=e.target.closest('[data-chip]');if(c){chipSel=+c.dataset.chip;AU.chip();drawCtl(T.st);return}
    if(e.target.closest('[data-split]')){splitMode=!splitMode;split=null;drawCtl(T.st);return}
    if(e.target.closest('[data-clear]')){T.act('rlc',()=>RPC('roulette_clear',{p_table:T.id})).then(()=>AU.chips(2))}
  });
  T=tableBase(ctx,'roulette',{render,light:()=>{}});if(!T)return;bindSide(T,sideE);
  ballE.style.opacity=0;idleLoop();
  sc.iv(()=>{const l=T.leftMs(),st=T.st;if(!st)return;tmE.textContent=l!=null?fmtMs(l):''},250);
};

/* ================= MACHINES A SOUS ================= */
V.slots=function(ctx){
  const {el,sc}=ctx;const id=ctx.arg&&ctx.arg.id;if(!id){go('hall');return}
  ctx.title=(ctx.arg&&ctx.arg.name)||'Machine à sous';ctx.back='hall';
  el.innerHTML=`<div class="cz-slotv"><div class="cz-cab"><div class="cz-marq"><span>${E(ctx.title)}</span>${Array.from({length:14},(_,i)=>`<i style="--i:${i}"></i>`).join('')}</div>
    <div class="cz-reelwin"><div class="cz-reels">${[0,1,2].map(()=>`<div class="cz-reel"><div class="cz-strip"></div></div>`).join('')}</div><div class="cz-payl"></div></div>
    <div class="cz-slotinfo"><div class="cz-swin"><span>Gain</span><b>0</b></div><div class="cz-sbet"><span>Mise</span><b></b></div></div>
    <div class="cz-slotctl"><div class="cz-bets"></div><button class="cz-btn gold big cz-spinbtn" type="button">Lancer</button></div></div>
    <div class="cz-lever" title="Tirer le levier"><i class="cz-ball2"></i><i class="cz-rod"></i><i class="cz-base"></i></div>
    <button class="cz-btn ghost sm cz-paybtn" type="button">${ico('info',15)} Table des gains</button></div>`;
  const stripE=$$('.cz-strip',el),reelE=$$('.cz-reel',el),winE=$('.cz-swin b',el),betE=$('.cz-sbet b',el),betsE=$('.cz-bets',el),spinB=$('.cz-spinbtn',el),lever=$('.cz-lever',el),paylE=$('.cz-payl',el);
  let info=null,bet=0,grid=[['cherry','lemon','bell'],['bar','seven','lemon'],['bell','cherry','star']],busyS=false,auto=false;
  const pool=['cherry','lemon','bell','bar','seven','star','diamond','joker'];
  const cell=s=>`<div class="cz-cellS">${symSvg(s)}</div>`;
  const setGrid=g=>{g.forEach((col,i)=>{stripE[i].style.transition='none';stripE[i].style.transform='translateY(0)';stripE[i].innerHTML=col.map(cell).join('')});grid=g};
  setGrid(grid);
  const drawBets=()=>{betsE.innerHTML=(info?info.bets:[]).filter(b=>b>=info.min_bet&&b<=info.max_bet).map(b=>`<button type="button" class="cz-chipb ${b===bet?'on':''}" data-b="${b}">${chipBtn(b)}</button>`).join('');betE.textContent=nfl(bet)};
  const spinReels=(res)=>new Promise(done=>{
    AU.reelStart(1900);const cs=reelE[0].clientHeight/3;
    res.forEach((col,i)=>{
      const n=14+i*6;const seq=[];for(let k=0;k<n;k++)seq.push(pick(pool));
      const full=[...grid[i],...seq,...col];const st=stripE[i];
      st.style.transition='none';st.style.transform='translateY(0)';st.innerHTML=full.map(cell).join('');
      void st.offsetWidth;const dur=1100+i*430;
      st.style.transition=`transform ${dur}ms cubic-bezier(.2,.75,.25,1.04)`;st.style.transform=`translateY(${-(full.length-3)*cs}px)`;
      reelE[i].classList.add('blur');sc.to(()=>{reelE[i].classList.remove('blur');AU.reelStop();reelE[i].classList.add('thud');sc.to(()=>reelE[i].classList.remove('thud'),260);if(i===2){grid=res;sc.to(done,160)}},dur);
    });
  });
  const showWin=(r)=>{
    const L=(info&&info.paylines)||[];const cells=new Set();
    (r.lines||[]).forEach(l=>{const pl=L[l.line-1];if(!pl)return;for(let k=0;k<(l.n||3);k++){const [row,col]=pl[k];cells.add(col+':'+row)}});
    reelE.forEach((rl,c)=>{$$('.cz-cellS',rl).forEach((cl,row)=>{if(cells.has(c+':'+row))cl.classList.add('hit')})});
    if(r.lines&&r.lines.length)paylE.innerHTML=r.lines.map(l=>`<span>Ligne ${l.line} : ${nf(l.pay)}</span>`).join('');
  };
  const clearWin=()=>{$$('.cz-cellS.hit',el).forEach(c=>c.classList.remove('hit'));paylE.innerHTML=''};
  const countUp=(to,ms)=>{const t0=performance.now();const h=sc.frame(n=>{const k=clamp((n-t0)/ms,0,1);winE.textContent=nfl(Math.round(to*k*10)/10);if(k>=1)return false})};
  const doSpin=async()=>{
    if(busyS||!info)return;busyS=true;spinB.disabled=true;clearWin();winE.textContent='0';AU.lever();lever.classList.add('pull');sc.to(()=>lever.classList.remove('pull'),600);
    let r;
    try{r=await RPC('slots_spin',{p_machine:id,p_bet:bet})}catch(e){say(EM(e));busyS=false;spinB.disabled=false;auto=false;return}
    if(sc.dead)return;setBal(r.balance);
    await spinReels(r.reels);if(sc.dead)return;
    if(r.win>0){showWin(r);countUp(r.win,900);if(r.big){AU.jackpot();FX.coinRain(90);FX.confetti(60);FX.flash('#ffd24a')}else{AU.win(r.win>=bet*5);FX.coinRain(Math.min(50,12+r.win/bet*3|0))}el.classList.add('cz-flashwin');sc.to(()=>el.classList.remove('cz-flashwin'),1400)}
    else AU.lose&&AU.lose();
    busyS=false;spinB.disabled=false;
    if(Z.bal!=null&&Z.bal<bet){say('Solde insuffisant pour cette mise');auto=false}
  };
  spinB.onclick=doSpin;lever.onclick=doSpin;
  betsE.onclick=e=>{const b=e.target.closest('[data-b]');if(!b||busyS)return;bet=+b.dataset.b;AU.chip();drawBets()};
  $('.cz-paybtn',el).onclick=()=>{
    if(!info)return;
    dlg(`<h3>Table des gains</h3><p>Gains par ligne gagnante, multiples de la mise totale. 5 lignes : 3 horizontales et 2 diagonales. Le joker remplace tout sauf le diamant.</p><div class="cz-paytbl">${info.symbols.map(s=>`<div>${symSvg(s.code)}<b>${E(s.label)}</b><span>${s.pays&&s.pays['3']!=null?'x3 : '+s.pays['3']+' fois':''}${s.pays&&s.pays['2']!=null?'<br>x2 : '+s.pays['2']+' fois':''}</span></div>`).join('')}</div><div class="cz-dlg-btn"><button class="cz-btn gold" data-x type="button">Fermer</button></div>`,{cls:'wide'});
  };
  RPC('slots_info',{p_machine:id}).then(i=>{if(sc.dead)return;info=i;const ok=i.bets.filter(b=>b>=i.min_bet&&b<=i.max_bet);bet=ok.includes(+lsGet('cz_bet'))?+lsGet('cz_bet'):(ok[1]||ok[0]||i.min_bet);drawBets()}).catch(e=>{say(EM(e));go('hall')});
  const oldDraw=drawBets;betsE.addEventListener('click',()=>lsSet('cz_bet',String(bet)));
  refreshBal();
};

/* ================= LOT-AU-MAX! ================= */
const ZN={zim:'Zimemberg',tan:'Tanhgokrom',tom:'Tomateeom',pou:'Poutinà'};
const ZSUB={zim:'20 caractères · la télé du casino',tan:'15 caractères · tirage mensuel',tom:'12 caractères · 3 symboles identiques',pou:'50 chiffres · puzzle de points'};
const bagSvg=(n,holo)=>`<svg class="cz-bagsvg" viewBox="0 0 120 150"><defs><linearGradient id="cbg${n}" x1="0" x2="1"><stop offset="0" stop-color="#ffffff" stop-opacity=".55"/><stop offset=".4" stop-color="#cfe6ff" stop-opacity=".18"/><stop offset="1" stop-color="#ffffff" stop-opacity=".4"/></linearGradient></defs>
<path d="M14 18h92l6 126H8z" fill="#9fc6e8" fill-opacity=".35" stroke="#dcefff" stroke-width="2"/><path d="M14 18h92l6 126H8z" fill="url(#cbg${n})"/>
<g transform="rotate(-4 60 84)"><rect x="26" y="36" width="68" height="92" rx="4" fill="#f5e9c9" stroke="#b88a2a" stroke-width="1.5"/><rect x="26" y="36" width="68" height="16" fill="#c4122f"/><text x="60" y="48" text-anchor="middle" font-size="9" font-weight="900" fill="#ffe9a3" font-family="Georgia,serif">LOT-AU-MAX!</text><circle cx="60" cy="86" r="18" fill="#e5b02c" stroke="#8d610a"/><text x="60" y="92" text-anchor="middle" font-size="18" font-weight="900" fill="#6e4c05" font-family="Georgia,serif">$</text>${holo?'<rect x="82" y="36" width="8" height="92" fill="url(#czg-holo)" opacity=".85"/>':''}</g>
<path d="M10 24h100v8H10z" fill="#fff" fill-opacity=".5"/><path d="M10 28l5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2 5-2 5 2" fill="none" stroke="#ffffffaa" stroke-width="1.5"/><path d="M22 40l10 100" stroke="#fff" stroke-opacity=".5" stroke-width="3"/></svg>`;
const lotErr=e=>say(EM(e));
const lotLoad=async()=>{const l=await RPC('lot_list');return Array.isArray(l)?l:[]};

/* ---- guichet ---- */
V.guichet=function(ctx){
  const {el,sc}=ctx;ctx.title='Guichet Lot-Au-MAX!';
  el.innerHTML=`<div class="cz-lotv cz-guich"><div class="cz-gwin"><div class="cz-gsign">Lot-Au-MAX!</div><div class="cz-gcounter"><div class="cz-prn"><i class="cz-prslot"></i><div class="cz-prt"></div></div><div class="cz-gcard"><h3>Billet à gratter</h3><div class="cz-gprice">${symbolCoin}<b>…</b></div><p>Quatre jeux sur le même billet : Zimemberg, Tanhgokrom, Tomateeom et Poutinà. Le prix dépend de la richesse moyenne des joueurs. 70 % du prix alimente la cagnotte du cochon.</p><button class="cz-btn gold big" data-buy type="button">Acheter un billet</button><div class="cz-gmsg"></div></div></div></div></div>`;
  const pr=$('.cz-gprice b',el),msg=$('.cz-gmsg',el),prt=$('.cz-prt',el);let price=0,pot=0;
  const load=async()=>{try{const i=await RPC('lot_info');if(sc.dead)return;price=i.price;pot=i.pot;pr.textContent=nfl(price)}catch(e){lotErr(e)}};
  load();refreshBal();
  $('[data-buy]',el).onclick=async e=>{
    const b=e.currentTarget;
    if(Z.bal!=null&&Z.bal<price){say('Solde insuffisant');return}
    const ok=await ask('Acheter un billet','Prix : <b>'+nfl(price)+'</b> jetons.','Acheter');if(!ok)return;
    await act('lotbuy',async()=>{
      const r=await RPC('lot_buy');if(sc.dead)return;setBal(r.balance);AU.coin&&AU.coin();AU.printer(2.2);
      msg.textContent='';prt.innerHTML=`<div class="cz-pticket"><b>LOT-AU-MAX!</b><span>${E(r.ticket)}</span></div>`;
      await sleep(2300);if(sc.dead)return;AU.bag();
      prt.innerHTML=`<div class="cz-dropbag">${bagSvg('g'+Date.now()%1000,true)}<em>${E(r.ticket)}</em></div>`;FX.burst(prt,16,'#ffd24a');
      msg.innerHTML=`Billet <b>${E(r.ticket)}</b> ajouté à votre inventaire, dans un sac. <button class="cz-btn ghost sm" data-my type="button">Mes billets</button>`;
      await load();
    },b);
  };
  el.addEventListener('click',e=>{if(e.target.closest('[data-my]'))go('tickets')});
};

/* ---- billet à gratter : rendu ---- */
function symCell(c){
  const s=String(c==null?'':c);
  if(/aucun|none/i.test(s))return `<div class="cz-tcell none"><svg viewBox="0 0 24 24" width="34" height="34" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg><b>Aucun</b></div>`;
  if(/gratuit|free|ticket|billet/i.test(s))return `<div class="cz-tcell free">${ico('ticket',34)}<b>Billet gratuit</b></div>`;
  const n=+s.replace(/\D/g,'');return `<div class="cz-tcell tok"><i class="cz-bigchip" style="--c:${(DEN.find(d=>d[0]<=n)||DEN[9])[1]}"><b>${n>=1000?(n/1000)+'k':n}</b></i><b>${nfl(n)}</b></div>`;
}
function zoneContent(z,d){
  if(!d)return '<div class="cz-ztx"></div>';
  if(z==='zim')return `<div class="cz-code" data-code="${E(d.code)}">${codeGroups(d.code).split(' ').map(g=>`<span>${E(g)}</span>`).join('')}</div>`;
  if(z==='tan')return `<div class="cz-code">${codeGroups(d.code).split(' ').map(g=>`<span>${E(g)}</span>`).join('')}</div>`;
  if(z==='tom')return `<div class="cz-code sm">${String(d.code).replace(/(.{4})/g,'$1 ').trim().split(' ').map(g=>`<span>${E(g)}</span>`).join('')}</div><div class="cz-tcells">${(d.cells||[]).map(symCell).join('')}</div>`;
  const c=String(d.code||'');return `<div class="cz-code pou">${(c.match(/.{1,10}/g)||[]).map(g=>`<span>${E(g)}</span>`).join('')}</div><div class="cz-poub">${d.done?'<em>Puzzle déjà tenté</em>':'<button class="cz-btn gold sm" data-pou type="button">Jouer au puzzle</button>'}</div>`;
}

/* ---- grattage ---- */
function scratchLayer(box,sc,o){
  const cv=D.createElement('canvas');cv.className='cz-scv';box.appendChild(cv);
  const coin=D.createElement('i');coin.className='cz-coinc';box.appendChild(coin);
  const dpr=Math.min(2,window.devicePixelRatio||1);let w=0,h=0,ctx2=null,down=false,moves=0,first=false,gone=false,lx=0,ly=0,lt=0;
  const paint=()=>{w=box.clientWidth;h=box.clientHeight;if(!w||!h)return;cv.width=w*dpr;cv.height=h*dpr;ctx2=cv.getContext('2d',{willReadFrequently:true});ctx2.scale(dpr,dpr);
    const g=ctx2.createLinearGradient(0,0,w,h);g.addColorStop(0,'#8f98a6');g.addColorStop(.3,'#e4e8ee');g.addColorStop(.55,'#9aa3b1');g.addColorStop(.8,'#dfe3ea');g.addColorStop(1,'#7e8795');ctx2.fillStyle=g;ctx2.fillRect(0,0,w,h);
    ctx2.globalAlpha=.16;for(let i=0;i<260;i++){ctx2.fillStyle=Math.random()<.5?'#fff':'#333';ctx2.fillRect(Math.random()*w,Math.random()*h,Math.random()*18+2,1)}ctx2.globalAlpha=1;
    ctx2.fillStyle='#4b5260';ctx2.font='800 '+Math.max(13,Math.min(22,w/14))+'px Georgia,serif';ctx2.textAlign='center';ctx2.textBaseline='middle';ctx2.fillText('GRATTEZ ICI',w/2,h/2);};
  paint();const ro=typeof ResizeObserver!=='undefined'?new ResizeObserver(()=>{if(!first&&!gone)paint()}):null;if(ro){ro.observe(box);sc.onEnd(()=>ro.disconnect())}
  const pos=e=>{const r=cv.getBoundingClientRect();return [e.clientX-r.left,e.clientY-r.top]};
  const clearPct=()=>{try{const s=ctx2.getImageData(0,0,cv.width,cv.height).data;let n=0,t=0;for(let i=3;i<s.length;i+=4*37){t++;if(s[i]<40)n++}return n/t}catch(e){return 0}};
  const reveal=()=>{if(gone)return;gone=true;cv.classList.add('gone');coin.style.display='none';o.onClear&&o.onClear()};
  cv.addEventListener('pointerdown',e=>{if(gone)return;down=true;try{cv.setPointerCapture(e.pointerId)}catch(_){}[lx,ly]=pos(e);lt=performance.now();AU.unlock();
    if(!first){first=true;o.onFirst&&o.onFirst()}coin.style.display='block';coin.style.transform=`translate(${lx-16}px,${ly-16}px) rotate(-20deg)`;e.preventDefault()});
  cv.addEventListener('pointermove',e=>{if(gone)return;const [x,y]=pos(e);coin.style.display='block';coin.style.transform=`translate(${x-16}px,${y-16}px) rotate(${down?-35:-20}deg)`;if(!down)return;
    ctx2.globalCompositeOperation='destination-out';ctx2.lineCap='round';ctx2.lineWidth=30;ctx2.beginPath();ctx2.moveTo(lx,ly);ctx2.lineTo(x,y);ctx2.stroke();ctx2.globalCompositeOperation='source-over';
    const n=performance.now(),v=Math.hypot(x-lx,y-ly)/Math.max(1,n-lt);if(n-lt>40){AU.scratch(clamp(v,0,2));lt=n}lx=x;ly=y;moves++;if(moves%10===0&&clearPct()>.5)reveal()});
  const up=()=>{down=false;if(first&&moves>3&&clearPct()>.45)reveal()};
  cv.addEventListener('pointerup',up);cv.addEventListener('pointercancel',up);cv.addEventListener('pointerleave',()=>{coin.style.display='none'});
  return {reveal:()=>{cv.classList.add('gone');gone=true;coin.style.display='none'}};
}

/* ---- puzzle Poutinà ---- */
const POUC=['#ff3b3b','#2f8bff','#25c46a','#ffd21f','#b24bff','#ff8a1f','#00d1d1','#ff4fa8','#a0e12a','#8d6a4a','#e9e9ef'];
function pouGame(tk,pz,onDone){
  const n=pz.n,pairs=pz.pairs,cols=pz.colors;
  const pt={};pairs.forEach(p=>{pt[p.a[0]+','+p.a[1]]={c:p.c,end:'a'};pt[p.b[0]+','+p.b[1]]={c:p.c,end:'b'}});
  const paths=Array.from({length:cols},()=>[]),start=new Array(cols).fill(null),done=new Array(cols).fill(false);
  const occ={};let cur=-1,submitted=false;
  const d=dlg(`<h3>Poutinà · ${tk}</h3><p>Reliez chaque paire de points de même couleur. Les traits ne se croisent pas et <b>sont indélébiles</b> : impossible de les effacer. Un seul essai.</p><div class="cz-pouwrap"><svg class="cz-pou" viewBox="0 0 ${n} ${n}"></svg></div><div class="cz-poust"></div><div class="cz-dlg-btn"><button class="cz-btn ghost" data-x type="button">Fermer</button><button class="cz-btn gold" data-sub type="button">Valider (essai unique)</button></div>`,{cls:'wide',lock:true});
  if(!d)return;const svg=$('.cz-pou',d),st=$('.cz-poust',d);
  const draw=()=>{let h='';for(let i=0;i<=n;i++)h+=`<path d="M${i} 0V${n}M0 ${i}H${n}" stroke="#ffffff22" stroke-width=".03"/>`;
    paths.forEach((p,c)=>{if(p.length>1)h+=`<polyline points="${p.map(q=>(q[1]+.5)+','+(q[0]+.5)).join(' ')}" fill="none" stroke="${POUC[c%POUC.length]}" stroke-width=".42" stroke-linecap="round" stroke-linejoin="round" opacity=".92"/>`});
    pairs.forEach(p=>{[p.a,p.b].forEach(q=>{h+=`<circle cx="${q[1]+.5}" cy="${q[0]+.5}" r=".3" fill="${POUC[p.c%POUC.length]}" stroke="#fff" stroke-width=".05"/>`})});
    svg.innerHTML=h;const dn=done.filter(Boolean).length;st.textContent=`Reliées : ${dn} / ${cols}`};
  draw();
  const cellAt=e=>{const r=svg.getBoundingClientRect();const x=Math.floor((e.clientX-r.left)/r.width*n),y=Math.floor((e.clientY-r.top)/r.height*n);if(x<0||y<0||x>=n||y>=n)return null;return [y,x]};
  svg.addEventListener('pointerdown',e=>{if(submitted)return;const q=cellAt(e);if(!q)return;const k=q[0]+','+q[1];
    const p=pt[k];
    if(p&&!done[p.c]&&paths[p.c].length===0){cur=p.c;start[cur]=p.end;paths[cur]=[q];occ[k]=cur;AU.click();draw();try{svg.setPointerCapture(e.pointerId)}catch(_){}}
    else{for(let c=0;c<cols;c++){const pp=paths[c];if(!done[c]&&pp.length&&pp[pp.length-1][0]===q[0]&&pp[pp.length-1][1]===q[1]){cur=c;try{svg.setPointerCapture(e.pointerId)}catch(_){}break}}}
    e.preventDefault()});
  svg.addEventListener('pointermove',e=>{if(cur<0||submitted)return;const q=cellAt(e);if(!q)return;const pp=paths[cur],t=pp[pp.length-1];if(q[0]===t[0]&&q[1]===t[1])return;
    if(Math.abs(q[0]-t[0])+Math.abs(q[1]-t[1])!==1)return;const k=q[0]+','+q[1];
    if(occ[k]!=null)return;const p=pt[k];
    if(p){if(p.c!==cur||p.end===start[cur])return;pp.push(q);occ[k]=cur;done[cur]=true;cur=-1;AU.pop();FX.burst(svg,6,POUC[p.c%POUC.length])}
    else{pp.push(q);occ[k]=cur;AU.tick&&AU.tick()}
    draw()});
  const stop=()=>{cur=-1};svg.addEventListener('pointerup',stop);svg.addEventListener('pointercancel',stop);
  $('[data-sub]',d).onclick=async()=>{
    if(submitted)return;const left=cols-done.filter(Boolean).length;
    const ok=await ask('Valider le puzzle',left?`Il reste <b>${left}</b> paire(s) non reliée(s). Vous n’aurez plus d’autre essai.`:'Vous n’aurez plus d’autre essai.','Valider',{danger:!!left});if(!ok)return;
    submitted=true;
    try{const out=paths.map((p,c)=>start[c]==='b'?p.slice().reverse():p);const r=await RPC('lot_pou_submit',{p_ticket:tk,p_paths:out});
      if(r.valid){AU.jackpot();FX.confetti(60);st.innerHTML='<b class="ok">Puzzle résolu ! Passez à la banque de ticket.</b>'}else{AU.lose();st.innerHTML='<b class="ko">Raté : le puzzle est définitivement perdu.</b>'}
      onDone&&onDone(r)}catch(e){submitted=false;lotErr(e)}
  };
}

/* ---- mes billets ---- */
V.tickets=function(ctx){
  const {el,sc}=ctx;ctx.title='Mes billets';ctx.back='hall';
  const arg=ctx.arg||{};
  if(arg.ticket){detail(ctx,arg.ticket);return}
  el.innerHTML=`<div class="cz-lotv"><div class="cz-tkhead"><h2>Mes billets Lot-Au-MAX!</h2><p>Ouvrez le sac, dépliez le billet, grattez les 4 zones avec la pièce, puis rendez-vous à la télé, au scanner ou à la banque de ticket.</p></div><div class="cz-tklist"><div class="cz-muted">Chargement…</div></div></div>`;
  const listE=$('.cz-tklist',el);
  const draw=async()=>{let L;try{L=await lotLoad()}catch(e){lotErr(e);return}if(sc.dead)return;
    listE.innerHTML=L.length?L.map(t=>`<div class="cz-tki ${t.opened?'open':'sealed'}" data-t="${E(t.ticket)}"><div class="cz-tkart">${t.opened?miniTicket(t):bagSvg(hashStr(t.ticket)%99,t.holo)}</div><b>${E(t.ticket)}</b><span class="cz-tkst">${t.claimed?'Réclamé':(t.opened?(Object.values(t.scratched||{}).filter(Boolean).length+' / 4 grattées'):'Sac fermé')}</span><div class="cz-tkb"><button class="cz-btn gold sm" data-o type="button">${t.opened?'Ouvrir le billet':'Ouvrir le sac'}</button><button class="cz-btn ghost sm" data-d type="button" title="Jeter">${ico('trash',16)}</button></div></div>`).join(''):`<div class="cz-empty">${ico('ticket',40)}<p>Aucun billet. Passez au guichet.</p><button class="cz-btn gold" data-g type="button">Aller au guichet</button></div>`};
  draw();
  el.addEventListener('click',async e=>{
    if(e.target.closest('[data-g]')){go('guichet');return}
    const it=e.target.closest('.cz-tki');if(!it)return;const tk=it.dataset.t;
    if(e.target.closest('[data-d]')){const ok=await ask('Jeter ce billet','Le billet <b>'+E(tk)+'</b> sera détruit définitivement, avec ses gains éventuels.','Jeter',{danger:true});if(!ok)return;await act('disc'+tk,async()=>{await RPC('lot_discard',{p_ticket:tk});AU.fold();await draw()});return}
    await act('open'+tk,async()=>{
      if(!it.classList.contains('open')){it.classList.add('tearing');AU.bag();await RPC('lot_open',{p_ticket:tk});await sleep(700)}
      go('tickets',{ticket:tk});
    });
  });
};
function miniTicket(t){const h=hashStr(t.ticket)%360;return `<div class="cz-mini" style="--h:${h}"><b>LOT-AU-MAX!</b>${t.holo?'<i class="cz-holo"></i>':''}<div class="cz-mz">${['zim','tan','tom','pou'].map(z=>`<i class="${t.scratched&&t.scratched[z]?'on':''}"></i>`).join('')}</div></div>`}

async function detail(ctx,tk){
  const {el,sc}=ctx;ctx.back='tickets';ctx.title='Billet '+tk;
  let L;try{L=await lotLoad()}catch(e){lotErr(e);go('tickets');return}if(sc.dead)return;
  const t=L.find(x=>x.ticket===tk);if(!t){say('Billet introuvable');go('tickets');return}
  const h=hashStr(tk+(t.seed||0))%360;
  const zones=['zim','tan','tom','pou'];
  el.innerHTML=`<div class="cz-lotv"><div class="cz-tkwrap"><div class="cz-ticket" style="--h:${h}">
    <div class="cz-tkhd"><div class="cz-tkbrand"><span>LOT-AU-MAX!</span><em>Le billet qui gratte fort</em></div><div class="cz-tkno">${E(tk)}</div>${t.holo?'<div class="cz-holo big" title="Bande holographique"></div>':''}</div>
    ${zones.map((z,i)=>`<div class="cz-fold" data-i="${i}"><div class="cz-foldin"><div class="cz-zhead"><b>${ZN[z]}</b><span>${ZSUB[z]}</span></div><div class="cz-zbox" data-z="${z}"><div class="cz-zrev"></div></div></div><i class="cz-crease"></i></div>`).join('')}
    <div class="cz-tkft"><span>Lot-Au-MAX! · billet ${E(tk)}</span><span class="cz-perf"></span></div></div>
    <div class="cz-tkact"><button class="cz-btn gold" data-unfold type="button">Déplier le billet</button><button class="cz-btn ghost" data-tv type="button">Télé Zimemberg</button><button class="cz-btn ghost" data-bk type="button">Banque de ticket</button><button class="cz-btn ghost" data-ds type="button">${ico('trash',16)} Jeter</button></div></div></div>`;
  const folds=$$('.cz-fold',el),act1=$('[data-unfold]',el);let opened=0;const data={};
  const unfoldNext=()=>{if(opened>=4)return;folds[opened].classList.add('open');AU.fold();opened++;if(opened>=4){act1.hidden=true;initZones()}else act1.textContent='Déplier le pli suivant ('+opened+'/4)'};
  act1.onclick=unfoldNext;
  folds.forEach((f,i)=>f.addEventListener('click',e=>{if(!f.classList.contains('open')&&i===opened)unfoldNext()}));
  let zoneInit=false;
  const reveal=(z,d)=>{data[z]=d;const b=$('.cz-zbox[data-z="'+z+'"] .cz-zrev',el);if(b)b.innerHTML=zoneContent(z,d)};
  const fetchZ=async z=>{if(data[z])return data[z];const d=await RPC('lot_scratch',{p_ticket:tk,p_zone:z});reveal(z,d);return d};
  function initZones(){
    if(zoneInit)return;zoneInit=true;
    zones.forEach(z=>{const box=$('.cz-zbox[data-z="'+z+'"]',el);
      if(t.scratched&&t.scratched[z]){fetchZ(z).catch(lotErr);return}
      scratchLayer(box,sc,{onFirst:()=>{fetchZ(z).catch(e=>{lotErr(e)})},onClear:()=>{AU.pop();FX.burst(box,10,'#ffe9a3')}});
    });
  }
  /* un billet déjà gratté est présenté déplié */
  if(Object.values(t.scratched||{}).some(Boolean)){folds.forEach(f=>f.classList.add('open'));opened=4;act1.hidden=true;initZones()}
  else{el.querySelector('.cz-ticket').classList.add('fresh')}
  el.addEventListener('click',async e=>{
    if(e.target.closest('[data-tv]')){go('tv');return}
    if(e.target.closest('[data-bk]')){go('bank',{ticket:tk});return}
    if(e.target.closest('[data-ds]')){const ok=await ask('Jeter ce billet','Le billet <b>'+E(tk)+'</b> sera détruit définitivement.','Jeter',{danger:true});if(!ok)return;await act('disc',async()=>{await RPC('lot_discard',{p_ticket:tk});go('tickets')});return}
    if(e.target.closest('[data-pou]')){await act('pou',async()=>{const d=await fetchZ('pou');if(d.done){say('Puzzle déjà tenté');return}pouGame(tk,d.puzzle,r=>{t.scratched.pou=true;reveal('pou',Object.assign({},d,{done:true}))})})}
  });
}

/* ---- scanner ---- */
V.scanner=function(ctx){
  const {el,sc}=ctx;ctx.title='Scanner de codes';
  el.innerHTML=`<div class="cz-lotv"><div class="cz-scan"><div class="cz-scanbox"><div class="cz-scanscr"><i class="cz-laser2"></i><div class="cz-scres">Entrez un code de 12, 15, 20 ou 50 caractères.</div></div><input class="cz-in" type="text" inputmode="text" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="60" placeholder="Code du billet"><button class="cz-btn gold big" data-go type="button">Scanner</button></div></div></div>`;
  const inp=$('.cz-in',el),res=$('.cz-scres',el),scr=$('.cz-scanscr',el);
  const go2=async()=>{const code=inp.value.replace(/[\s-]/g,'').toUpperCase();if(!code){say('Entrez un code');return}
    await act('scan',async()=>{scr.classList.add('on');AU.printer(.9);res.textContent='Lecture…';await sleep(900);const r=await RPC('lot_scan',{p_code:code});if(sc.dead)return;scr.classList.remove('on');
      const lab={gagnant:'GAGNANT',perdant:'PERDANT',faux:'FAUX BILLET',attente:'EN ATTENTE',inconnu:'CODE INCONNU'}[r.status]||String(r.status).toUpperCase();
      res.innerHTML=`<div class="cz-sres ${E(r.status)}"><b>${lab}</b>${r.kind?`<span>${E(ZN[r.kind]||r.kind)}${r.ticket?' · '+E(r.ticket):''}</span>`:''}<p>${E(r.note||'')}</p></div>`;
      if(r.status==='gagnant'){AU.win(false);FX.confetti(30)}else if(r.status==='faux')AU.err();else AU.beep();
    });};
  $('[data-go]',el).onclick=go2;inp.addEventListener('keydown',e=>{if(e.key==='Enter')go2()});
  inp.addEventListener('input',()=>{inp.value=inp.value.toUpperCase()});
};

/* ---- banque de ticket ---- */
V.bank=function(ctx){
  const {el,sc}=ctx;ctx.title='Banque de ticket';
  el.innerHTML=`<div class="cz-lotv"><div class="cz-bankv"><div class="cz-bankhd">${ico('bank',34)}<h2>Banque de ticket</h2><p>Présentez un billet : tout ce qui est gagné et non réclamé est payé. Un faux billet est confisqué.</p></div><div class="cz-bkl"><div class="cz-muted">Chargement…</div></div><div class="cz-bkres"></div></div></div>`;
  const listE=$('.cz-bkl',el),resE=$('.cz-bkres',el);
  const draw=async()=>{let L;try{L=await lotLoad()}catch(e){lotErr(e);return}if(sc.dead)return;L=L.filter(t=>t.opened);
    listE.innerHTML=L.length?L.map(t=>`<button class="cz-bkt ${ctx.arg&&ctx.arg.ticket===t.ticket?'pre':''}" data-t="${E(t.ticket)}" type="button">${miniTicket(t)}<b>${E(t.ticket)}</b></button>`).join(''):'<div class="cz-empty"><p>Aucun billet ouvert à présenter.</p></div>'};
  draw();
  listE.addEventListener('click',async e=>{const b=e.target.closest('[data-t]');if(!b)return;const tk=b.dataset.t;
    await act('bank',async()=>{AU.printer(1.4);resE.innerHTML='<div class="cz-muted">Vérification du billet…</div>';await sleep(1200);const r=await RPC('lot_bank',{p_ticket:tk});if(sc.dead)return;setBal(r.balance,r.medals);
      if(r.fake){AU.err();FX.flash('#ff2a2a');resE.innerHTML=`<div class="cz-receipt bad"><h3>Billet confisqué</h3><p>Le billet <b>${E(tk)}</b> est un faux. Il a été retenu par la banque.</p></div>`;await draw();return}
      const it=r.items||[];const tot=it.reduce((s,x)=>s+num(x.tokens),0),md=it.reduce((s,x)=>s+num(x.medals),0);
      resE.innerHTML=`<div class="cz-receipt"><h3>Reçu · ${E(tk)}</h3>${it.length?it.map(x=>`<div class="cz-rl"><span>${E(x.label||ZN[x.kind]||x.kind)}</span><b>${num(x.tokens)?nfl(x.tokens)+' jetons':''}${num(x.medals)?(num(x.tokens)?' · ':'')+nfl(x.medals)+' médaillons':''}${x.free_ticket?(num(x.tokens)||num(x.medals)?' · ':'')+'billet gratuit '+E(x.free_ticket):''}</b></div>`).join(''):'<p>Rien à payer pour ce billet.</p>'}${it.length?`<div class="cz-rl tot"><span>Total</span><b>${nfl(tot)} jetons${md?' + '+nfl(md)+' médaillons':''}</b></div>`:''}</div>`;
      if(tot>0||md>0||it.some(x=>x.free_ticket)){AU.win(tot>=10000);FX.coinRain(Math.min(80,20+tot/200));if(md)FX.confetti(30)}else AU.click();
      await draw();
    });
  });
};

/* ---- télé Zimemberg ---- */
V.tv=function(ctx){
  const {el,sc}=ctx;ctx.title='Télé Zimemberg';
  el.innerHTML=`<div class="cz-lotv"><div class="cz-tvv"><div class="cz-tvbig"><div class="cz-tvbez"><div class="cz-tvscr2"><div class="cz-tvlogo">ZIMEMBERG</div><div class="cz-tvc"></div><div class="cz-tvr"></div><div class="cz-tvl"></div></div><div class="cz-tvled"></div></div><div class="cz-tvfoot2"></div></div>
    <div class="cz-tvpanel"><h3>Réclamer un billet</h3><p>Si le code Zimemberg gratté sur votre billet est <b>identique</b> au code affiché, réclamez le gros lot (100 000 à 500 000 jetons). <b class="cz-warn">Une mauvaise réclamation vous fait perdre TOUS vos jetons.</b></p><div class="cz-tvl2"></div></div></div></div>`;
  const cE=$('.cz-tvc',el),rE=$('.cz-tvr',el),lE=$('.cz-tvl2',el);let codes={},list=[];
  const tick=()=>{const z=zimNow();cE.innerHTML=codeGroups(z.code).split(' ').map(g=>`<span>${E(g)}</span>`).join('');rE.textContent='Prochain code dans '+fmtMs(z.left);
    if(z.left<=0&&!tick.busy){tick.busy=1;getLobby().then(()=>{Z.lobbyAt=performance.now()}).catch(()=>{}).finally(()=>{tick.busy=0})}};
  const draw=async()=>{try{list=(await lotLoad()).filter(t=>t.opened&&t.scratched&&t.scratched.zim&&!t.claimed)}catch(e){lotErr(e);return}
    for(const t of list){if(!codes[t.ticket]){try{const d=await RPC('lot_scratch',{p_ticket:t.ticket,p_zone:'zim'});codes[t.ticket]=d.code}catch(e){}}}
    if(sc.dead)return;
    lE.innerHTML=list.length?list.map(t=>`<div class="cz-tvt"><b>${E(t.ticket)}</b><div class="cz-code sm">${codeGroups(codes[t.ticket]||'').split(' ').map(g=>`<span>${E(g)}</span>`).join('')}</div><button class="cz-btn red sm" data-c="${E(t.ticket)}" type="button">Réclamer</button></div>`).join(''):'<div class="cz-muted">Aucun billet avec la zone Zimemberg grattée. Grattez-la dans « Mes billets ».</div>'};
  getLobby().then(()=>{Z.lobbyAt=performance.now();tick()}).catch(()=>{});tick();draw();sc.iv(tick,500);
  lE.addEventListener('click',async e=>{const b=e.target.closest('[data-c]');if(!b)return;const tk=b.dataset.c;
    const ok=await ask('Réclamer le billet '+tk,'Si le code ne correspond pas exactement à celui affiché maintenant, vous perdez <b>TOUS vos jetons</b>. Êtes-vous certain de vouloir réclamer ?','Je réclame',{danger:true,lock:true});if(!ok)return;
    await act('zim',async()=>{const r=await RPC('lot_zim_claim',{p_ticket:tk});if(sc.dead)return;setBal(r.balance);
      if(r.won){AU.jackpot();FX.coinRain(90);FX.confetti(80);FX.flash('#ffd24a');dlg(`<h3>Gros lot Zimemberg !</h3><p>Vous remportez <b>${nfl(r.prize)}</b> jetons.</p><div class="cz-dlg-btn"><button class="cz-btn gold" data-x type="button">Formidable</button></div>`)}
      else{AU.err();FX.flash('#ff2a2a');dlg(`<h3>Mauvais code</h3><p>Le code ne correspond pas. Vos jetons ont été perdus.</p><div class="cz-dlg-btn"><button class="cz-btn red" data-x type="button">Fermer</button></div>`)}
      await refreshBal();await draw()},b)});
};

/* ---- cochon Tanhgokrom ---- */
V.pig=function(ctx){
  const {el,sc}=ctx;ctx.title='Tanhgokrom';
  el.innerHTML=`<div class="cz-lotv"><div class="cz-pigv"><div class="cz-beam"></div><div class="cz-pigbig"></div><div class="cz-pigsign"><h3>Cagnotte Tanhgokrom</h3><div class="cz-potn">${symbolCoin}<b>…</b></div><div class="cz-cd2"><span>Prochain tirage dans</span><b>…</b></div><p>70 % du prix de chaque billet vendu remplit le cochon. Tirage le 1er de chaque mois à 00:00 GMT : le billet gagnant empoche toute la cagnotte, réclamable à la banque de ticket. Si personne ne gagne, la cagnotte est reportée.</p></div></div></div>`;
  const pot=$('.cz-potn b',el),cd=$('.cz-cd2 b',el),pg=$('.cz-pigbig',el);let info=null,shown=-1;
  const load=async()=>{try{info=await RPC('lot_info');if(sc.dead)return;pot.textContent=nfl(info.pot);const f=pigFill(info.pot);if(f!==shown){shown=f;pigMount(pg,f);if(info.pot>0)AU.coin&&AU.coin()}}catch(e){lotErr(e)}};
  load();sc.iv(load,8000);
  sc.iv(()=>{const e=info?Date.parse(info.period_end):NaN;const end=isFinite(e)&&e>Date.now()?e:nextMonthMs();cd.textContent=fmtLong(end-Date.now())},500);
  pg.addEventListener('click',()=>{pg.classList.remove('shake');void pg.offsetWidth;pg.classList.add('shake');sc.to(()=>pg.classList.remove('shake'),650);AU.coin&&AU.coin();FX.burst(pg,8,'#ffd24a')});
};

/* ---- inventaire du site : section Lot-Au-MAX! ---- */
try{
  if(typeof bmInv==='function'){
    const _bi=bmInv;
    bmInv=async function(box,bal,show){
      await _bi.apply(this,arguments);
      let L=[];try{L=await RPC('lot_list')}catch(e){return}
      if(!box||!box.isConnected)return;
      const sec=D.createElement('div');sec.className='cz-invsec';
      const draw=()=>{sec.innerHTML=`<label>Lot-Au-MAX!</label>${L.length?L.map(t=>`<div class="bdgrow cz-invrow" data-t="${E(t.ticket)}"><span class="grow"><b>${E(t.ticket)}</b> <span class="muted">${t.opened?'billet ouvert':'sac fermé'}${t.claimed?' · réclamé':''}</span></span><button class="ghost lite" data-o type="button">${t.opened?'Gratter':'Ouvrir'}</button><button class="ghost lite" data-d type="button">Jeter</button></div>`).join(''):'<p class="muted">Aucun billet. Ils s’achètent au guichet du casino.</p>'}`};
      draw();box.appendChild(sec);
      sec.addEventListener('click',async e=>{
        const r=e.target.closest('.cz-invrow');if(!r)return;const tk=r.dataset.t;
        if(e.target.closest('[data-o]')){const t=L.find(x=>x.ticket===tk);openCasino({go:'tickets',arg:t&&t.opened?{ticket:tk}:null});return}
        if(e.target.closest('[data-d]')){if(!confirm('Jeter le billet '+tk+' définitivement ?'))return;try{await RPC('lot_discard',{p_ticket:tk});L=L.filter(x=>x.ticket!==tk);draw()}catch(x){say(EM(x))}}
      });
    };
  }
}catch(e){console.warn('casino: inventaire non lié',e)}

window.openCasino=openCasino;
window.CZ={_loaded:true,open:openCasino,close:closeCasino};
})();
