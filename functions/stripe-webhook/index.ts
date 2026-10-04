// Os eventos do Stripe sobre as assinaturas. Confere a assinatura do evento
// (STRIPE_WEBHOOK_SECRET), lê a assinatura de novo na API — o evento pode
// chegar fora de ordem — e grava `subscriptions` com a service role.
//
// No Stripe (Developers → Webhooks), o endpoint é
// https://<projeto>.supabase.co/functions/v1/stripe-webhook com os eventos
// checkout.session.completed e customer.subscription.created/updated/deleted.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const ENTITLED = ["active", "trialing", "past_due"];

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain" } });
}

/** A conta dona da assinatura: pelo metadado que o checkout grava ou, sem
 * ele (assinatura criada no painel do Stripe), pelo cliente. */
async function owner(subscription: Stripe.Subscription): Promise<string | null> {
  if (subscription.metadata?.user_id) return subscription.metadata.user_id;
  const customer = typeof subscription.customer === "string" ? subscription.customer : subscription.customer.id;
  const { data } = await admin.from("billing_customers").select("user_id").eq("stripe_customer_id", customer).maybeSingle();
  return data?.user_id ?? null;
}

async function sync(stripe: Stripe, id: string) {
  const subscription = await stripe.subscriptions.retrieve(id);
  const userId = await owner(subscription);
  if (!userId) {
    console.error("stripe-webhook: assinatura sem conta", id);
    return;
  }
  const item = subscription.items.data[0];
  const price = item?.price?.id ?? null;
  // O fim do período mudou da assinatura para o item nas versões novas da API.
  const periodEnd = (item as unknown as { current_period_end?: number })?.current_period_end
    ?? (subscription as unknown as { current_period_end?: number }).current_period_end;
  const { data: plan } = price
    ? await admin.from("plans").select("key").eq("stripe_price_id", price).maybeSingle()
    : { data: null };

  // Uma assinatura antiga que acaba depois de a nova começar não derruba a
  // nova: a conta tem uma linha só, e vale a que ainda dá direito.
  const { data: current } = await admin.from("subscriptions").select("stripe_subscription_id, status, plan_key").eq("user_id", userId).maybeSingle();
  if (current && current.stripe_subscription_id !== subscription.id && ENTITLED.includes(current.status) && !ENTITLED.includes(subscription.status)) {
    return;
  }

  const { error } = await admin.from("subscriptions").upsert({
    user_id: userId,
    // Preço que nenhum plano tem mais (o admin trocou o preço do plano): quem
    // já assinava continua no plano que tinha, e não cai no gratuito.
    plan_key: plan?.key ?? (current?.stripe_subscription_id === subscription.id ? current.plan_key : null),
    stripe_subscription_id: subscription.id,
    stripe_price_id: price,
    status: subscription.status,
    current_period_end: periodEnd ? new Date(periodEnd * 1000).toISOString() : null,
    cancel_at_period_end: subscription.cancel_at_period_end ?? false,
    updated_at: new Date().toISOString(),
  }, { onConflict: "user_id" });
  if (error) throw error;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return text(405, "POST only");
  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  const signing = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret || !signing) return text(503, "missing Stripe secrets");
  const stripe = new Stripe(secret);

  const signature = request.headers.get("Stripe-Signature");
  if (!signature) return text(400, "missing signature");
  const body = await request.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, signing, undefined, Stripe.createSubtleCryptoProvider());
  } catch (error) {
    return text(400, `bad signature: ${error instanceof Error ? error.message : error}`);
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.mode === "subscription" && session.subscription) {
          await sync(stripe, typeof session.subscription === "string" ? session.subscription : session.subscription.id);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await sync(stripe, (event.data.object as Stripe.Subscription).id);
        break;
    }
  } catch (error) {
    // 500 faz o Stripe tentar de novo mais tarde.
    console.error("stripe-webhook", event.type, error);
    return text(500, "sync failed");
  }
  return text(200, "ok");
});
