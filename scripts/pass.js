/* pass.js — Communicer Pass et Pass+ (chargé après app.js). Les avantages ne valent que pendant que l'abonnement est actif ;
   le serveur (patch_lot26.sql) décide de tout : ce fichier n'affiche que l'état et appelle les fonctions du serveur. */
(function(){
'use strict';
if(window.__passLoaded)return;window.__passLoaded=1;
window.PASS=window.PASS||{pass:false,plus:false};window.PASSIDS=window.PASSIDS||new Set();
const ready=()=>typeof S!=='undefined'&&S&&S.me&&S.me.id&&typeof sb!=='undefined';
const e2=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const dt=x=>{try{return new Date(x).toLocaleDateString('fr-CA',{year:'numeric',month:'long',day:'numeric'})}catch(e){return ''}};
const money=n=>Number(n).toFixed(2).replace('.',',')+' $';

async function load(){
  if(!ready())return;
  try{const s=await rpcd('pass_state');window.PASS=s;window.PASSERR=null;try{const c=cur();if(c&&typeof msgLim==='function')$('#in').maxLength=msgLim(c)||20000}catch(e){}if(s.pass)window.PASSIDS.add(S.me.id);else window.PASSIDS.delete(S.me.id);
    try{renderList();if(typeof renderHeader==='function')renderHeader()}catch(e){}
  }catch(e){window.PASSERR=(e&&e.message)||'erreur'}
}
/* symbole à côté du surnom des abonnés actifs */
const seen=new Map();
async function fetchIds(ids,force){
  const now=Date.now(),need=[...new Set((ids||[]).filter(Boolean))].filter(i=>force||!seen.has(i)||now-seen.get(i)>300000).slice(0,200);
  if(!need.length)return;need.forEach(i=>seen.set(i,now));
  try{const on=await rpcd('pass_active_ids',{p_ids:need});let ch=false;
    for(const i of need){const had=window.PASSIDS.has(i),has=on.includes(i);if(has&&!had){window.PASSIDS.add(i);ch=true}else if(!has&&had&&i!==(S.me&&S.me.id)){window.PASSIDS.delete(i);ch=true}}
    if(ch){try{renderList();renderMsgs()}catch(e){}}}catch(e){}
}
window.PASSFETCH=fetchIds;
function hookEnsure(){
  if(typeof ensureProfiles!=='function'||ensureProfiles.__p)return;
  const o=ensureProfiles;ensureProfiles=async function(ids){const r=await o.apply(this,arguments);try{fetchIds(Array.isArray(ids)?ids:[...(ids||[])])}catch(e){}return r};ensureProfiles.__p=1;
}

/* fenêtre Pass */
function render(el,done){
  const P=window.PASS||{};const adm=(typeof RK==='function'?RK():0)>=3;
  const li=a=>a.map(t=>`<li>${e2(t)}</li>`).join('');
  const benef=['Accès à une conversation avec CommunicerAI (indisponible pour le moment)','Photos importées en haute qualité, sans compression','Symbole à côté du surnom et badge Pass unique','1 500 jetons par mois','Boutique : 5 % de rabais sur tous les articles','Communicer Lite et épinglage gratuits pendant l’abonnement','Limite de message portée à 200 caractères','Compte protégé contre toute suppression de données du stockage, y compris par un administrateur','Mises à jour en avance (versions bêta)','Casino : 2 % de chance supplémentaire sur tous les jeux','Échange de jetons contre coquelicots','Police personnalisée'];
  const plusB=['Réservé : Nom dans les crédits, Tournois, VAZE++, Équipe e-Sport, Krypto+%!?','Boutique : 20 % de rabais jusqu’à 65 000 jetons d’achat par mois (aucun rabais sur les articles réservés au Pass+)','Les articles achetés avec le Pass+ restent à vous si vous ne renouvelez pas'];
  el.innerHTML=(`<h3 style="margin:0 0 6px">Communicer Pass</h3>${window.PASSERR?`<p class="muted">État du Pass indisponible (${e2(window.PASSERR)}). Vérifiez que patch_lot26.sql a été exécuté.</p>`:''}
   <p>${P.pass?`<b>Actif</b> jusqu’au ${e2(dt(P.until))}.`:'<b>Inactif.</b> Les avantages ci-dessous ne s’appliquent que pendant l’abonnement.'}</p>
   <p class="muted">${money(P.price||6.99)} par mois + ${money(P.storage||2.99)} de frais de stockage = <b>${money(P.total||9.98)}</b> par mois. Les taxes et frais Stripe sont ajoutés au montant lors de la confirmation.</p>
   <h4 style="margin:10px 0 4px">Avantages du Pass</h4><ul style="margin:6px 0 10px 18px">${li(benef)}</ul>
   <div class="row" style="flex-wrap:wrap"><button id="psSub" disabled>S’abonner (paiement bientôt disponible)</button><button class="ghost" id="psAI">CommunicerAI</button>${P.pass?`<button class="ghost" id="psClaim" ${P.claimed?'disabled':''}>${P.claimed?'Jetons du mois déjà réclamés':'Réclamer 1 500 jetons'}</button>`:''}</div>
   <p class="muted" style="font-size:12px">Le paiement par Stripe viendra plus tard. En attendant, le commandant ou un chef des administrateurs peut accorder le Pass ou le Pass+.</p>
   ${P.pass?`<h4 style="margin:12px 0 4px">Jetons vers coquelicots</h4><div class="row"><input id="psMed" type="number" min="1" max="1000" placeholder="Coquelicots voulus" class="grow"><button class="ghost" id="psMedGo">Échanger</button></div><div class="muted" style="font-size:12px">Coût : ${P.rate_med?`${(P.rate_med*1.4).toFixed(2).replace('.',',')} jetons par coquelicot (40 % de plus que l’échange inverse).`:'selon le taux en vigueur.'}</div>`:''}
   <h4 style="margin:12px 0 4px">Communicer Pass+</h4>
   <p>${P.plus?`<b>Actif</b> jusqu’au ${e2(dt(P.plus_until))}. Déjà dépensé ce mois avec rabais : ${Math.round(P.plus_spent||0)} sur ${P.plus_cap||65000}.`:'<b>Inactif.</b>'}</p>
   <ul style="margin:6px 0 10px 18px">${li(plusB)}</ul>
   ${adm?`<h4 style="margin:12px 0 4px">Accorder (commandant et chefs)</h4><div class="row" style="flex-wrap:wrap"><input id="pgU" placeholder="nom d’utilisateur" class="grow"><select id="pgK"><option value="pass">Pass</option><option value="plus">Pass+</option></select><input id="pgN" type="number" min="1" value="1" style="max-width:70px"><select id="pgT"><option value="day">jours</option><option value="month" selected>mois</option><option value="year">ans</option></select></div><div class="row"><button id="pgG">Accorder</button><button class="ghost" id="pgR">Retirer</button></div>`:''}
   `);
  const q=s=>el.querySelector(s),on=(s,f)=>{const b=q(s);if(b)b.onclick=async()=>{try{await f()}catch(e){toast(errMsg(e))}}};
  on('#psAI',async()=>{modal('<h3>CommunicerAI</h3><p>Indisponible pour le moment. Les abonnés Pass y auront accès dès son ouverture.</p><div class="row end"><button data-x>Fermer</button></div>')});
  on('#psClaim',async()=>{await rpcd('pass_claim_month');toast('1 500 jetons ajoutés');try{balRefresh()}catch(e){}await load();if(done)done()});
  on('#psMedGo',async()=>{const n=+q('#psMed').value;const r=await rpcd('pass_tok_to_med',{p_med:n});toast('Échange effectué : '+n+' coquelicot'+(n>1?'s':''));try{balRefresh()}catch(e){}});
  on('#pgG',async()=>{const t=await rpcd('pass_grant',{p_username:q('#pgU').value,p_kind:q('#pgK').value,p_amount:+q('#pgN').value,p_unit:q('#pgT').value});toast('Accordé jusqu’au '+dt(t))});
  on('#pgR',async()=>{await rpcd('pass_revoke',{p_username:q('#pgU').value,p_kind:q('#pgK').value});toast('Retiré')});
}
function open(){
  const m=modal('<div id="psBox"></div><div class="row end"><button class="ghost" data-x>Fermer</button></div>',true);
  const go=()=>render(m.querySelector('#psBox'),go);go();
}
window.openPass=open;window.passShop=async function(el,done){await load();render(el,()=>{if(done)done();else window.passShop(el)})};window.PASSLOAD=load;

function boot(){
  hookEnsure();
  let n=0;const iv=setInterval(()=>{if(ready()){clearInterval(iv);load();hookEnsure();setInterval(load,600000)}else if(++n>120)clearInterval(iv)},1000);
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
})();
