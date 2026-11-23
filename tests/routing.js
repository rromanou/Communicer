// Routage téléphone / ordinateur. Usage : node tests/routing.js <racine servie> [prefixe]   (ex. _site, ou la racine du dépôt)
const {chromium}=require('playwright');const http=require('http'),fs=require('fs'),path=require('path');
const root=path.resolve(process.argv[2]||'_site');const T={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';const f=path.join(root,p);if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end()}r.writeHead(200,{'content-type':T[path.extname(f)]||'text/plain'});fs.createReadStream(f).pipe(r)});
srv.listen(0,async()=>{const b=await chromium.launch();const base=`http://localhost:${srv.address().port}`;let bad=0;
 const go=async(name,opt,url,want)=>{const c=await b.newContext(opt);const pg=await c.newPage();await pg.route(/supabase\.co|cdn\.jsdelivr/,r=>r.abort());await pg.goto(base+url);await pg.waitForTimeout(1200);
  const u=new URL(pg.url()).pathname,ok=want.test(u)&&await pg.evaluate(()=>!!document.getElementById('auth')&&document.styleSheets.length>0);console.log(ok?'OK ':'ECHEC',name,url,'->',u);if(!ok)bad++;await c.close()};
 const D={viewport:{width:1280,height:800}},P={viewport:{width:400,height:800},isMobile:true,hasTouch:true};
 await go('ordinateur sur /',D,'/',/^\/(index\.html|app\/index\.html)$|^\/$/);
 await go('ordinateur sur /phone/',D,'/phone/',/^\/(index\.html|app\/index\.html)?$|^\/app\//);
 await go('téléphone sur /',P,'/',/^\/phone\//);
 await b.close();srv.close();process.exit(bad?1:0)})
