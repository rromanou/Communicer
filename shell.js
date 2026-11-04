/* Coquille : charge la dernière version publiée sur GitHub, sinon la copie en cache, sinon la copie embarquée. */
(() => {
  const RAW = 'https://raw.githubusercontent.com/rromanou/Romanomoney/main/';
  const FILES = ['app.html', 'popup.css', 'popup.js', 'minigames.js', 'piggy.js', 'sync.js'];
  const KEY = 'rmn_remote', CHECK_MS = 1500;
  const f = document.getElementById('f');
  // intégré dans Communicer (iframe) : jeu centré dans le cadre 640x480
  if (window.parent !== window && /[?&]cm=1(&|$)/.test(location.search)) { const st = document.createElement('style'); st.textContent = 'html{height:100%;display:flex;justify-content:center;align-items:center;background:#05070f}body{margin:0!important}'; document.head.appendChild(st); }
  // hors extension (page web) ou permission « storage » absente : on retombe sur localStorage, sans planter
  const hasExt = typeof chrome !== 'undefined' && chrome && chrome.storage && chrome.storage.local;
  const ls = {
    get: (k) => { const o = {}; try { const keys = typeof k === 'string' ? [k] : Array.isArray(k) ? k : k && typeof k === 'object' ? Object.keys(k) : null; if (keys) keys.forEach((x) => { const v = localStorage.getItem('rmn_s_' + x); if (v != null) o[x] = JSON.parse(v); }); else for (let i = 0; i < localStorage.length; i++) { const n = localStorage.key(i); if (n.startsWith('rmn_s_')) o[n.slice(6)] = JSON.parse(localStorage.getItem(n)); } } catch (e) {} return o; },
    set: (o) => { try { for (const k in o) localStorage.setItem('rmn_s_' + k, JSON.stringify(o[k])); } catch (e) {} },
  };
  const sget = (k, cb) => { if (hasExt) chrome.storage.local.get(k, cb); else cb(ls.get(k)); };
  const sset = (o, cb) => { if (hasExt) chrome.storage.local.set(o, cb); else { ls.set(o); cb && cb(); } };
  const store = {
    get: (k) => new Promise((r) => sget(k, (o) => r(o ? o[k] : undefined))),
    set: (o) => new Promise((r) => sset(o, r)),
  };
  const bundled = async () => { const o = {}; for (const n of FILES) o[n] = await (await fetch(hasExt && chrome.runtime && chrome.runtime.getURL ? chrome.runtime.getURL(n) : n)).text(); return o; };
  const remote = async () => {
    const o = {};
    await Promise.all(FILES.map(async (n) => {
      const r = await fetch(RAW + n + '?t=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) throw new Error(n);
      const t = await r.text(); if (!t || t.length < 20) throw new Error(n); o[n] = t;
    }));
    if (!/<script/.test(o['app.html']) || !/__rmn/.test(o['popup.js'])) throw new Error('invalide');
    return o;
  };
  let files = null, source = 'embarquée';
  const ready = (async () => {
    const cached = await store.get(KEY);
    let fresh = null;
    try { fresh = await Promise.race([remote(), new Promise((_, no) => setTimeout(no, CHECK_MS))]); } catch (e) { /* hors ligne ou trop lent */ }
    if (fresh) { files = fresh; source = 'GitHub'; store.set({ [KEY]: { files: fresh, at: Date.now() } }); }
    else {
      // la mise à jour peut encore arriver : on la garde pour la prochaine ouverture
      remote().then((o) => store.set({ [KEY]: { files: o, at: Date.now() } })).catch(() => {});
      if (cached && cached.files) { files = cached.files; source = 'cache'; } else files = await bundled();
    }
  })();
  const send = (m) => f.contentWindow.postMessage(m, '*');
  window.addEventListener('message', async (e) => {
    if (e.source !== f.contentWindow) return;
    const d = e.data || {};
    if (d.t === 'hello') { await ready; send({ t: 'boot', files, source }); return; }
    if (d.t === 'size') { f.style.width = d.w + 'px'; f.style.height = d.h + 'px'; document.body.style.width = d.w + 'px'; document.body.style.height = d.h + 'px'; return; }
    if (d.t !== 'rpc') return;
    const reply = (v, err) => send({ t: 'rpc-res', id: d.id, v, err });
    try {
      if (d.m === 'storage.get') sget(d.a[0], (o) => reply(o));
      else if (d.m === 'storage.set') sset(d.a[0], () => reply(true));
      else if (d.m === 'tabs.query' && !(typeof chrome !== 'undefined' && chrome.tabs)) reply([]);
      else if (d.m === 'tabs.sendMessage' && !(typeof chrome !== 'undefined' && chrome.tabs)) reply(null, 'indisponible');
      else if (d.m === 'tabs.query') chrome.tabs.query(d.a[0], (t) => reply((t || []).map((x) => ({ id: x.id, url: x.url }))));
      else if (d.m === 'tabs.sendMessage') chrome.tabs.sendMessage(d.a[0], d.a[1], (r) => reply(r, chrome.runtime.lastError ? String(chrome.runtime.lastError.message) : null));
      else reply(null, 'inconnu');
    } catch (x) { reply(null, String(x)); }
  });
  if (hasExt && chrome.storage.onChanged) chrome.storage.onChanged.addListener((ch, area) => send({ t: 'storage-changed', ch, area }));
  else window.addEventListener('storage', () => send({ t: 'storage-changed', ch: {}, area: 'local' }));
})();
