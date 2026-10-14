// Pagamento dos planos pelo Stripe. Com o JWT do usuário:
//   POST { action: "checkout", plan, country?, currency? }  → { url }  página de pagamento do Stripe,
//        na moeda pedida ou na do país de quem paga (veja `plan_price_for`)
//   POST { action: "portal" }          → { url }  portal para trocar cartão, plano ou cancelar
//   POST { action: "sync_plan", plan }     → { productId, priceId }  (só admin) cria ou atualiza
//        o produto e o preço do plano no Stripe, a partir do que o admin salvou no site
//   POST { action: "archive_plan", productId, priceId? }  → { ok }  (só admin) arquiva, depois de o
//        plano ser apagado, o produto (e o preço) que o JayV criou
// Sem JWT, o navegador volta do Stripe para cá:
//   GET ?return=done|cancel|portal     → 303 para jayv://billing/<return>, que reabre o app
//
// Quem já tem assinatura valendo e pede checkout recebe o portal: uma conta
// tem uma assinatura só. A assinatura em si só é gravada pelo `billing-webhook`.
//
// Segredo: STRIPE_SECRET_KEY, lida do Vault do Supabase (ou, na falta, dos
// segredos das Edge Functions). A chave nunca vai para o app.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const RETURNS = ["done", "cancel", "portal"];

/** Um segredo do Stripe: do Vault (`public.stripe_secret`, só a service role
 * chama) ou, se lá não houver, da variável de ambiente da função. */
