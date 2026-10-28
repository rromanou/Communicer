/* =====================================================================
   cmm.js — Langage CMM (Communicer) : lit du code .cmm et le traduit en JavaScript.
   Traduction ligne à ligne (la ligne N du .cmm donne la ligne N du .js) pour que
   Ciffron et les erreurs puissent désigner la bonne ligne.
   Le JavaScript produit ne s'exécute QUE dans le bac à sable des bots (voir bots.js).
   ===================================================================== */
(function(G){
'use strict';

const WORDS={et:'&&',ou:'||',non:'!',vrai:'true',faux:'false',nul:'null',indefini:'undefined',egal:'===',different:'!==',nouveau:'new',typede:'typeof',attends:'await'};
const CONT=new Set(['sinon','erreur','finalement']);

function fail(line,msg){const e=new Error('Ligne '+line+' : '+msg);e.line=line;e.cmm=true;return e}

/* découpe une ligne en segments code / chaîne, retire le commentaire # */
function segments(src,ln){
  const out=[];let i=0,cur='';
  const push=(t,v)=>{if(v!=='')out.push({t,v})};
  while(i<src.length){
    const c=src[i];
    if(c==='#'){break}
    const f=(c==='f'&&(src[i+1]==='"'||src[i+1]==="'")&&!/[\w$]/.test(src[i-1]||''));
    if(c==='"'||c==="'"||c==='`'||f){
      push('code',cur);cur='';
      const q=f?src[i+1]:c;let j=i+(f?2:1),s='';
      while(j<src.length&&src[j]!==q){if(src[j]==='\\'){s+=src[j]+(src[j+1]||'');j+=2}else{s+=src[j];j++}}
      if(j>=src.length)throw fail(ln,'chaîne non fermée');
      if(f||q==='`'){
        let t=s.replace(/`/g,'\\`').replace(/\$\{/g,'\\${');
        if(f)t=t.replace(/\{/g,'${');
        out.push({t:'str',v:'`'+t+'`'});
      }else out.push({t:'str',v:q+s+q});
      i=j+1;continue;
    }
    cur+=c;i++;
  }
  push('code',cur);return out;
}
function convCode(code){
  let r=code.replace(/(^|[^\w$.])([A-Za-z_]\w*)(?![\w$])/g,(m,p,w)=>WORDS[w]!==undefined?p+WORDS[w]:m);
  r=r.replace(/([^=!<>])==(?!=)/g,'$1===').replace(/!=(?!=)/g,'!==');
  return r;
}
function depth(segs){let d=0;for(const s of segs)if(s.t==='code')for(const c of s.v){if('([{'.includes(c))d++;else if(')]}'.includes(c))d--}return d}
function join(segs,fn){return segs.map(s=>s.t==='code'?(fn?fn(convCode(s.v)):convCode(s.v)):s.v).join('')}
function stripColon(segs){
  const last=segs[segs.length-1];
  if(!last||last.t!=='code'||!/:\s*$/.test(last.v))return null;
  const c=segs.slice();c[c.length-1]={t:'code',v:last.v.replace(/:\s*$/,'')};return c;
}
function textOf(segs){return segs.map(s=>s.t==='code'?s.v:'"'+'"').join('')}

/* ---------- traduction ---------- */
function translate(source,opts){
  opts=opts||{};
  const lines=String(source).replace(/\r\n?/g,'\n').split('\n');
  const L=[];     // lignes analysées
  let pendDepth=0,pend=null;
  lines.forEach((raw,k)=>{
    const ln=k+1;
    if(pendDepth>0){ // continuation d'une expression sur plusieurs lignes
      const segs=segments(raw,ln);pendDepth+=depth(segs);
      pend.push(join(segs));
      L.push({ln,cont:true,js:join(segs)});
      if(pendDepth<=0){pendDepth=0;const last=L[L.length-1];last.js+=';'}
      return;
    }
    const ind=(raw.match(/^[ \t]*/)[0]).replace(/\t/g,'    ').length;
    const segs=segments(raw.trim()?raw:'',ln);
    const t=textOf(segs).trim();
    if(!t){L.push({ln,blank:true});return}
    L.push({ln,ind,segs,t});
    const d=depth(segs);
    if(d>0&&!/:\s*$/.test(t)){pendDepth=d;pend=[]}
  });

  // fonctions asynchrones (contiennent « attendre » / « attends », ou appellent une fonction async)
  const fnBlocks=[];let stack0=[];
  L.forEach((l,i)=>{
    if(l.blank||l.cont)return;
    while(stack0.length&&stack0[stack0.length-1].ind>=l.ind){fnBlocks.push(stack0.pop())}
    const m=/^(?:fonction|asynchrone)\s+([A-Za-z_]\w*)\s*\(/.exec(l.t);
    if(m)stack0.push({name:m[1],ind:l.ind,from:i,to:L.length-1});
    stack0.forEach(b=>b.to=i);
  });
  fnBlocks.push(...stack0);
  const asyncFns=new Set();
  const usesAwait=(from,to,names)=>{
    for(let i=from+1;i<=to;i++){const l=L[i];if(l.blank)continue;
      const tt=l.t||'';if(/^(attendre|attends)\b/.test(tt)||/\battends\b/.test(tt))return true;
      for(const n of names)if(new RegExp('(^|[^\\w$.])'+n+'\\s*\\(').test(tt)&&!/^(fonction|asynchrone)\s/.test(tt))return true}
    return false};
  let chg=true;
  while(chg){chg=false;for(const b of fnBlocks){if(asyncFns.has(b.name))continue;if(usesAwait(b.from,b.to,asyncFns)){asyncFns.add(b.name);chg=true}}}
  const awaitCalls=js=>{let r=js;asyncFns.forEach(n=>{r=r.replace(new RegExp('(^|[^\\w$.])(?<!function\\s)'+n+'\\s*\\(','g'),(m,p)=>p+'await '+n+'(')});return r};

  const out=[];const stack=[];
  const closeTo=(ind,upto)=>{let s='';while(stack.length&&stack[stack.length-1].ind>=ind){s+=stack.pop().close}return s};
  let prevPopped=null;
  for(let i=0;i<L.length;i++){
    const l=L[i];
    if(l.blank){out.push('');continue}
    if(l.cont){out.push(l.js);continue}
    const kw=(/^[A-Za-zéèêàùç]+/.exec(l.t)||[''])[0];
    let pre='';
    // fermeture des blocs plus profonds, puis éventuel raccord sinon / erreur / finalement
    while(stack.length&&stack[stack.length-1].ind>l.ind)pre+=stack.pop().close;
    const top=stack.length?stack[stack.length-1]:null;
    const isCont=CONT.has(kw)&&top&&top.ind===l.ind&&top.close==='}';
    if(isCont){stack.pop();pre+='}'}
    else pre+=closeTo(l.ind);
    if(stack.length&&l.ind<=stack[stack.length-1].ind){/* ne devrait pas arriver */}
    const head=stripColon(l.segs);
    let js='';
    const rest=(re)=>{const m=re.exec(l.t);return m};
    const hdr=(segsLike)=>join(segsLike);
    const open=(text,close)=>{
      // le bloc doit avoir un contenu plus indenté
      let j=i+1;while(j<L.length&&(L[j].blank))j++;
      if(j>=L.length||L[j].cont||L[j].ind<=l.ind)throw fail(l.ln,'bloc vide : il faut du code indenté après « : »');
      stack.push({ind:l.ind,close});return text;
    };
    if(head){
      const ht=textOf(head).trim();
      let m;
      const after=(re)=>{ // retire le mot-clé du début en gardant les segments
        const first=head[0];const nm=first.v.replace(re,'');const c=head.slice();c[0]={t:first.t,v:nm};return join(c)};
      if((m=/^si\s+/.exec(ht))){js=open('if ('+after(/^\s*si\s+/)+') {','}')}
      else if(/^sinon\s+si\s+/.test(ht)){if(!isCont)throw fail(l.ln,'« sinon si » sans « si » avant');js=open('else if ('+after(/^\s*sinon\s+si\s+/)+') {','}')}
      else if(/^sinon$/.test(ht)){if(!isCont)throw fail(l.ln,'« sinon » sans « si » avant');js=open('else {','}')}
      else if(/^tant\s+que\s+/.test(ht)){js=open('while ('+after(/^\s*tant\s+que\s+/)+') {','}')}
      else if((m=/^pour\s+([A-Za-z_]\w*)\s+de\s+(.+?)\s+a\s+(.+)$/.exec(ht))){
        js=open(`for (let ${m[1]}=${convCode(m[2])}; ${m[1]}<=${convCode(m[3])}; ${m[1]}++) {`,'}')}
      else if((m=/^pour\s+([A-Za-z_]\w*)\s+dans\s+/.exec(ht))){js=open('for (const '+m[1]+' of '+after(/^\s*pour\s+[A-Za-z_]\w*\s+dans\s+/)+') {','}')}
      else if((m=/^(?:fonction|asynchrone)\s+([A-Za-z_]\w*)\s*\((.*)\)$/.exec(ht))){
        js=open((asyncFns.has(m[1])||/^asynchrone/.test(ht)?'async ':'')+'function '+m[1]+'('+m[2]+') {','}')}
      else if((m=/^sur\s+commande\s+(\S+)\s*(?:\((.*)\))?$/.exec(ht))){
        const name=head.find(s=>s.t==='str');const nm=name?name.v:JSON.stringify(m[1]);
        js=open('api.onCommand('+nm+', async ('+(m[2]||'ctx')+') => {','});')}
      else if((m=/^sur\s+evenement\s+(\S+)\s*(?:\((.*)\))?$/.exec(ht))){
        const name=head.find(s=>s.t==='str');const nm=name?name.v:JSON.stringify(m[1]);
        js=open('api.on('+nm+', async ('+(m[2]||'e')+') => {','});')}
      else if((m=/^sur\s+clic\s+(\S+)\s*(?:\((.*)\))?$/.exec(ht))){
        const name=head.find(s=>s.t==='str');const nm=name?name.v:JSON.stringify(m[1]);
        js=open('api.onClick('+nm+', async ('+(m[2]||'e')+') => {','});')}
      else if((m=/^sur\s+(demarrage|fin|minuterie)\s*(?:\((.*)\))?$/.exec(ht))){
        js=open('api.on("'+m[1]+'", async ('+(m[2]||'e')+') => {','});')}
      else if(/^essayer$/.test(ht)){js=open('try {','}')}
      else if((m=/^erreur\s*([A-Za-z_]\w*)?$/.exec(ht))){if(!isCont)throw fail(l.ln,'« erreur » sans « essayer » avant');js=open('catch ('+(m[1]||'err')+') {','}')}
      else if(/^finalement$/.test(ht)){if(!isCont)throw fail(l.ln,'« finalement » sans « essayer » avant');js=open('finally {','}')}
      else throw fail(l.ln,'instruction inconnue avant « : » : '+ht.slice(0,40));
      if(isCont&&kw==='sinon'&&/^else\b/.test(js))js=js; // « } else … »
      if(isCont&&(kw==='erreur'||kw==='finalement'))js=js;
      out.push(pre+(isCont&&pre==='}'?' ':'')+awaitCalls(js));continue;
    }
    // instructions simples
    if(isCont)throw fail(l.ln,'« '+kw+' » doit se terminer par « : »');
    const t=l.t;let m;
    const after=(re)=>{const first=l.segs[0];const nm=first.v.replace(re,'');const c=l.segs.slice();c[0]={t:first.t,v:nm};return join(c)};
    if((m=/^soit\s+([A-Za-z_]\w*)\s*$/.exec(t)))js='let '+m[1]+';';
    else if(/^soit\s+/.test(t))js='let '+after(/^\s*soit\s+/)+';';
    else if(/^constante\s+/.test(t))js='const '+after(/^\s*constante\s+/)+';';
    else if(/^retour\s*$/.test(t))js='return;';
    else if(/^retour\s+/.test(t))js='return '+after(/^\s*retour\s+/)+';';
    else if(/^arreter\s*$/.test(t))js='break;';
    else if(/^continuer\s*$/.test(t))js='continue;';
    else if(/^attendre\s+/.test(t))js='await api.sleep('+after(/^\s*attendre\s+/)+');';
    else if(/^attends\s+/.test(t))js='await '+after(/^\s*attends\s+/)+';';
    else if(/^lancer\s+/.test(t))js='throw new Error('+after(/^\s*lancer\s+/)+');';
    else if((m=/^importer\s+/.test(t))){
      const mm=/^importer\s+(\S+)(?:\s+comme\s+([A-Za-z_]\w*))?\s*$/.exec(t);
      if(!mm)throw fail(l.ln,'syntaxe : importer "fichier.cmm" [comme nom]');
      const str=l.segs.find(s=>s.t==='str');
      js=(mm[2]?'const '+mm[2]+' = ':'')+'await api.require('+(str?str.v:'""')+');';
    }
    else if(/^exporter\s+[A-Za-z_]\w*\s*$/.test(t)){const n=t.split(/\s+/)[1];js='api.exportAs("'+n+'", '+n+');'}
    else js=join(l.segs)+';';
    if(js.endsWith(';;'))js=js.slice(0,-1);
    out.push(pre+awaitCalls(js));
  }
  // fermeture finale + enveloppe (sur la dernière ligne, sans décaler les lignes)
  let tail='';while(stack.length)tail+=stack.pop().close;
  if(out.length===0)out.push('');
  out[0]='(async function(api){"use strict";const dire=api.say,journal=api.log;'+out[0];
  out[out.length-1]+=tail+'})';
  return {js:out.join('\n'),asyncFns:[...asyncFns]};
}

/* ---------- chargement d'un répertoire ---------- */
function compileFile(path,text){
  if(/\.cmm$/i.test(path))return translate(text).js;
  return text;
}
/* « le .js lit les .cmm puis les traduit » : renvoie {path→js} pour tous les .cmm d'un répertoire */
function compileAll(files){
  const out={},errors=[];
  Object.keys(files).forEach(p=>{
    if(!/\.cmm$/i.test(p))return;
    try{out[p]=translate(files[p]).js}catch(e){errors.push({file:p,line:e.line||0,message:e.message})}
  });
  return {js:out,errors};
}

const KEYWORDS=['soit','constante','si','sinon','sinon si','tant que','pour … dans','pour … de … a …','fonction','asynchrone','retour','arreter','continuer','attendre','attends','lancer','essayer','erreur','finalement','importer','exporter','sur commande','sur evenement','sur clic','sur demarrage','sur fin','sur minuterie','et','ou','non','vrai','faux','nul'];

G.CMM={translate,compileFile,compileAll,KEYWORDS,version:'1.0'};
if(typeof module!=='undefined'&&module.exports)module.exports=G.CMM;
})(typeof window!=='undefined'?window:globalThis);
