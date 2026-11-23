// Supabase Edge Function « account-mail » (verify_jwt = false ; l'identité est vérifiée dans le code)
// Aucun service tiers de courriel : envoi par SMTP depuis la fonction Supabase (le même SMTP que celui configuré dans Authentication > SMTP).
// Secrets : SMTP_HOST, SMTP_PORT (465 ou 587), SMTP_USER, SMTP_PASS, MAIL_FROM (ex. « Communicer! <no-reply@votre-domaine> »),
//           SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
// Facultatif (téléphone) : TWILIO_SID, TWILIO_TOKEN, TWILIO_FROM — sans ces secrets l'option téléphone répond « SMS non configuré ».
// Facultatif : MAIL_HOURLY_MAX (plafond d'envois par heure, 90 par défaut)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, apikey, x-client-info", "access-control-allow-methods": "POST, OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "content-type": "application/json" } });
const sha = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t)))).map((b) => b.toString(16).padStart(2, "0")).join("");
const code6 = () => String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
const okMail = (e: string) => /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/.test(e) && e.length <= 254;
const okPhone = (p: string) => /^\+[1-9][0-9]{7,14}$/.test(p);
const normPhone = (p: string) => String(p || "").replace(/[\s().-]/g, "");
const HOURLY = Number(Deno.env.get("MAIL_HOURLY_MAX") || 90);

async function quota(channel: "email" | "sms") {
  const { count } = await admin.from("mail_log").select("id", { count: "exact", head: true }).eq("channel", channel).gt("created_at", new Date(Date.now() - 3600_000).toISOString());
  if ((count ?? 0) >= HOURLY) throw new Error("Limite d'envois atteinte pour cette heure, réessayez plus tard");
}
async function logSend(channel: "email" | "sms", kind: string, userId: string | null) { await admin.from("mail_log").insert({ channel, kind, user_id: userId }); }

