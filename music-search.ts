// Edge function « music-search » — VlafiBOT V2.
//   GET  ?q=NOM&n=8        -> { results:[{title,artist,source,audio,page,score}], failed:[source] }
//   GET  ?proxy=URL_AUDIO  -> flux audio (CORS), hôtes autorisés seulement, 20 Mo maximum
// Déploiement : supabase functions deploy music-search   (verify_jwt activé : seules les personnes connectées l'appellent)
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "GET, OPTIONS" };
const SOURCES = [
  { id: "pixabay", host: "pixabay.com", url: (q: string) => `https://pixabay.com/fr/music/search/${encodeURIComponent(q)}/` },
  { id: "audiolibrary", host: "audiolibrary.com.co", url: (q: string) => `https://audiolibrary.com.co/?s=${encodeURIComponent(q)}` },
  { id: "fma", host: "freemusicarchive.org", url: (q: string) => `https://freemusicarchive.org/search?quicksearch=${encodeURIComponent(q)}` },
  { id: "ccmixter", host: "ccmixter.org", url: (q: string) => `https://ccmixter.org/api/query?f=json&search=${encodeURIComponent(q)}&limit=12&sort=rank` },
  { id: "sonotheque", host: "lasonotheque.org", url: (q: string) => `https://lasonotheque.org/search?q=${encodeURIComponent(q)}` },
];
const HOSTS = ["pixabay.com", "cdn.pixabay.com", "audiolibrary.com.co", "freemusicarchive.org", "files.freemusicarchive.org", "ccmixter.org", "lasonotheque.org", "www.lasonotheque.org", "storage.googleapis.com"];
const norm = (s: string) => (s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
function lev(a: string, b: string) { const m = a.length, n = b.length; if (!m) return n; if (!n) return m; let p = Array.from({ length: n + 1 }, (_, j) => j); for (let i = 1; i <= m; i++) { const c = [i]; for (let j = 1; j <= n; j++) c.push(Math.min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))); p = c; } return p[n]; }
function score(q: string, title: string, artist: string) {
  const t = norm(title), tx = t + " " + norm(artist); let s = 0;
  if (t === q) s += 100; if (t.includes(q)) s += 60; if (tx.includes(q)) s += 30;
  for (const w of q.split(" ")) { if (w.length < 2) continue; if (t.includes(w)) s += 14; else if (tx.includes(w)) s += 8; }
  s += Math.max(0, 20 - lev(q, t.slice(0, Math.max(q.length, 3))) * 2); return s;
}
const AUDIO = /\.(mp3|ogg|wav|m4a)(\?|$)/i;
const abs = (u: string, base: string) => { try { return new URL(u.replace(/&amp;/g, "&"), base).toString(); } catch { return ""; } };
const okHost = (u: string) => { try { const x = new URL(u); return x.protocol === "https:" && HOSTS.some((h) => x.hostname === h || x.hostname.endsWith("." + h)); } catch { return false; } };
async function get(url: string, ms = 7000) { const c = new AbortController(); const t = setTimeout(() => c.abort(), ms); try { return await fetch(url, { signal: c.signal, headers: { "User-Agent": "CommunicerMusicSearch/1.0", Accept: "text/html,application/json" } }); } finally { clearTimeout(t); } }
function fromHtml(html: string, base: string, source: string) {
  const out: any[] = [], seen = new Set<string>();
  const add = (audio: string, title: string, page: string) => { const a = abs(audio, base); if (!a || seen.has(a) || !AUDIO.test(a)) return; seen.add(a); const nm = (title || decodeURIComponent(a.split("/").pop()!.split("?")[0]).replace(/\.[a-z0-9]+$/i, "").replace(/[-_]+/g, " ")).replace(/<[^>]+>/g, "").trim(); out.push({ title: nm.slice(0, 90), artist: "", source, audio: a, page: abs(page || base, base) }); };
  for (const m of html.matchAll(/<a[^>]+href=["']([^"']+\.(?:mp3|ogg|wav|m4a)[^"']*)["'][^>]*>([\s\S]{0,120}?)<\/a>/gi)) add(m[1], m[2], base);
  for (const m of html.matchAll(/(?:data-(?:mp3|audio|src|preview)|src|content)=["']([^"']+\.(?:mp3|ogg|wav|m4a)[^"']*)["']/gi)) add(m[1], "", base);
  for (const m of html.matchAll(/"(?:audio|mp3|preview|download_url|url)"\s*:\s*"(https?:[^"]+\.(?:mp3|ogg|wav|m4a)[^"]*)"/gi)) add(m[1].replace(/\\\//g, "/"), "", base);
  return out;
}
async function searchOne(s: typeof SOURCES[number], q: string) {
  const r = await get(s.url(q)); if (!r.ok) throw new Error(String(r.status));
  if (s.id === "ccmixter") { const j = await r.json(); const out: any[] = []; for (const x of (Array.isArray(j) ? j : [])) { const f = (x.files || []).find((f: any) => AUDIO.test(f.download_url || "")); if (f) out.push({ title: x.upload_name, artist: x.user_real_name || x.user_name || "", source: s.id, audio: f.download_url, page: x.file_page_url || "" }); } return out; }
  return fromHtml(await r.text(), s.url(q), s.id);
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const u = new URL(req.url);
  const px = u.searchParams.get("proxy");
  if (px) {
    if (!okHost(px)) return new Response("Hôte non autorisé", { status: 403, headers: CORS });
    const r = await get(px, 20000); const len = +(r.headers.get("content-length") || 0);
    if (!r.ok || !r.body) return new Response("Introuvable", { status: 502, headers: CORS });
    if (len > 20 * 1024 * 1024) return new Response("Fichier trop gros", { status: 413, headers: CORS });
    const buf = new Uint8Array(await r.arrayBuffer()); if (buf.length > 20 * 1024 * 1024) return new Response("Fichier trop gros", { status: 413, headers: CORS });
    return new Response(buf, { headers: { ...CORS, "Content-Type": r.headers.get("content-type") || "audio/mpeg", "Cache-Control": "public, max-age=3600" } });
  }
  const q = norm(u.searchParams.get("q") || ""); const n = Math.max(1, Math.min(12, +(u.searchParams.get("n") || 8)));
  if (q.length < 2 || q.length > 80) return new Response(JSON.stringify({ error: "Requête invalide" }), { status: 400, headers: { ...CORS, "Content-Type": "application/json" } });
  const failed: string[] = []; const all: any[] = [];
  await Promise.all(SOURCES.map(async (s) => { try { all.push(...await searchOne(s, q)); } catch { failed.push(s.id); } }));
  const results = all.filter((x) => okHost(x.audio)).map((x) => ({ ...x, score: score(q, x.title, x.artist) })).sort((a, b) => b.score - a.score).slice(0, n);
  return new Response(JSON.stringify({ results, failed }), { headers: { ...CORS, "Content-Type": "application/json" } });
});
