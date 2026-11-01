// Supabase Edge Function « stripe-webhook » (verify_jwt = false)
// Secrets : STRIPE_WEBHOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
import Stripe from "https://esm.sh/stripe@16.12.0?target=denonext";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const stripe = new Stripe("sk_unused", { httpClient: Stripe.createFetchHttpClient() });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature") ?? "";
  let ev;
  try { ev = await stripe.webhooks.constructEventAsync(await req.text(), sig, Deno.env.get("STRIPE_WEBHOOK_SECRET")!); }
  catch { return new Response("bad signature", { status: 400 }); }
  if (ev.type === "checkout.session.completed") {
    const s = ev.data.object as any;
    if (s.payment_status === "paid") {
      const { error } = await db.rpc("order_fulfill", { p_ref: s.client_reference_id, p_provider: s.id, p_cents: s.amount_total });
      if (error) return new Response(error.message, { status: 500 });
    }
  }
  return new Response("ok");
});