async function stripeSecret(admin: ReturnType<typeof createClient>, name: string): Promise<string | undefined> {
  const { data } = await admin.rpc("stripe_secret", { secret_name: name });
  return (typeof data === "string" && data) || Deno.env.get(name) || undefined;
}
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

  // A chave vem do Vault do Supabase (função `stripe_secret`, só da service
  // role); sem ela lá, vale o segredo de mesmo nome das Edge Functions.
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const secret = await stripeSecret(admin, "STRIPE_SECRET_KEY");
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

  let input: { action?: unknown; plan?: unknown; productId?: unknown; priceId?: unknown; country?: unknown; currency?: unknown };
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

  type PlanRow = {
    key: string; name: string; description: string; active: boolean; is_default: boolean;
    price_cents: number | null; currency: string | null; billing_interval: "month" | "year" | null;
    extra_prices: { currency: string; price_cents: number }[] | null;
    stripe_product_id: string | null; stripe_price_id: string | null;
  };

  async function loadPlan(key: string): Promise<PlanRow | Response> {
    const { data, error } = await admin.from("plans")
      .select("key, name, description, active, is_default, price_cents, currency, billing_interval, extra_prices, stripe_product_id, stripe_price_id")
      .eq("key", key).maybeSingle();
    if (error) throw error;
    if (!data) return refuse(404, "plan", "plano desconhecido");
    return data as PlanRow;
  }

  /** O produto do plano no Stripe: o que o banco já guarda ou, se um envio
   * anterior morreu antes de gravar, o que já existe com a chave do plano. */
  async function productOf(plan: PlanRow): Promise<string | null> {
    if (plan.stripe_product_id) return plan.stripe_product_id;
    const found = await stripe.products.search({ query: `metadata['plan_key']:'${plan.key}'`, limit: 1 });
    return found.data[0]?.id ?? null;
  }

  /** Envia o plano ao Stripe: um produto por plano (o gratuito também, sem
   * preço) e, no plano à venda, um preço recorrente, com as outras moedas do
   * plano em `currency_options`. Preço no Stripe não muda: se valor, moeda,
   * intervalo ou as outras moedas mudaram, cria um novo, põe-no como padrão do
   * produto e arquiva o antigo. */
  async function syncPlan(key: string): Promise<Response> {
    const plan = await loadPlan(key);
    if (plan instanceof Response) return plan;
    const fields = { name: plan.name, description: plan.description || undefined, active: plan.active, metadata: { plan_key: plan.key } };
    let productId = await productOf(plan);
    if (productId) await stripe.products.update(productId, { ...fields, description: plan.description || "" });
    else productId = (await stripe.products.create(fields)).id;

    const selling = !plan.is_default && plan.active;
    if (selling && (!plan.price_cents || !plan.currency || !plan.billing_interval)) {
      return refuse(422, "price", "defina preço, moeda e intervalo para vender o plano");
    }
    const extras = Object.fromEntries((plan.extra_prices ?? []).map((item) => [item.currency, { unit_amount: item.price_cents }]));
    let priceId = plan.stripe_price_id;
    let retired: string | null = null;
    if (selling) {
      const current = priceId ? await stripe.prices.retrieve(priceId, { expand: ["currency_options"] }).catch(() => null) : null;
      const options = current?.currency_options ?? {};
      const same = current && current.active && current.product === productId && current.unit_amount === plan.price_cents
        && current.currency === plan.currency && current.recurring?.interval === plan.billing_interval
        && Object.keys(options).filter((code) => code !== current.currency).length === Object.keys(extras).length
        && Object.entries(extras).every(([code, value]) => options[code]?.unit_amount === value.unit_amount);
      if (!same) {
        const created = await stripe.prices.create({
          product: productId, unit_amount: plan.price_cents!, currency: plan.currency!,
          recurring: { interval: plan.billing_interval! }, metadata: { plan_key: plan.key },
          ...(Object.keys(extras).length > 0 ? { currency_options: extras } : {}),
        });
        await stripe.products.update(productId, { default_price: created.id });
        retired = priceId;
        priceId = created.id;
      }
    } else if (plan.is_default) {
      priceId = null;
    }
    const { error } = await admin.from("plans")
      .update({ stripe_product_id: productId, stripe_price_id: priceId, stripe_synced_at: new Date().toISOString() })
      .eq("key", plan.key);
    if (error) throw error;
    // Só depois de o banco apontar para o preço novo, o antigo sai de venda.
    if (retired) await stripe.prices.update(retired, { active: false }).catch((cause) => console.error("billing: preço antigo", cause));
    return reply(200, { productId, priceId });
  }

  /** O plano apagado deixa de estar à venda no Stripe: produto e preço são
   * arquivados, não apagados (quem assinou continua cobrado até cancelar). Só
   * mexe em produto que o JayV criou (leva `plan_key` nos metadados) e que
   * nenhum plano usa mais. */
  async function archivePlan(productId: string, priceId: string | null): Promise<Response> {
    if (!/^prod_[A-Za-z0-9]+$/.test(productId)) return refuse(400, "product", "produto inválido");
    const product = await stripe.products.retrieve(productId);
    if (!product.metadata?.plan_key) return refuse(422, "product", "este produto não é de um plano do JayV");
    const { data: used } = await admin.from("plans").select("key").eq("stripe_product_id", productId).maybeSingle();
    if (used) return refuse(409, "product", "um plano ainda usa este produto");
    if (priceId) await stripe.prices.update(priceId, { active: false }).catch((cause) => console.error("billing: preço", cause));
    await stripe.products.update(productId, { active: false });
    return reply(200, { ok: true });
  }

  try {
    if (input.action === "portal") return await portal();
    if (input.action === "sync_plan" || input.action === "archive_plan") {
      // Quem decide é o banco: `my_features().admin` lê `is_admin()` com o
      // token de quem chama, segundo fator incluído.
      const { data: me } = await user.rpc("my_features");
      if (!(me as { admin?: boolean } | null)?.admin) return refuse(403, "forbidden", "só o admin do sistema");
      return input.action === "sync_plan"
        ? await syncPlan(String(input.plan ?? ""))
        : await archivePlan(String(input.productId ?? ""), input.priceId ? String(input.priceId) : null);
    }
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
      .select("key, stripe_price_id, stripe_synced_at, active")
      .eq("key", String(input.plan ?? ""))
      .maybeSingle();
    if (missing) return refuse(403, "read", missing.message);
    // `stripe_synced_at` vazio: o admin mexeu no plano e o Stripe ainda não
    // recebeu — o preço que ele cobraria não é o que a página mostra.
    if (!plan || !plan.active || !plan.stripe_price_id || !plan.stripe_synced_at) return refuse(422, "plan", "plano sem preço no Stripe, desatualizado ou inativo");

    // A moeda: a que a pessoa escolheu ou a do país dela, entre as que o plano
    // vende (`plan_price_for`); sem resposta, a do preço padrão do Stripe.
    const country = typeof input.country === "string" && /^[A-Za-z]{2}$/.test(input.country) ? input.country : null;
    const wanted = typeof input.currency === "string" && /^[A-Za-z]{3}$/.test(input.currency) ? input.currency.toLowerCase() : null;
    const { data: chosen } = await user.rpc("plan_price_for", { plan_key: plan.key, country, wanted });
    const currency = (chosen as { currency?: string } | null)?.currency;

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      ...(currency ? { currency } : {}),
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