async function sendMail(to: string, subject: string, text: string) {
  const port = Number(Deno.env.get("SMTP_PORT") || 465);
  const c = new SMTPClient({ connection: { hostname: Deno.env.get("SMTP_HOST")!, port, tls: port === 465, auth: { username: Deno.env.get("SMTP_USER")!, password: Deno.env.get("SMTP_PASS")! } } });
  try { await c.send({ from: Deno.env.get("MAIL_FROM")!, to, subject, content: text }); } catch (_) { throw new Error("Envoi du courriel impossible"); } finally { try { await c.close(); } catch (_) { /* rien */ } }
}
async function sendSms(to: string, text: string) {
  const sid = Deno.env.get("TWILIO_SID"), tok = Deno.env.get("TWILIO_TOKEN"), from = Deno.env.get("TWILIO_FROM");
  if (!sid || !tok || !from) throw new Error("SMS non configuré");
  const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, { method: "POST", headers: { authorization: "Basic " + btoa(sid + ":" + tok), "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ To: to, From: from, Body: text }) });
  if (!r.ok) throw new Error("Envoi du SMS impossible");
}
async function deliver(channel: "email" | "sms", dest: string, kind: string, userId: string | null, code: string) {
  await quota(channel);
  if (channel === "email") await sendMail(dest, kind === "reset" ? "Réinitialisation du mot de passe Communicer!" : "Code de vérification Communicer!",
    kind === "reset" ? "Votre code : " + code + "\nValable 15 minutes. Si vous n'êtes pas à l'origine de cette demande, ignorez ce message.\nAttention : la réinitialisation rend illisibles vos anciennes conversations chiffrées de bout en bout." : "Votre code : " + code + "\nValable 15 minutes.");
  else await sendSms(dest, "Communicer! : votre code est " + code + " (15 minutes).");
  await logSend(channel, kind, userId);
}
// les codes pour le téléphone sont rangés dans la même table, avec le préfixe « tel: »
const key = (channel: string, dest: string) => (channel === "sms" ? "tel:" + dest : dest.toLowerCase());
async function issue(userId: string | null, channel: string, dest: string, purpose: "verify" | "reset") {
  const k = key(channel, dest);
  const { count } = await admin.from("email_codes").select("id", { count: "exact", head: true }).eq("email", k).gt("created_at", new Date(Date.now() - 3600_000).toISOString());
  if ((count ?? 0) >= 5) throw new Error("Trop de demandes, réessayez plus tard");
  const code = code6();
  await admin.from("email_codes").insert({ user_id: userId, email: k, purpose, code_hash: await sha(code + ":" + k), expires_at: new Date(Date.now() + 15 * 60_000).toISOString() });
  return code;
}
async function check(channel: string, dest: string, purpose: string, code: string, userId: string) {
  const k = key(channel, dest);
  const { data } = await admin.from("email_codes").select("*").eq("email", k).eq("purpose", purpose).eq("used", false).gt("expires_at", new Date().toISOString()).order("id", { ascending: false }).limit(1);
  const row = data?.[0];
  if (!row || row.user_id !== userId) return null;   // le code doit avoir été émis pour CE compte
  if (row.tries >= 5) return null;
  if (row.code_hash !== await sha(code + ":" + k)) { await admin.from("email_codes").update({ tries: row.tries + 1 }).eq("id", row.id); return null; }
  await admin.from("email_codes").update({ used: true }).eq("id", row.id);
  return row;
}
async function caller(req: Request) {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { authorization: "Bearer " + token } } }).auth.getUser();
  return u?.user || null;
}
// l'ancien nom d'utilisateur reste valable pour retrouver le compte
async function findProfile(un: string) {
  const { data: p } = await admin.from("profiles").select("id").eq("username", un).maybeSingle();
  if (p) return p;
  const { data: h } = await admin.from("username_history").select("user_id").eq("name", un).maybeSingle();
  return h ? { id: h.user_id } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json(); const a = String(b.action || "");
    if (a === "send_verify" || a === "verify" || a === "send_verify_phone" || a === "verify_phone") {
      const user = await caller(req); if (!user) return json({ error: "Non connecté" }, 401);
      const sms = a.endsWith("_phone");
      const dest = sms ? normPhone(b.phone) : String(b.email || "").trim().toLowerCase();
      if (sms ? !okPhone(dest) : !okMail(dest)) return json({ error: sms ? "Numéro invalide (format +15145551234)" : "Adresse invalide" }, 400);
      const tbl = sms ? "contact_phones" : "contact_emails", col = sms ? "phone" : "email", ch = sms ? "sms" : "email";
      if (a.startsWith("send_verify")) {
        const { data: taken } = await admin.from(tbl).select("user_id").eq(col, dest).not("verified_at", "is", null).maybeSingle();
        if (taken && taken.user_id !== user.id) return json({ error: sms ? "Ce numéro est déjà utilisé" : "Cette adresse est déjà utilisée" }, 400);
        await deliver(ch, dest, "verify", user.id, await issue(user.id, ch, dest, "verify"));
        await admin.from(tbl).upsert({ user_id: user.id, [col]: dest, verified_at: null });
        return json({ ok: true });
      }
      const row = await check(ch, dest, "verify", String(b.code || ""), user.id);
      if (!row) return json({ error: "Code invalide ou expiré" }, 400);
      const { error } = await admin.from(tbl).update({ verified_at: new Date().toISOString() }).eq("user_id", user.id).eq(col, dest);
      if (error) return json({ error: sms ? "Ce numéro est déjà utilisé" : "Cette adresse est déjà utilisée" }, 400);
      return json({ ok: true });
    }
    if (a === "reset_request" || a === "reset_confirm") {
      const un = String(b.username || "").trim().toLowerCase().replace(/^@/, "");
      const sms = String(b.channel || "email") === "sms"; const ch = sms ? "sms" : "email";
      const dest = sms ? normPhone(b.phone) : String(b.email || "").trim().toLowerCase();
      const p = await findProfile(un);
      // le contact doit être CELUI enregistré ET vérifié dans les paramètres de ce compte
      const { data: ce } = p ? await admin.from(sms ? "contact_phones" : "contact_emails").select(sms ? "phone" : "email").eq("user_id", p.id).not("verified_at", "is", null).maybeSingle() : { data: null };
      const saved = ce ? String((ce as Record<string, string>)[sms ? "phone" : "email"]).toLowerCase() : "";
      const match = !!(p && ce && saved === dest.toLowerCase() && (sms ? okPhone(dest) : okMail(dest)));
      if (a === "reset_request") { if (match) await deliver(ch, dest, "reset", p!.id, await issue(p!.id, ch, dest, "reset")); return json({ ok: true }); } // réponse identique si le compte n'existe pas
      const pw = String(b.password || ""); if (pw.length < 6) return json({ error: "Mot de passe : 6 caractères minimum" }, 400);
      if (!match || !(await check(ch, dest, "reset", String(b.code || ""), p!.id))) return json({ error: "Code invalide ou expiré" }, 400);
      const { error } = await admin.auth.admin.updateUserById(p!.id, { password: pw });
      if (error) return json({ error: "Échec de la réinitialisation" }, 500);
      await admin.from("profiles").update({ keys_reset_ok: true }).eq("id", p!.id);
      return json({ ok: true });
    }
    return json({ error: "Action inconnue" }, 400);
  } catch (e) { return json({ error: String((e as Error).message || e) }, 500); }
});
