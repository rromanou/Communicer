// Supabase Edge Function « account-mail » (verify_jwt = false ; l'identité est vérifiée dans le code)
// Secrets : RESEND_API_KEY, MAIL_FROM (ex. « Communicer! <no-reply@votre-domaine> »), SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, apikey, x-client-info", "access-control-allow-methods": "POST, OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "content-type": "application/json" } });
const sha = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t)))).map((b) => b.toString(16).padStart(2, "0")).join("");
const code6 = () => String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
const okMail = (e: string) => /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/.test(e) && e.length <= 254;
async function send(to: string, subject: string, text: string) {
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { authorization: "Bearer " + Deno.env.get("RESEND_API_KEY"), "content-type": "application/json" },
    body: JSON.stringify({ from: Deno.env.get("MAIL_FROM"), to, subject, text }) });
  if (!r.ok) throw new Error("Envoi du courriel impossible");
}
async function issue(userId: string | null, email: string, purpose: "verify" | "reset") {
  const { count } = await admin.from("email_codes").select("id", { count: "exact", head: true }).ilike("email", email).gt("created_at", new Date(Date.now() - 3600_000).toISOString());
  if ((count ?? 0) >= 5) throw new Error("Trop de demandes, réessayez plus tard");
  const code = code6();
  await admin.from("email_codes").insert({ user_id: userId, email: email.toLowerCase(), purpose, code_hash: await sha(code + ":" + email.toLowerCase()), expires_at: new Date(Date.now() + 15 * 60_000).toISOString() });
  return code;
}
async function check(email: string, purpose: string, code: string, userId: string | null) {
  const { data } = await admin.from("email_codes").select("*").ilike("email", email).eq("purpose", purpose).eq("used", false).gt("expires_at", new Date().toISOString()).order("id", { ascending: false }).limit(1);
  const row = data?.[0];
  if (!row || (userId && row.user_id !== userId)) return null;
  if (row.tries >= 5) return null;
  if (row.code_hash !== await sha(code + ":" + email.toLowerCase())) { await admin.from("email_codes").update({ tries: row.tries + 1 }).eq("id", row.id); return null; }
  await admin.from("email_codes").update({ used: true }).eq("id", row.id);
  return row;
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json(); const a = String(b.action || "");
    if (a === "send_verify" || a === "verify") {
      const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = await createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { authorization: "Bearer " + token } } }).auth.getUser();
      if (!u?.user) return json({ error: "Non connecté" }, 401);
      const email = String(b.email || "").trim().toLowerCase();
      if (!okMail(email)) return json({ error: "Adresse invalide" }, 400);
      if (a === "send_verify") {
        const { data: taken } = await admin.from("contact_emails").select("user_id").ilike("email", email).not("verified_at", "is", null).maybeSingle();
        if (taken && taken.user_id !== u.user.id) return json({ error: "Cette adresse est déjà utilisée" }, 400);
        await admin.from("contact_emails").upsert({ user_id: u.user.id, email, verified_at: null });
        await send(email, "Code de vérification Communicer!", "Votre code : " + await issue(u.user.id, email, "verify") + "\nValable 15 minutes.");
        return json({ ok: true });
      }
      const row = await check(email, "verify", String(b.code || ""), u.user.id);
      if (!row) return json({ error: "Code invalide ou expiré" }, 400);
      await admin.from("contact_emails").update({ verified_at: new Date().toISOString() }).eq("user_id", u.user.id).ilike("email", email);
      return json({ ok: true });
    }
    if (a === "reset_request" || a === "reset_confirm") {
      const un = String(b.username || "").trim().toLowerCase().replace(/^@/, ""); const email = String(b.email || "").trim().toLowerCase();
      const { data: p } = await admin.from("profiles").select("id").eq("username", un).maybeSingle();
      const { data: ce } = p ? await admin.from("contact_emails").select("email").eq("user_id", p.id).not("verified_at", "is", null).maybeSingle() : { data: null };
      const match = !!(p && ce && ce.email.toLowerCase() === email);
      if (a === "reset_request") { if (match) await send(email, "Réinitialisation du mot de passe Communicer!", "Votre code : " + await issue(p!.id, email, "reset") + "\nValable 15 minutes. Si vous n'êtes pas à l'origine de cette demande, ignorez ce message.\nAttention : la réinitialisation rend illisibles vos anciennes conversations chiffrées de bout en bout."); return json({ ok: true }); } // réponse identique si le compte n'existe pas
      const pw = String(b.password || ""); if (pw.length < 6) return json({ error: "Mot de passe : 6 caractères minimum" }, 400);
      if (!match || !(await check(email, "reset", String(b.code || ""), p!.id))) return json({ error: "Code invalide ou expiré" }, 400);
      const { error } = await admin.auth.admin.updateUserById(p!.id, { password: pw });
      if (error) return json({ error: "Échec de la réinitialisation" }, 500);
      await admin.from("profiles").update({ keys_reset_ok: true }).eq("id", p!.id);
      return json({ ok: true });
    }
    return json({ error: "Action inconnue" }, 400);
  } catch (e) { return json({ error: String((e as Error).message || e) }, 500); }
});
