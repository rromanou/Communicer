// Edge function « ciffron-key » : remet la clé de Ciffron V2 uniquement aux personnes réellement connectées.
// Déploiement :  supabase functions deploy ciffron-key
// Secret      :  supabase secrets set CIFFRON_KEY=<clé fournie>
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "GET, OPTIONS" };
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const auth = req.headers.get("Authorization") || "";
  const k = Deno.env.get("CIFFRON_KEY");
  if (!k) return new Response(JSON.stringify({ error: "non configuré" }), { status: 500, headers: { ...CORS, "Content-Type": "application/json" } });
  // le jeton doit être celui d'un utilisateur (pas la clé anonyme publique)
  const r = await fetch(Deno.env.get("SUPABASE_URL") + "/auth/v1/user", { headers: { Authorization: auth, apikey: Deno.env.get("SUPABASE_ANON_KEY") || "" } });
  if (!r.ok) return new Response(JSON.stringify({ error: "refusé" }), { status: 401, headers: { ...CORS, "Content-Type": "application/json" } });
  return new Response(JSON.stringify({ k }), { headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" } });
});
