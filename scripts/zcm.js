/* =====================================================================
   zcm.js — Conteneur ZCM (Communicer) : format binaire propre, PAS un zip renommé.
   Tous les fichiers d'un répertoire de bot (images, .cmm, .html, .css, .js, .txt,
   .png, .gif, .mp4, .mp3, polices…) sont stockés DANS le fichier, compressés (LZSS maison).
   Aucune adresse, aucun lien : le ZCM ne dépend d'aucun site.

   Disposition :
     "ZCM" 0x7F 0x01                 magie + version
     u32  longueur de l'en-tête JSON (UTF-8)   { meta, n }
     JSON en-tête
     pour chaque fichier :
       u16 longueur chemin, chemin UTF-8
       u8  drapeaux (bit0 = compressé)
       u32 taille d'origine, u32 taille stockée, u32 CRC32 de l'original
       données stockées
     u32 CRC32 de tout ce qui précède, puis "ZCM!"
   ===================================================================== */
(function(G){
'use strict';
const MAGIC=[0x5A,0x43,0x4D,0x7F,0x01],END=[0x5A,0x43,0x4D,0x21];
const LIM={files:500,file:12*1024*1024,total:48*1024*1024,path:200};

const CRC=(()=>{const t=new Uint32Array(256);for(let n=0;n<256;n++){let c=n;for(let k=0;k<8;k++)c=c&1?0xEDB88320^(c>>>1):c>>>1;t[n]=c>>>0}return t})();
function crc32(u8,c0){let c=(c0===undefined?0:c0)^0xFFFFFFFF;for(let i=0;i<u8.length;i++)c=CRC[(c^u8[i])&255]^(c>>>8);return (c^0xFFFFFFFF)>>>0}

/* ---------- LZSS : jetons = octet de contrôle (8 bits) puis littéral ou (offset 12 bits, longueur 4 bits +3) ---------- */
function lzCompress(src){
  const n=src.length,out=[];const W=4095,MINM=3,MAXM=18;
  const head=new Int32Array(1<<14).fill(-1),prev=new Int32Array(Math.max(n,1));
  let i=0,ctlPos=-1,bit=8;
  const ins=p=>{if(p+2<n){const h=((src[p]<<6)^(src[p+1]<<3)^src[p+2])&0x3FFF;prev[p]=head[h];head[h]=p}};
  while(i<n){
    if(bit===8){ctlPos=out.length;out.push(0);bit=0}
    let bl=0,bo=0;
    if(i+2<n){
      const h=((src[i]<<6)^(src[i+1]<<3)^src[i+2])&0x3FFF;let p=head[h],tries=24;
      while(p>=0&&i-p<=W&&tries--){
        let l=0;const mx=Math.min(MAXM,n-i);while(l<mx&&src[p+l]===src[i+l])l++;
        if(l>bl){bl=l;bo=i-p;if(l===mx)break}
        p=prev[p];
      }
    }
    if(bl>=MINM){
      out[ctlPos]|=(1<<bit);
      const o=bo-1;out.push(o&255,((o>>8)<<4)|(bl-MINM));
      for(let k=0;k<bl;k++)ins(i+k);i+=bl;
    }else{out.push(src[i]);ins(i);i++}
    bit++;
  }
  return Uint8Array.from(out);
}
function lzDecompress(src,size){
  const out=new Uint8Array(size);let i=0,o=0;
  while(o<size){
    if(i>=src.length)throw new Error('ZCM : données compressées tronquées');
    const ctl=src[i++];
    for(let b=0;b<8&&o<size;b++){
      if(ctl&(1<<b)){
        if(i+1>=src.length)throw new Error('ZCM : jeton invalide');
        const a=src[i++],c=src[i++];const off=(a|((c>>4)<<8))+1,len=(c&15)+3;
        if(off>o)throw new Error('ZCM : référence invalide');
        for(let k=0;k<len&&o<size;k++){out[o]=out[o-off];o++}
      }else{if(i>=src.length)throw new Error('ZCM : données tronquées');out[o++]=src[i++]}
    }
  }
  return out;
}

/* ---------- utilitaires ---------- */
const enc=s=>new TextEncoder().encode(s),dec=u=>new TextDecoder('utf-8',{fatal:true}).decode(u);
function cleanPath(p){
  p=String(p).replace(/\\/g,'/').replace(/^\/+/,'');
  if(!p||p.length>LIM.path||/(^|\/)\.\.(\/|$)/.test(p)||/[\0-\x1f]/.test(p)||p.split('/').some(s=>!s||s==='.'))throw new Error('ZCM : chemin invalide « '+String(p).slice(0,40)+' »');
  return p;
}
const MIME={txt:'text/plain',cmm:'text/x-cmm',js:'text/javascript',css:'text/css',html:'text/html',json:'application/json',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',gif:'image/gif',webp:'image/webp',svg:'image/svg+xml',mp3:'audio/mpeg',ogg:'audio/ogg',wav:'audio/wav',mp4:'video/mp4',webm:'video/webm',woff:'font/woff',woff2:'font/woff2',ttf:'font/ttf',otf:'font/otf'};
const mimeOf=p=>MIME[(p.split('.').pop()||'').toLowerCase()]||'application/octet-stream';

/* files : [{path, data:Uint8Array|string}] ; meta : objet JSON libre (nom, version, notes…) */
function pack(files,meta){
  if(files.length>LIM.files)throw new Error('ZCM : trop de fichiers');
  const seen=new Set(),parts=[];let total=0;
  const hdr=enc(JSON.stringify({meta:meta||{},n:files.length,t:Date.now()}));
  const push=u=>parts.push(u);
  const u32=v=>Uint8Array.of(v>>>24&255,v>>>16&255,v>>>8&255,v&255);
  push(Uint8Array.from(MAGIC));push(u32(hdr.length));push(hdr);
  for(const f of files){
    const path=cleanPath(f.path);if(seen.has(path))throw new Error('ZCM : doublon « '+path+' »');seen.add(path);
    const raw=typeof f.data==='string'?enc(f.data):f.data;
    if(raw.length>LIM.file)throw new Error('ZCM : fichier trop gros « '+path+' »');
    total+=raw.length;if(total>LIM.total)throw new Error('ZCM : répertoire trop gros');
    const c=lzCompress(raw),useC=c.length<raw.length;const st=useC?c:raw;
    const pb=enc(path);
    push(Uint8Array.of(pb.length>>8,pb.length&255));push(pb);push(Uint8Array.of(useC?1:0));
    push(u32(raw.length));push(u32(st.length));push(u32(crc32(raw)));push(st);
  }
  let len=0;parts.forEach(p=>len+=p.length);
  const out=new Uint8Array(len+8);let o=0;parts.forEach(p=>{out.set(p,o);o+=p.length});
  out.set(u32(crc32(out.subarray(0,o))),o);o+=4;out.set(END,o);
  return out;
}
function unpack(buf){
  const u=buf instanceof Uint8Array?buf:new Uint8Array(buf);
  if(u.length<17)throw new Error('ZCM : fichier trop court');
  for(let i=0;i<MAGIC.length;i++)if(u[i]!==MAGIC[i])throw new Error('ZCM : ce n’est pas un fichier .zcm');
  for(let i=0;i<4;i++)if(u[u.length-4+i]!==END[i])throw new Error('ZCM : fin de fichier absente (fichier incomplet)');
  const rd32=p=>(u[p]*16777216)+((u[p+1]<<16)|(u[p+2]<<8)|u[p+3]);
  if(rd32(u.length-8)!==crc32(u.subarray(0,u.length-8)))throw new Error('ZCM : somme de contrôle incorrecte (fichier altéré)');
  let p=MAGIC.length;const hl=rd32(p);p+=4;
  if(hl>1e6||p+hl>u.length)throw new Error('ZCM : en-tête invalide');
  const head=JSON.parse(dec(u.subarray(p,p+hl)));p+=hl;
  if(!head||typeof head.n!=='number'||head.n>LIM.files)throw new Error('ZCM : en-tête invalide');
  const files=[],seen=new Set();let total=0;
  for(let k=0;k<head.n;k++){
    const pl=(u[p]<<8)|u[p+1];p+=2;if(pl>LIM.path*4||p+pl>u.length)throw new Error('ZCM : chemin invalide');
    const path=cleanPath(dec(u.subarray(p,p+pl)));p+=pl;if(seen.has(path))throw new Error('ZCM : doublon');seen.add(path);
    const fl=u[p++],size=rd32(p),stored=rd32(p+4),crc=rd32(p+8);p+=12;
    if(size>LIM.file||stored>u.length||p+stored>u.length-8)throw new Error('ZCM : taille invalide');
    total+=size;if(total>LIM.total)throw new Error('ZCM : répertoire trop gros');
    const st=u.subarray(p,p+stored);p+=stored;
    const raw=(fl&1)?lzDecompress(st,size):st.slice();
    if(raw.length!==size||crc32(raw)!==crc)throw new Error('ZCM : fichier corrompu « '+path+' »');
    files.push({path,data:raw,mime:mimeOf(path)});
  }
  return {meta:head.meta||{},files};
}
/* base64 pratique pour stocker dans la base */
function toB64(u8){let s='';for(let i=0;i<u8.length;i+=0x8000)s+=String.fromCharCode.apply(null,u8.subarray(i,i+0x8000));return btoa(s)}
function fromB64(b){const s=atob(b),u=new Uint8Array(s.length);for(let i=0;i<s.length;i++)u[i]=s.charCodeAt(i);return u}

G.ZCM={pack,unpack,crc32,mimeOf,cleanPath,toB64,fromB64,LIM,version:'1.0'};
if(typeof module!=='undefined'&&module.exports)module.exports=G.ZCM;
})(typeof window!=='undefined'?window:globalThis);
