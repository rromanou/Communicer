// Test de fumée : sert le site assemblé (_site) et vérifie que la page charge sans erreur JS.
// Usage : node tests/smoke.js [dossier=_site]   (nécessite playwright)
const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const root=path.resolve(process.argv[2]||'_site');
const T={'.html':'text/html','.js':'text/javascript','.css':'text/css','.txt':'text/plain','.png':'image/png','.enc':'text/plain','.b64':'text/plain'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';const f=path.join(root,p);
  if(!f.startsWith(root)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('404')}
  r.writeHead(200,{'content-type':T[path.extname(f)]||'application/octet-stream'});fs.createReadStream(f).pipe(r)});
(async()=>{await new Promise(r=>srv.listen(0,r));const port=srv.address().port;
 const b=await chromium.launch();const errs=[];let fail=0;
 for(const page of ['index.html','communicer-lite.html','phone/index.html','mentions.html','offline.html','404.html']){
  const pg=await b.newPage({viewport:{width:420,height:800}});
  pg.on('pageerror',e=>errs.push(page+' : '+e.message));
  await pg.route(/supabase\.co|cdn\.jsdelivr/,r=>r.abort());
  await pg.goto(`http://localhost:${port}/${page}`);await pg.waitForTimeout(1200);
  if(page.startsWith('index')||page.includes('lite')||page.startsWith('phone')){
    const ok=await pg.evaluate(async()=>({css:getComputedStyle(document.body).margin!==undefined&&document.styleSheets.length>0,
      auth:!!document.getElementById('auth'),h2c:(await blobText('blob-h2c')).length>1000,dico:(await blobText('blob-dico')).length>1000,lame:(await blobText('blob-lame')).length>1000,
      lite:!!window.__LITE,dlg:(await fetch('assets/src/dialogues.txt')).ok,bots:(await fetch('scripts/bots-offline.js')).ok,frame:(await fetch(frUrl('frames/photo1.png'))).ok,poppy:(await fetch('assets/images/poppy.png')).ok}));
    console.log(page,JSON.stringify(ok));if(Object.values(ok).slice(0,8).some(v=>v===false&&!(page.startsWith('index')&&v===ok.lite)))fail++;
  }
  await pg.close()}
 await b.close();srv.close();
 const real=errs.filter(e=>!/Hors ligne|supabase/i.test(e));console.log('erreurs JS:',real.length?real:'aucune');process.exit(real.length||fail?1:0)})();
