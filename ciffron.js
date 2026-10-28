/* =====================================================================
   ciffron.js — Défendeur Ciffron, l'antivirus de Communicer!
   - Analyse chaque fichier d'un bot (.cmm .js .html .css) ligne par ligne.
   - Les règles (motifs portables JS/PostgreSQL) viennent de la table ciffron_rules (Supabase)
     et, à défaut, de la liste intégrée ci-dessous.
   - Exceptions d'administrateur : code stocké dans Supabase (ciffron_exceptions), exécuté
     APRÈS le code intégré de ce fichier.
   - Surveillance à l'exécution : cadence de messages, silence du script (gel).
   Le blocage lui-même (bot, développeur, IP) est appliqué par le serveur (RPC ciffron_flag).
   ===================================================================== */
(function(G){
'use strict';
const W='[^A-Za-z0-9_$.]';
/* id, motif, drapeaux, types de fichiers, raison */
const BUILTIN=[
 ['sb-ref','(supabase|sb[ ]*\\.[ ]*(from|rpc|auth|storage|channel|functions)|\\.supabase\\.co)','i','*','Accès visant Supabase (base de données du site)'],
 ['net-api','(^|'+W+')(fetch|XMLHttpRequest|WebSocket|EventSource|importScripts|sendBeacon)([^A-Za-z0-9_$]|$)','','*','Requête réseau directe interdite : le bot doit passer par le SDK'],
 ['dyn-code','((^|'+W+')(eval|Function)[ ]*\\(|new[ ]+Function|setTimeout[ ]*\\([ ]*[\'"`]|setInterval[ ]*\\([ ]*[\'"`])','','*','Exécution de code dynamique'],
 ['escape','(^|[^A-Za-z0-9_$])(parent|top|opener|frameElement|globalThis\\.parent)[ ]*(\\.|\\[)','','js|cmm','Tentative de sortie du bac à sable'],
 ['storage','(document[ ]*\\.[ ]*cookie|localStorage|sessionStorage|indexedDB)','','*','Accès au stockage ou aux cookies du navigateur'],
 ['nav','(window[ ]*\\.[ ]*open|location[ ]*\\.[ ]*(href|assign|replace)|location[ ]*=[^=])','','*','Redirection ou ouverture de page'],
 ['ext-url','(https?://[A-Za-z0-9._-]+|@import|url\\([ ]*[\'"]?[ ]*//)','i','*','Importation étrangère : tout doit être dans le répertoire du bot'],
 ['html-bad','(<[ ]*(iframe|object|embed|base|form|meta|link)([^A-Za-z0-9]|$)|<[ ]*script[^>]*[ ]src|javascript[ ]*:)','i','html|js|cmm','Élément HTML dangereux'],
 ['obfus','((atob|btoa|fromCharCode|unescape)[ ]*\\(|(\\\\x[0-9a-fA-F]{2}){6,})','','js|cmm','Code obscurci'],
 ['loop-inf','(tant[ ]+que[ ]+(vrai|1)[ ]*:|while[ ]*\\([ ]*(true|1)[ ]*\\)|for[ ]*\\([ ]*;[ ]*;[ ]*\\))','','js|cmm','Boucle infinie (risque de spam ou de gel)'],
 ['priv-info','(sender_id|user_id|auth\\.uid|password|mot_de_passe|private_key|public_key)','i','js|cmm','Recherche d’informations privées'],
];
let RULES=BUILTIN.map(([id,pat,fl,files,reason])=>({id,pat,fl,files,reason}));
let EXC=[];

const hash=(s)=>{let h=2166136261;for(let i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619)}return (h>>>0).toString(16).padStart(8,'0')};
const lineHash=(file,line)=>hash(file+'\n'+String(line).trim());
const ext=p=>(p.split('.').pop()||'').toLowerCase();

function setRules(rows){
  if(!Array.isArray(rows)||!rows.length)return;
  const ok=[];rows.forEach(r=>{try{new RegExp(r.pat,r.fl||'');ok.push({id:r.id,pat:r.pat,fl:r.fl||'',files:r.files||'*',reason:r.reason||r.id})}catch(e){}});
  if(ok.length)RULES=ok;
}
/* exceptions : [{id,code}] ; code = corps d'une fonction (f, ctx) qui renvoie true pour AUTORISER la détection f */
function setExceptions(rows){
  EXC=[];(rows||[]).forEach(r=>{try{EXC.push({id:r.id,fn:new Function('f','ctx','Ciffron',String(r.code||''))})}catch(e){}});
}
const rx=new Map();
const re=r=>{let x=rx.get(r.id+r.pat);if(!x){x=new RegExp(r.pat,r.fl);rx.set(r.id+r.pat,x)}return x};

/* analyse d'un fichier → détections [{file,line,text,rule,reason,protected,allowed}] */
function scanFile(path,text,prot){
  const out=[];const e=ext(path);
  if(!/^(cmm|js|html|css)$/.test(e))return out;
  const lines=String(text).split(/\r?\n/);
  const protSet=prot instanceof Set?prot:new Set(prot||[]);
  lines.forEach((ln,i)=>{
    if(!ln.trim())return;
    // une ligne uniquement commentaire (# ou //) ne s'exécute pas, mais une URL dedans reste signalée
    for(const r of RULES){
      if(r.files!=='*'&&!r.files.split('|').includes(e))continue;
      if(r.id==='loop-inf'&&e==='css')continue;
      if(!re(r).test(ln))continue;
      const f={file:path,line:i+1,text:ln.slice(0,300),rule:r.id,reason:r.reason,protected:false,allowed:false};
      if(protSet.has(lineHash(path,ln)))f.protected=true;
      out.push(f);
    }
  });
  // boucle infinie avec attente => acceptable
  out.forEach(f=>{if(f.rule!=='loop-inf')return;const body=lines.slice(f.line,f.line+25).join('\n');if(/attendre|api\.sleep|await/.test(body))f.allowed=true});
  return out;
}
function scanBot(files,prot){
  const all=[];const ctx={files};
  Object.keys(files).forEach(p=>{const t=typeof files[p]==='string'?files[p]:null;if(t===null)return;all.push(...scanFile(p,t,prot))});
  all.forEach(f=>{
    if(f.protected||f.allowed)return;
    for(const x of EXC){try{if(x.fn(f,ctx,G.Ciffron)===true){f.allowed=true;f.by='exception:'+x.id;break}}catch(e){}}
  });
  return all;
}
const blocking=fs=>fs.filter(f=>!f.protected&&!f.allowed);

/* surveillance à l'exécution */
class Monitor{
  constructor(o){this.o=Object.assign({say:[8,5000],cmd:[20,5000],big:4000},o||{});this.t={}}
  hit(kind){
    const lim=this.o[kind];if(!lim)return null;const now=Date.now();
    const a=(this.t[kind]=(this.t[kind]||[]).filter(x=>now-x<lim[1]));a.push(now);
    if(a.length>lim[0])return {rule:'rt-'+kind,reason:kind==='say'?'Envoi de messages en rafale (spam)':'Trop de commandes en rafale'};
    return null;
  }
  size(txt){return String(txt||'').length>this.o.big?{rule:'rt-big',reason:'Message démesuré'}:null}
}
/* retrouve la ligne fautive d'un fichier d'après une règle d'exécution (aucune détection statique) */
function locate(files,hint){
  const fs=scanBot(files);const b=blocking(fs);if(b.length)return b;
  const key=hint==='rt-say'?/dire\(|api\.say|\.say\(/:/api\.|dire\(/;
  for(const p of Object.keys(files)){if(!/\.(cmm|js)$/.test(p))continue;const ls=String(files[p]).split('\n');
    for(let i=0;i<ls.length;i++)if(key.test(ls[i]))return [{file:p,line:i+1,text:ls[i].slice(0,300),rule:hint||'rt',reason:'Ligne à l’origine de l’activité suspecte',protected:false}]}
  return [];
}

G.Ciffron={version:'1.0',BUILTIN,get rules(){return RULES},scanFile,scanBot,blocking,lineHash,setRules,setExceptions,Monitor,locate,hash};
if(typeof module!=='undefined'&&module.exports)module.exports=G.Ciffron;
})(typeof window!=='undefined'?window:globalThis);
