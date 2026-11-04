const PAGE='cm-page-v1',GAMES='cm-games-v1',OFF='offline.html';
self.addEventListener('install',e=>{e.waitUntil(caches.open(PAGE).then(c=>c.add(new Request(OFF,{cache:'reload'}))).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil((async()=>{for(const k of await caches.keys())if(k!==PAGE&&k!==GAMES)await caches.delete(k);await self.clients.claim()})())});
self.addEventListener('message',e=>{const d=e.data||{};
  if(d.t==='games-on')e.waitUntil(caches.open(GAMES).then(async c=>{const u=new URL('./',self.registration.scope).href;
    for(const x of [u,u+'index.html'])try{const r=await fetch(x,{cache:'reload'});if(r.ok)await c.put(x,r.clone())}catch(_){}
    const ok=!!(await c.match(u));const cl=await self.clients.matchAll();cl.forEach(k=>k.postMessage({t:'games-ready',ok}))}));
  if(d.t==='games-off')e.waitUntil(caches.delete(GAMES))});
self.addEventListener('fetch',e=>{const r=e.request;if(r.method!=='GET'||r.mode!=='navigate')return;
  e.respondWith((async()=>{try{const n=await fetch(r);if(n.ok){const g=await caches.open(GAMES).catch(()=>null);if(g&&(await g.keys()).length){const u=new URL('./',self.registration.scope).href;g.put(u,n.clone())}}return n}
    catch(_){const g=await caches.open(GAMES);const hit=(await g.match(new URL('./',self.registration.scope).href))||(await g.match(r,{ignoreSearch:true}));
      return hit||(await caches.match(OFF))||Response.error()}})())});
