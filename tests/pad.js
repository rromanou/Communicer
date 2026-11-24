// Manette : visible seulement quand un jeu demande le clavier. Usage : node tests/pad.js <site>
const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const root=path.resolve(process.argv[2]||'_site');const T={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';const f=path.join(root,p);if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end()}r.writeHead(200,{'content-type':T[path.extname(f)]||'text/plain'});fs.createReadStream(f).pipe(r)});
srv.listen(0,async()=>{const b=await chromium.launch();const c=await b.newContext({viewport:{width:400,height:800},isMobile:true,hasTouch:true});const pg=await c.newPage();const errs=[];pg.on('pageerror',e=>errs.push(e.message));
 await pg.route(/supabase\.co|cdn\.jsdelivr/,r=>r.abort());await pg.goto(`http://localhost:${srv.address().port}/phone/index.html`);await pg.waitForTimeout(1500);
 const vis=()=>pg.evaluate(()=>{const b=document.getElementById('phPadBtn');return !!b&&!b.hidden});
 const a=await vis();
 await pg.evaluate(()=>{window.__k=e=>{};window.addEventListener('keydown',window.__k)});await pg.waitForTimeout(300);const bOn=await vis();
 await pg.evaluate(()=>window.removeEventListener('keydown',window.__k));await pg.waitForTimeout(300);const cOff=await vis();
 const box=await pg.evaluate(()=>{const r=document.getElementById('app').getBoundingClientRect();return [r.width,r.height]});
 console.log(JSON.stringify({sansJeu:a,avecJeu:bOn,apres:cOff,app:box}),errs.length?errs:'aucune erreur');await b.close();srv.close();process.exit(!a&&bOn&&!cOff&&!errs.length?0:1)})
