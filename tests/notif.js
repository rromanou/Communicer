// Notifications : bannière, dialogue de 3 s, redirection. Usage : node tests/notif.js <site>
const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const root=path.resolve(process.argv[2]||'_site');const T={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';const f=path.join(root,p);if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end()}r.writeHead(200,{'content-type':T[path.extname(f)]||'text/plain'});fs.createReadStream(f).pipe(r)});
srv.listen(0,async()=>{const b=await chromium.launch();const pg=await (await b.newContext({viewport:{width:1280,height:800}})).newPage();const errs=[];pg.on('pageerror',e=>errs.push(e.message));
 await pg.route(/supabase\.co|cdn\.jsdelivr/,r=>r.abort());await pg.goto(`http://localhost:${srv.address().port}/index.html`);await pg.waitForTimeout(800);
 const r=await pg.evaluate(async()=>{const o={};let went=0;
  NT.push({title:'Jetons',text:'Vous avez reçu des jetons.',detail:'+ 50 jetons · gain',go:()=>went++});
  o.banner=document.querySelector('.ntItem')?.textContent;o.noAmount=!/\d/.test(o.banner||'');
  const bb=document.querySelector('#ntBox').getBoundingClientRect();o.top=Math.round(bb.top);
  document.querySelector('.ntItem').click();await new Promise(r=>setTimeout(r,300));
  o.dlg=!!document.querySelector('.ntDlg');o.dlgText=document.querySelector('#ntD')?.textContent;o.cd=document.querySelector('#ntC')?.textContent;
  await new Promise(r=>setTimeout(r,3300));o.closed=!document.querySelector('.ntDlg');o.went=went;return o});
 console.log(JSON.stringify(r),'erreurs',errs.length?errs:'aucune');await b.close();srv.close();process.exit(r.dlg&&r.closed&&r.went===1&&r.noAmount&&!errs.length?0:1)})
