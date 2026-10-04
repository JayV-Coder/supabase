// Pagamento dos planos pelo Stripe. Com o JWT do usuário:
//   POST { action: "checkout", plan }  → { url }  página de pagamento do Stripe
//   POST { action: "portal" }          → { url }  portal para trocar cartão, plano ou cancelar
// Sem JWT, o navegador volta do Stripe para cá:
//   GET ?return=done|cancel|portal     → 303 para jayv://billing/<return>, que reabre o app
//
// Quem já tem assinatura valendo e pede checkout recebe o portal: uma conta
// tem uma assinatura só. A assinatura em si só é gravada pelo `stripe-webhook`.
//
// Segredos (Edge Functions → Secrets): STRIPE_SECRET_KEY. A chave nunca vai
// para o app.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const RETURNS = ["done", "cancel", "portal"];
const ENTITLED = ["active", "trialing", "past_due"];

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function refuse(status: number, code: string, message: string): Response {
  return reply(status, { error: message, code });
}

const back = (kind: string) => `${Deno.env.get("SUPABASE_URL")}/functions/v1/billing?return=${kind}`;

Deno.serve(async (request) => {
  if (request.method === "GET") {
    const kind = new URL(request.url).searchParams.get("return") ?? "";
    if (!RETURNS.includes(kind)) return refuse(400, "return", "retorno desconhecido");
    return new Response(null, { status: 303, headers: { Location: `jayv://billing/${kind}` } });
  }
  if (request.method !== "POST") return refuse(405, "method", "só GET e POST");

  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!secret) return refuse(503, "config", "a função está sem a chave do Stripe");
  const stripe = new Stripe(secret);

  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return refuse(401, "session", "sem sessão");
  // O cliente com o token de quem chama passa pela RLS e pelo segundo fator;
  // o da service role só grava o cliente do Stripe.
  const user = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let subject: string | undefined;
  let email: string | undefined;
  try {
    const { data, error } = await user.auth.getClaims(token);
    if (!error) {
      subject = data?.claims?.sub;
      email = data?.claims?.email as string | undefined;
    }
  } catch {
    subject = undefined;
  }
  if (!subject) return refuse(401, "session", "sessão inválida ou expirada");

  let input: { action?: unknown; plan?: unknown };
  try {
    input = await request.json();
  } catch {
    return refuse(400, "body", "o corpo não é JSON");
  }

  // Lido com o token de quem chama: sem o segundo fator, a RLS não devolve
  // nada e a função recusa como qualquer outra leitura.
  const { data: known, error: reading } = await user.from("billing_customers").select("stripe_customer_id").maybeSingle();
  if (reading) return refuse(403, "read", reading.message);

  async function customer(): Promise<string> {
    if (known?.stripe_customer_id) return known.stripe_customer_id;
    // A chave de idempotência faz dois pedidos ao mesmo tempo criarem um só
    // cliente no Stripe.
    const created = await stripe.customers.create({ email, metadata: { user_id: subject! } }, { idempotencyKey: `customer-${subject}` });
    const { error } = await admin.from("billing_customers").insert({ user_id: subject, stripe_customer_id: created.id });
    if (error) {
      // Dois pedidos ao mesmo tempo: vale o que entrou primeiro.
      const { data: first } = await admin.from("billing_customers").select("stripe_customer_id").eq("user_id", subject).maybeSingle();
      if (first?.stripe_customer_id) return first.stripe_customer_id;
      throw error;
    }
    return created.id;
  }

  async function portal(): Promise<Response> {
    const session = await stripe.billingPortal.sessions.create({ customer: await customer(), return_url: back("portal") });
    return reply(200, { url: session.url, portal: true });
  }

  try {
    if (input.action === "portal") return await portal();
    if (input.action !== "checkout") return refuse(400, "action", "ação desconhecida");

    const { data: current } = await user.from("subscriptions").select("status").maybeSingle();
    if (current && ENTITLED.includes(current.status)) return await portal();
    // A tabela só se preenche quando o webhook chega: um pagamento que acabou
    // de passar ainda não está nela. O Stripe é quem sabe.
    if (known?.stripe_customer_id) {
      const live = await stripe.subscriptions.list({ customer: known.stripe_customer_id, status: "all", limit: 10 });
      if (live.data.some((item) => ENTITLED.includes(item.status))) return await portal();
    }

    const { data: plan, error: missing } = await user
      .from("plans")
      .select("key, stripe_price_id, active")
      .eq("key", String(input.plan ?? ""))
      .maybeSingle();
    if (missing) return refuse(403, "read", missing.message);
    if (!plan || !plan.active || !plan.stripe_price_id) return refuse(422, "plan", "plano sem preço no Stripe ou inativo");

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: await customer(),
      client_reference_id: subject,
      line_items: [{ price: plan.stripe_price_id, quantity: 1 }],
      subscription_data: { metadata: { user_id: subject } },
      allow_promotion_codes: true,
      success_url: back("done"),
      cancel_url: back("cancel"),
    });
    return reply(200, { url: session.url, portal: false });
  } catch (error) {
    console.error("billing", error);
    return refuse(502, "stripe", error instanceof Error ? error.message : String(error));
  }
});
