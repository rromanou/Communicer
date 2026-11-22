/* Ciffron V2 (verrouillé) : le code du défendeur est chiffré (ciffron.enc) et ne se déverrouille qu'avec la clé secrète du serveur,
   remise seulement aux personnes connectées. Tant qu'il est verrouillé, l'analyse de bots refuse tout (par prudence). */
(function(G){
'use strict';
const hash=(s)=>{let h=2166136261;for(let i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619)}return (h>>>0).toString(16).padStart(8,'0')};
const lineHash=(file,line)=>hash(file+'\n'+String(line).trim());
class Monitor{
  constructor(o){this.o=Object.assign({say:[8,5000],cmd:[20,5000],big:4000},o||{});this.t={}}
  hit(kind){const lim=this.o[kind];if(!lim)return null;const now=Date.now();const a=(this.t[kind]=(this.t[kind]||[]).filter(x=>now-x<lim[1]));a.push(now);
    if(a.length>lim[0])return {rule:'rt-'+kind,reason:kind==='say'?'Envoi de messages en rafale (spam)':'Trop de commandes en rafale'};return null}
  size(txt){return String(txt||'').length>this.o.big?{rule:'rt-big',reason:'Message démesuré'}:null}
}
let real=null;const pend={rules:null,exc:null};
const locked=[{file:'',line:0,text:'',rule:'cif-locked',reason:'Ciffron est verrouillé : reconnectez-vous pour l’activer',protected:false,allowed:false}];
const C={version:'2.0-locked',locked:true,BUILTIN:[],hash,lineHash,Monitor,
  get rules(){return real?real.rules:[]},
  scanFile:(...a)=>real?real.scanFile(...a):[],
  scanBot:(...a)=>real?real.scanBot(...a):locked,
  blocking:fs=>real?real.blocking(fs):fs.filter(f=>!f.protected&&!f.allowed),
  locate:(...a)=>real?real.locate(...a):[],
  setRules:r=>{pend.rules=r;if(real)real.setRules(r)},
  setExceptions:r=>{pend.exc=r;if(real)real.setExceptions(r)}};
G.Ciffron=C;
let busy=null;
G.CiffronUnlock=function(url,anon,token){
  if(real)return Promise.resolve(true);if(busy)return busy;
  busy=(async()=>{
    const kr=await fetch(url+'/functions/v1/ciffron-key',{headers:{apikey:anon,Authorization:'Bearer '+token}});if(!kr.ok)throw new Error('clé refusée');
    const kb=Uint8Array.from(atob((await kr.json()).k),c=>c.charCodeAt(0));
    const er=await fetch('ciffron.enc?v=2');if(!er.ok)throw new Error('ciffron.enc introuvable');
    const raw=Uint8Array.from(atob((await er.text()).trim()),c=>c.charCodeAt(0));
    const key=await crypto.subtle.importKey('raw',kb,'AES-GCM',false,['decrypt']);
    const code=new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:raw.slice(0,12)},key,raw.slice(12)));
    const fake={};new Function('window','module',code)(fake,undefined);
    if(!fake.Ciffron)throw new Error('Ciffron invalide');
    real=fake.Ciffron;if(pend.rules)real.setRules(pend.rules);if(pend.exc)real.setExceptions(pend.exc);
    C.version=real.version;C.locked=false;return true;
  })().catch(e=>{busy=null;throw e});
  return busy;
};
})(window);
