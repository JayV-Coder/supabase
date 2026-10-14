-- App 0.98.0 e site 2.16.0: preço do plano em mais de uma moeda e por país.
--
-- Até aqui o plano tinha um preço só (valor + moeda). Agora ele tem o preço
-- padrão (`price_cents` + `currency`, como antes) e, em `extra_prices`, preços
-- em outras moedas: [{currency, price_cents, countries: ["US", "CA"]}].
-- No Stripe são todos o mesmo preço do produto (`currency_options`) e quem paga
-- fica com a moeda do seu país; a moeda sai de `plan_price_for`:
--   1. a moeda pedida (a que a pessoa escolheu), se o plano a vende;
--   2. a moeda cuja lista de países traz o país da pessoa;
--   3. a moeda do país (`country_currency`: US → usd, DE → eur, GB → gbp...), se o plano a vende;
--   4. a moeda padrão do plano.
-- Só entram moedas com duas casas decimais (o Stripe conta o valor em centavos).
alter table public.plans
  add column extra_prices jsonb not null default '[]'::jsonb check (jsonb_typeof(extra_prices) = 'array');

-- A moeda de cada país, para as que o admin pode oferecer. País fora da lista
-- (ou sem moeda oferecida) cai na moeda padrão do plano.
create function public.country_currency(country text) returns text language sql immutable set search_path = '' as $$
  select case
    when upper(btrim(coalesce(country, ''))) in ('US', 'PR', 'EC', 'SV') then 'usd'
    when upper(btrim(coalesce(country, ''))) in ('AT', 'BE', 'CY', 'DE', 'EE', 'ES', 'FI', 'FR', 'GR', 'HR', 'IE', 'IT', 'LT', 'LU', 'LV', 'MT', 'NL', 'PT', 'SI', 'SK') then 'eur'
    when upper(btrim(coalesce(country, ''))) = 'GB' then 'gbp'
    when upper(btrim(coalesce(country, ''))) = 'BR' then 'brl'
    when upper(btrim(coalesce(country, ''))) = 'CA' then 'cad'
    when upper(btrim(coalesce(country, ''))) = 'AU' then 'aud'
    when upper(btrim(coalesce(country, ''))) = 'CH' then 'chf'
    when upper(btrim(coalesce(country, ''))) = 'MX' then 'mxn'
    when upper(btrim(coalesce(country, ''))) = 'IN' then 'inr'
  end;
$$;
revoke execute on function public.country_currency(text) from public;
grant execute on function public.country_currency(text) to anon, authenticated, service_role;

-- O preço que vale para quem é de `country` (ou pediu `wanted`): {currency, priceCents}.
create function public.plan_price_for(plan_key text, country text default null, wanted text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with p as (select currency, price_cents, extra_prices from public.plans where key = plan_key and active),
  options as (
    select p.currency as currency, p.price_cents as cents, '[]'::jsonb as countries, 0 as ord from p
    where p.currency is not null and p.price_cents is not null
    union all
    select e->>'currency', (e->>'price_cents')::integer, coalesce(e->'countries', '[]'::jsonb), 1
    from p, jsonb_array_elements(p.extra_prices) e
  ),
  ranked as (
    select o.*, case
      when o.currency = lower(btrim(coalesce(wanted, ''))) then 0
      when jsonb_exists(o.countries, upper(btrim(coalesce(country, '')))) then 1
      when o.currency = public.country_currency(country) then 2
      when o.ord = 0 then 3
    end as rank
    from options o
  )
  select jsonb_build_object('currency', r.currency, 'priceCents', r.cents)
  from ranked r where r.rank is not null order by r.rank limit 1;
$$;
revoke execute on function public.plan_price_for(text, text, text) from public;
grant execute on function public.plan_price_for(text, text, text) to anon, authenticated, service_role;

-- Alterar um preço extra também deixa o plano "não enviado ao Stripe".
create or replace function public.plans_guard_stripe() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb)->>'role', '') = 'authenticated' then
    if tg_op = 'INSERT' then
      new.stripe_product_id := null;
      new.stripe_price_id := null;
      new.stripe_synced_at := null;
    else
      new.stripe_product_id := old.stripe_product_id;
      new.stripe_price_id := old.stripe_price_id;
      new.stripe_synced_at := old.stripe_synced_at;
      if (new.name, new.description, new.active, new.price_cents, new.currency, new.billing_interval, new.extra_prices)
         is distinct from (old.name, old.description, old.active, old.price_cents, old.currency, old.billing_interval, old.extra_prices) then
        new.stripe_synced_at := null;
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- `admin_save_plan` passa a gravar `extra_prices` (validados: moeda da lista,
-- valor inteiro > 0, países de duas letras, cada país em uma moeda só).
create or replace function public.admin_save_plan(plan jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  chosen text := plan->>'key';
  item jsonb;
  wanted text[] := '{}';
  modes text[] := '{}';
  defaults boolean[] := '{}';
  mode text;
  extras jsonb := '[]'::jsonb;
  seen text[] := '{}';
  used text[] := '{}';
  cur text;
  countries jsonb;
  allowed text[] := array['usd','eur','gbp','brl','cad','aud','chf','mxn','inr'];
begin
  perform public.admin_require();
  if jsonb_typeof(plan) is distinct from 'object' or jsonb_typeof(plan->'features') is distinct from 'array' then
    raise exception 'admin.error.planInvalid';
  end if;
  for item in select value from jsonb_array_elements(plan->'features') loop
    if jsonb_typeof(item) = 'string' then
      if not ((item #>> '{}') = any (wanted)) then
        wanted := wanted || (item #>> '{}'); modes := modes || 'optional'::text; defaults := defaults || true;
      end if;
    elsif jsonb_typeof(item) = 'object' and jsonb_typeof(item->'key') = 'string' then
      mode := coalesce(item->>'mode', 'optional');
      if mode not in ('optional', 'locked') or (item ? 'default_on' and jsonb_typeof(item->'default_on') <> 'boolean') then
        raise exception 'admin.error.planInvalid';
      end if;
      if not ((item->>'key') = any (wanted)) then
        wanted := wanted || (item->>'key'); modes := modes || mode; defaults := defaults || coalesce((item->>'default_on')::boolean, true);
      end if;
    else
      raise exception 'admin.error.planInvalid';
    end if;
  end loop;
  if exists (select 1 from unnest(wanted) k where not exists (select 1 from public.features f where f.key = k)) then
    raise exception 'admin.error.unknownFeature';
  end if;
  -- Preços em outras moedas (e os países a que valem): só no plano pago.
  if plan ? 'extra_prices' and not coalesce((plan->>'is_default')::boolean, false) then
    if jsonb_typeof(plan->'extra_prices') is distinct from 'array' then
      raise exception 'admin.error.planInvalid';
    end if;
    for item in select value from jsonb_array_elements(plan->'extra_prices') loop
      cur := lower(btrim(coalesce(item->>'currency', '')));
      if jsonb_typeof(item) is distinct from 'object' or not (cur = any (allowed)) or cur = any (seen)
         or cur = lower(btrim(coalesce(plan->>'currency', '')))
         or coalesce(item->>'price_cents', '') !~ '^[1-9][0-9]{0,8}$' then
        raise exception 'admin.error.planInvalid';
      end if;
      if item ? 'countries' and jsonb_typeof(item->'countries') is distinct from 'array' then
        raise exception 'admin.error.planInvalid';
      end if;
      if exists (select 1 from jsonb_array_elements(coalesce(item->'countries', '[]'::jsonb)) c
                 where jsonb_typeof(c) is distinct from 'string' or (c #>> '{}') !~ '^[A-Za-z]{2}$') then
        raise exception 'admin.error.planInvalid';
      end if;
      select coalesce(jsonb_agg(distinct upper(c #>> '{}')), '[]'::jsonb) into countries
        from jsonb_array_elements(coalesce(item->'countries', '[]'::jsonb)) c;
      -- Um país só tem uma moeda.
      if exists (select 1 from jsonb_array_elements_text(countries) c where c = any (used)) then
        raise exception 'admin.error.planInvalid';
      end if;
      used := used || array(select jsonb_array_elements_text(countries));
      seen := seen || cur;
      extras := extras || jsonb_build_array(jsonb_build_object('currency', cur, 'price_cents', (item->>'price_cents')::integer, 'countries', countries));
    end loop;
  end if;
  begin
    -- Um padrão novo tira o posto do antigo antes de a linha nova entrar.
    if coalesce((plan->>'is_default')::boolean, false) then
      update public.plans set is_default = false where is_default and key <> chosen;
    end if;
    insert into public.plans (key, name, description, position, active, is_default, stripe_price_id, price_cents, currency, billing_interval, extra_prices, jev_daily_limit, max_concurrent_turns, updated_by, updated_at)
    values (
      chosen, btrim(plan->>'name'), coalesce(plan->>'description', ''), coalesce((plan->>'position')::integer, 0),
      coalesce((plan->>'active')::boolean, true), coalesce((plan->>'is_default')::boolean, false),
      nullif(btrim(plan->>'stripe_price_id'), ''), (plan->>'price_cents')::integer, nullif(lower(btrim(plan->>'currency')), ''),
      nullif(plan->>'billing_interval', ''), extras, nullif(plan->>'jev_daily_limit', '')::integer,
      coalesce(nullif(plan->>'max_concurrent_turns', '')::integer, 1), auth.uid(), now()
    )
    on conflict (key) do update set
      name = excluded.name, description = excluded.description, position = excluded.position, active = excluded.active,
      is_default = excluded.is_default, stripe_price_id = excluded.stripe_price_id, price_cents = excluded.price_cents,
      currency = excluded.currency, billing_interval = excluded.billing_interval, extra_prices = excluded.extra_prices, jev_daily_limit = excluded.jev_daily_limit,
      max_concurrent_turns = excluded.max_concurrent_turns, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  exception
    when check_violation or not_null_violation or invalid_text_representation then raise exception 'admin.error.planInvalid';
    when unique_violation then raise exception 'admin.error.priceTaken';
  end;
  if not exists (select 1 from public.plans where is_default) then raise exception 'admin.error.default'; end if;
  delete from public.plan_features pf
  where pf.plan_key = chosen and not (pf.feature_key = any (wanted))
    and not exists (select 1 from public.features f where f.key = pf.feature_key and f.core);
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select chosen, w.k, w.m, w.d from unnest(wanted, modes, defaults) as w(k, m, d)
  on conflict (plan_key, feature_key) do update set mode = excluded.mode, default_on = excluded.default_on;
  -- O núcleo é travado, diga a lista o que disser.
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select chosen, f.key, 'locked', true from public.features f where f.core
  on conflict (plan_key, feature_key) do update set mode = 'locked', default_on = true;
end;
$$;

-- A página pública: o preço já vem na moeda do país (ou da escolha) de quem
-- olha, e `currencies` traz as moedas que o plano vende, para trocar.
drop function public.public_plans();
create function public.public_plans(country text default null, wanted text default null) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', p.key, 'name', p.name, 'description', p.description, 'isDefault', p.is_default,
    'priceCents', (public.plan_price_for(p.key, country, wanted)->>'priceCents')::integer,
    'currency', public.plan_price_for(p.key, country, wanted)->>'currency',
    'interval', p.billing_interval,
    'currencies', case when p.is_default or p.currency is null then '[]'::jsonb
      else jsonb_build_array(p.currency) || coalesce((select jsonb_agg(e->>'currency') from jsonb_array_elements(p.extra_prices) e), '[]'::jsonb) end,
    'features', (select coalesce(jsonb_agg(jsonb_build_object('key', f.key, 'core', f.core) order by f.position, f.key), '[]'::jsonb)
                 from public.plan_features pf join public.features f on f.key = pf.feature_key
                 where pf.plan_key = p.key and f.enabled)
  ) order by p.position, p.key), '[]'::jsonb)
  from public.plans p
  where p.active and (p.is_default or p.stripe_price_id is not null);
$$;
revoke execute on function public.public_plans(text, text) from public;
grant execute on function public.public_plans(text, text) to anon, authenticated;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.admin.plan.prices.title', $json$"Preços em outras moedas"$json$::jsonb),
  ('en', 'site.admin.plan.prices.title', $json$"Prices in other currencies"$json$::jsonb),
  ('es', 'site.admin.plan.prices.title', $json$"Precios en otras monedas"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.title', $json$"其他货币的价格"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.title', $json$"अन्य मुद्राओं में कीमतें"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.title', $json$"الأسعار بعملات أخرى"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.title', $json$"Prix dans d’autres devises"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.title', $json$"Цены в других валютах"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.title', $json$"他の通貨での価格"$json$::jsonb),
  ('de', 'site.admin.plan.prices.title', $json$"Preise in anderen Währungen"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.hint', $json$"O preço acima é o padrão. Cada moeda extra vira um preço do mesmo produto no Stripe, e quem paga fica com a moeda do seu país. Liste os países (códigos de 2 letras, como US, CA) em que a moeda vale; deixe vazio para valer nos países que usam essa moeda."$json$::jsonb),
  ('en', 'site.admin.plan.prices.hint', $json$"The price above is the default. Each extra currency becomes a price of the same product in Stripe, and the buyer pays in the currency of their country. List the countries (2-letter codes such as US, CA) where the currency applies; leave it empty to use it in the countries that use that currency."$json$::jsonb),
  ('es', 'site.admin.plan.prices.hint', $json$"El precio de arriba es el predeterminado. Cada moneda extra se convierte en un precio del mismo producto en Stripe y quien paga lo hace en la moneda de su país. Indica los países (códigos de 2 letras, como US, CA) donde vale la moneda; déjalo vacío para usarla en los países que la tienen."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.hint', $json$"上面的价格是默认价格。每种额外货币都会成为 Stripe 中同一产品的一个价格，付款人按所在国家的货币付款。填写该货币适用的国家（两位代码，如 US、CA）；留空则适用于使用该货币的国家。"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.hint', $json$"ऊपर की कीमत डिफ़ॉल्ट है। हर अतिरिक्त मुद्रा Stripe में उसी प्रोडक्ट की एक कीमत बन जाती है, और भुगतान करने वाला अपने देश की मुद्रा में भुगतान करता है। वे देश लिखें (US, CA जैसे 2 अक्षर के कोड) जहाँ यह मुद्रा लागू हो; खाली छोड़ने पर यह उन देशों में लागू होगी जो यह मुद्रा इस्तेमाल करते हैं।"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.hint', $json$"السعر أعلاه هو الافتراضي. تصبح كل عملة إضافية سعرًا للمنتج نفسه في Stripe، ويدفع المشتري بعملة بلده. اذكر الدول (رموز من حرفين مثل US وCA) التي تسري فيها العملة، واتركها فارغة لتسري في الدول التي تستخدم هذه العملة."$json$::jsonb),
  ('fr', 'site.admin.plan.prices.hint', $json$"Le prix ci-dessus est celui par défaut. Chaque devise supplémentaire devient un prix du même produit dans Stripe, et l’acheteur paie dans la devise de son pays. Indiquez les pays (codes à 2 lettres, comme US, CA) où la devise s’applique ; laissez vide pour l’appliquer aux pays qui l’utilisent."$json$::jsonb),
  ('ru', 'site.admin.plan.prices.hint', $json$"Цена выше — основная. Каждая дополнительная валюта становится ценой того же продукта в Stripe, и покупатель платит в валюте своей страны. Укажите страны (двухбуквенные коды, например US, CA), где действует валюта; если оставить пусто, она действует в странах, которые её используют."$json$::jsonb),
  ('ja', 'site.admin.plan.prices.hint', $json$"上の価格が標準です。追加した通貨は Stripe の同じ商品の価格になり、購入者は自国の通貨で支払います。その通貨を使う国（US、CA などの2文字コード）を並べてください。空のままなら、その通貨を使う国に適用されます。"$json$::jsonb),
  ('de', 'site.admin.plan.prices.hint', $json$"Der Preis oben ist der Standardpreis. Jede weitere Währung wird in Stripe zu einem Preis desselben Produkts, und Käufer zahlen in der Währung ihres Landes. Nennen Sie die Länder (2-Buchstaben-Codes wie US, CA), in denen die Währung gilt; leer lassen, um sie in den Ländern zu verwenden, die diese Währung nutzen."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.add', $json$"Adicionar moeda"$json$::jsonb),
  ('en', 'site.admin.plan.prices.add', $json$"Add currency"$json$::jsonb),
  ('es', 'site.admin.plan.prices.add', $json$"Añadir moneda"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.add', $json$"添加货币"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.add', $json$"मुद्रा जोड़ें"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.add', $json$"إضافة عملة"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.add', $json$"Ajouter une devise"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.add', $json$"Добавить валюту"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.add', $json$"通貨を追加"$json$::jsonb),
  ('de', 'site.admin.plan.prices.add', $json$"Währung hinzufügen"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.remove', $json$"Remover"$json$::jsonb),
  ('en', 'site.admin.plan.prices.remove', $json$"Remove"$json$::jsonb),
  ('es', 'site.admin.plan.prices.remove', $json$"Quitar"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.remove', $json$"移除"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.remove', $json$"हटाएँ"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.remove', $json$"إزالة"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.remove', $json$"Retirer"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.remove', $json$"Убрать"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.remove', $json$"削除"$json$::jsonb),
  ('de', 'site.admin.plan.prices.remove', $json$"Entfernen"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.amount', $json$"Valor"$json$::jsonb),
  ('en', 'site.admin.plan.prices.amount', $json$"Amount"$json$::jsonb),
  ('es', 'site.admin.plan.prices.amount', $json$"Importe"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.amount', $json$"金额"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.amount', $json$"राशि"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.amount', $json$"المبلغ"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.amount', $json$"Montant"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.amount', $json$"Сумма"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.amount', $json$"金額"$json$::jsonb),
  ('de', 'site.admin.plan.prices.amount', $json$"Betrag"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.currency', $json$"Moeda"$json$::jsonb),
  ('en', 'site.admin.plan.prices.currency', $json$"Currency"$json$::jsonb),
  ('es', 'site.admin.plan.prices.currency', $json$"Moneda"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.currency', $json$"货币"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.currency', $json$"मुद्रा"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.currency', $json$"العملة"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.currency', $json$"Devise"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.currency', $json$"Валюта"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.currency', $json$"通貨"$json$::jsonb),
  ('de', 'site.admin.plan.prices.currency', $json$"Währung"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.prices.countries', $json$"Países (ex.: US, CA)"$json$::jsonb),
  ('en', 'site.admin.plan.prices.countries', $json$"Countries (e.g. US, CA)"$json$::jsonb),
  ('es', 'site.admin.plan.prices.countries', $json$"Países (p. ej., US, CA)"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.prices.countries', $json$"国家（如 US、CA）"$json$::jsonb),
  ('hi', 'site.admin.plan.prices.countries', $json$"देश (जैसे US, CA)"$json$::jsonb),
  ('ar', 'site.admin.plan.prices.countries', $json$"الدول (مثل US وCA)"$json$::jsonb),
  ('fr', 'site.admin.plan.prices.countries', $json$"Pays (p. ex. US, CA)"$json$::jsonb),
  ('ru', 'site.admin.plan.prices.countries', $json$"Страны (например, US, CA)"$json$::jsonb),
  ('ja', 'site.admin.plan.prices.countries', $json$"国（例: US、CA）"$json$::jsonb),
  ('de', 'site.admin.plan.prices.countries', $json$"Länder (z. B. US, CA)"$json$::jsonb),
  ('pt-BR', 'site.plans.currency', $json$"Moeda"$json$::jsonb),
  ('en', 'site.plans.currency', $json$"Currency"$json$::jsonb),
  ('es', 'site.plans.currency', $json$"Moneda"$json$::jsonb),
  ('zh-CN', 'site.plans.currency', $json$"货币"$json$::jsonb),
  ('hi', 'site.plans.currency', $json$"मुद्रा"$json$::jsonb),
  ('ar', 'site.plans.currency', $json$"العملة"$json$::jsonb),
  ('fr', 'site.plans.currency', $json$"Devise"$json$::jsonb),
  ('ru', 'site.plans.currency', $json$"Валюта"$json$::jsonb),
  ('ja', 'site.plans.currency', $json$"通貨"$json$::jsonb),
  ('de', 'site.plans.currency', $json$"Währung"$json$::jsonb),
  ('pt-BR', 'plans.currency', $json$"Moeda"$json$::jsonb),
  ('en', 'plans.currency', $json$"Currency"$json$::jsonb),
  ('es', 'plans.currency', $json$"Moneda"$json$::jsonb),
  ('zh-CN', 'plans.currency', $json$"货币"$json$::jsonb),
  ('hi', 'plans.currency', $json$"मुद्रा"$json$::jsonb),
  ('ar', 'plans.currency', $json$"العملة"$json$::jsonb),
  ('fr', 'plans.currency', $json$"Devise"$json$::jsonb),
  ('ru', 'plans.currency', $json$"Валюта"$json$::jsonb),
  ('ja', 'plans.currency', $json$"通貨"$json$::jsonb),
  ('de', 'plans.currency', $json$"Währung"$json$::jsonb),
  ('pt-BR', 'docs.plans.usage', $json$"Abra Planos na barra lateral (ou Ctrl+K › Planos) para ver o que cada plano inclui. Assinar abre o pagamento do Stripe no navegador e, quando ele termina, o JayV atualiza o plano sozinho; Gerenciar assinatura abre o portal do Stripe para trocar o cartão ou o plano e cancelar. Quem administra o sistema monta os planos no site (Dashboard › Administração › Planos): ao salvar, cada plano vira um produto no Stripe e o plano pago ganha o preço recorrente; trocar o valor cria um preço novo e tira o antigo de venda. Um plano só fica à venda depois de enviado ao Stripe. Um plano pago também pode ter preços em outras moedas (dólar, euro, libra, real, dólar canadense e australiano, franco suíço, peso mexicano e rupia), cada uma com os países em que vale: quem paga vê a moeda do seu país e pode escolher outra na página de planos."$json$::jsonb),
  ('en', 'docs.plans.usage', $json$"Open Plans in the sidebar (or Ctrl+K › Plans) to see what each plan includes. Subscribe opens Stripe's payment in the browser and, when it finishes, JayV updates the plan by itself; Manage subscription opens Stripe's portal to change the card or the plan and to cancel. Whoever administers the system builds the plans on the site (Dashboard › Administration › Plans): when you save, each plan becomes a product in Stripe and a paid plan gets its recurring price; changing the amount creates a new price and takes the old one off sale. A plan only goes on sale once it has been sent to Stripe. A paid plan can also have prices in other currencies (US dollar, euro, pound, real, Canadian and Australian dollar, Swiss franc, Mexican peso and rupee), each with the countries it applies to: whoever pays sees the currency of their country and can pick another on the plans page."$json$::jsonb),
  ('es', 'docs.plans.usage', $json$"Abre Planes en la barra lateral (o Ctrl+K › Planes) para ver qué incluye cada plan. Suscribirse abre el pago de Stripe en el navegador y, al terminar, JayV actualiza el plan solo; Gestionar suscripción abre el portal de Stripe para cambiar la tarjeta o el plan y cancelar. Quien administra el sistema arma los planes en el sitio (Panel › Administración › Planes): al guardar, cada plan se convierte en un producto de Stripe y el plan de pago recibe su precio recurrente; cambiar el importe crea un precio nuevo y retira el anterior de la venta. Un plan solo se vende una vez enviado a Stripe. Un plan de pago también puede tener precios en otras monedas (dólar, euro, libra, real, dólar canadiense y australiano, franco suizo, peso mexicano y rupia), cada una con los países donde vale: quien paga ve la moneda de su país y puede elegir otra en la página de planes."$json$::jsonb),
  ('zh-CN', 'docs.plans.usage', $json$"在侧边栏打开“套餐”（或 Ctrl+K › 套餐）查看每个套餐包含什么。“订阅”会在浏览器中打开 Stripe 支付，完成后 JayV 会自动更新套餐；“管理订阅”会打开 Stripe 门户，用于更换银行卡或套餐以及取消。系统管理员在网站（控制台 › 管理 › 套餐）中配置套餐：保存时，每个套餐都会成为 Stripe 中的一个产品，付费套餐还会创建循环价格；修改金额会创建新价格并下架旧价格。套餐发送到 Stripe 之后才会开始销售。 付费套餐还可以设置其他货币的价格（美元、欧元、英镑、雷亚尔、加元、澳元、瑞士法郎、墨西哥比索和卢比），并指定各自适用的国家：付款人看到所在国家的货币，也可以在套餐页面改选其他货币。"$json$::jsonb),
  ('hi', 'docs.plans.usage', $json$"हर प्लान में क्या शामिल है यह देखने के लिए साइडबार में प्लान खोलें (या Ctrl+K › प्लान)। सदस्यता लें ब्राउज़र में Stripe का भुगतान खोलता है और पूरा होते ही JayV प्लान अपने आप बदल देता है; सदस्यता प्रबंधित करें Stripe का पोर्टल खोलता है, जहाँ कार्ड या प्लान बदला और सदस्यता रद्द की जा सकती है। सिस्टम का प्रशासक प्लान साइट पर बनाता है (डैशबोर्ड › प्रशासन › प्लान): सहेजते ही हर प्लान Stripe में प्रोडक्ट बन जाता है और सशुल्क प्लान को आवर्ती कीमत मिलती है; राशि बदलने पर नई कीमत बनती है और पुरानी बिक्री से हट जाती है। प्लान Stripe को भेजे जाने के बाद ही बिक्री पर आता है। सशुल्क प्लान की कीमतें अन्य मुद्राओं में भी हो सकती हैं (डॉलर, यूरो, पाउंड, रियल, कनाडाई और ऑस्ट्रेलियाई डॉलर, स्विस फ़्रैंक, मेक्सिकन पेसो और रुपया), हर एक के साथ वे देश जहाँ वह लागू है: भुगतान करने वाले को अपने देश की मुद्रा दिखती है और वह प्लान पेज पर दूसरी मुद्रा चुन सकता है।"$json$::jsonb),
  ('ar', 'docs.plans.usage', $json$"افتح «الخطط» من الشريط الجانبي (أو Ctrl+K › الخطط) لترى ما تشمله كل خطة. «اشتراك» يفتح دفع Stripe في المتصفح، وعند انتهائه يحدّث JayV الخطة تلقائيًا؛ و«إدارة الاشتراك» يفتح بوابة Stripe لتغيير البطاقة أو الخطة والإلغاء. يبني مسؤول النظام الخطط في الموقع (لوحة التحكم › الإدارة › الخطط): عند الحفظ تصبح كل خطة منتجًا في Stripe وتحصل الخطة المدفوعة على سعرها المتكرر؛ وتغيير المبلغ ينشئ سعرًا جديدًا ويوقف بيع القديم. ولا تُعرض الخطة للبيع إلا بعد إرسالها إلى Stripe. يمكن أن تكون للخطة المدفوعة أسعار بعملات أخرى (الدولار واليورو والجنيه الإسترليني والريال البرازيلي والدولار الكندي والأسترالي والفرنك السويسري والبيزو المكسيكي والروبية)، لكل منها الدول التي تسري فيها: يرى من يدفع عملة بلده ويمكنه اختيار عملة أخرى في صفحة الخطط."$json$::jsonb),
  ('fr', 'docs.plans.usage', $json$"Ouvrez Forfaits dans la barre latérale (ou Ctrl+K › Forfaits) pour voir ce que chaque forfait inclut. S’abonner ouvre le paiement Stripe dans le navigateur et, une fois terminé, JayV met le forfait à jour tout seul ; Gérer l’abonnement ouvre le portail Stripe pour changer de carte ou de forfait et résilier. L’administrateur du système monte les forfaits sur le site (Tableau de bord › Administration › Forfaits) : à l’enregistrement, chaque forfait devient un produit dans Stripe et un forfait payant reçoit son prix récurrent ; changer le montant crée un nouveau prix et retire l’ancien de la vente. Un forfait n’est en vente qu’une fois envoyé à Stripe. Un forfait payant peut aussi avoir des prix dans d’autres devises (dollar, euro, livre, réal, dollars canadien et australien, franc suisse, peso mexicain et roupie), chacune avec les pays où elle s’applique : la personne qui paie voit la devise de son pays et peut en choisir une autre sur la page des forfaits."$json$::jsonb),
  ('ru', 'docs.plans.usage', $json$"Откройте «Тарифы» на боковой панели (или Ctrl+K › Тарифы), чтобы увидеть, что входит в каждый тариф. «Оформить подписку» открывает оплату Stripe в браузере, а когда она завершается, JayV сам обновляет тариф; «Управление подпиской» открывает портал Stripe, где можно сменить карту или тариф и отменить подписку. Администратор системы настраивает тарифы на сайте (Панель › Администрирование › Тарифы): при сохранении каждый тариф становится продуктом в Stripe, а платный получает регулярную цену; смена суммы создаёт новую цену и снимает старую с продажи. Тариф поступает в продажу только после отправки в Stripe. У платного тарифа могут быть цены и в других валютах (доллар, евро, фунт, реал, канадский и австралийский доллары, швейцарский франк, мексиканское песо и рупия), каждая со своими странами: плательщик видит валюту своей страны и может выбрать другую на странице тарифов."$json$::jsonb),
  ('ja', 'docs.plans.usage', $json$"サイドバーの「プラン」（または Ctrl+K › プラン）で、各プランの内容を確認できます。「申し込む」はブラウザーで Stripe の支払いを開き、完了すると JayV が自動でプランを更新します。「サブスクリプションを管理」は Stripe のポータルを開き、カードやプランの変更、解約ができます。システム管理者はサイト（ダッシュボード › 管理 › プラン）でプランを作ります。保存すると各プランが Stripe の商品になり、有料プランには定期課金の価格も作られます。金額を変えると新しい価格が作られ、古い価格は販売停止になります。プランは Stripe に送信されてから販売されます。 有料プランには、他の通貨（米ドル、ユーロ、ポンド、レアル、カナダドル、豪ドル、スイスフラン、メキシコペソ、ルピー）の価格も設定でき、通貨ごとに適用する国を指定できます。支払う人には自国の通貨が表示され、プランのページで別の通貨を選ぶこともできます。"$json$::jsonb),
  ('de', 'docs.plans.usage', $json$"Öffnen Sie Tarife in der Seitenleiste (oder Strg+K › Tarife), um zu sehen, was jeder Tarif enthält. Abonnieren öffnet die Stripe-Zahlung im Browser; ist sie abgeschlossen, aktualisiert JayV den Tarif selbst. Abo verwalten öffnet das Stripe-Portal, um Karte oder Tarif zu ändern und zu kündigen. Wer das System verwaltet, richtet die Tarife auf der Website ein (Dashboard › Administration › Tarife): Beim Speichern wird jeder Tarif zu einem Produkt in Stripe, ein kostenpflichtiger Tarif erhält seinen wiederkehrenden Preis; ändert sich der Betrag, entsteht ein neuer Preis und der alte wird aus dem Verkauf genommen. Ein Tarif wird erst verkauft, wenn er an Stripe gesendet wurde. Ein kostenpflichtiger Tarif kann auch Preise in anderen Währungen haben (Dollar, Euro, Pfund, Real, kanadischer und australischer Dollar, Schweizer Franken, mexikanischer Peso und Rupie), jeweils mit den Ländern, in denen sie gilt: Wer zahlt, sieht die Währung seines Landes und kann auf der Tarifseite eine andere wählen."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.plansCurrencies.title', $json$"Preços dos planos em várias moedas e por país"$json$::jsonb),
  ('en', 'whatsNew.item.plansCurrencies.title', $json$"Plan prices in several currencies and by country"$json$::jsonb),
  ('es', 'whatsNew.item.plansCurrencies.title', $json$"Precios de los planes en varias monedas y por país"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.plansCurrencies.title', $json$"套餐支持多种货币和按国家定价"$json$::jsonb),
  ('hi', 'whatsNew.item.plansCurrencies.title', $json$"प्लान की कीमतें कई मुद्राओं में और देश के अनुसार"$json$::jsonb),
  ('ar', 'whatsNew.item.plansCurrencies.title', $json$"أسعار الخطط بعملات متعددة وحسب الدولة"$json$::jsonb),
  ('fr', 'whatsNew.item.plansCurrencies.title', $json$"Prix des forfaits en plusieurs devises et par pays"$json$::jsonb),
  ('ru', 'whatsNew.item.plansCurrencies.title', $json$"Цены тарифов в нескольких валютах и по странам"$json$::jsonb),
  ('ja', 'whatsNew.item.plansCurrencies.title', $json$"プランの価格を複数の通貨・国別に設定可能に"$json$::jsonb),
  ('de', 'whatsNew.item.plansCurrencies.title', $json$"Tarifpreise in mehreren Währungen und nach Land"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.plansCurrencies.detail', $json$"Um plano pago pode ter preços em dólar, euro, libra, real e outras moedas, cada uma com os países em que vale. No site (Administração › Planos) você adiciona as moedas e o plano vai ao Stripe com todas elas; em Planos, a página abre na moeda do seu país e você pode trocá-la, e o pagamento é cobrado na que escolher."$json$::jsonb),
  ('en', 'whatsNew.item.plansCurrencies.detail', $json$"A paid plan can have prices in dollar, euro, pound, real and more, each with the countries it applies to. On the site (Administration › Plans) you add the currencies and the plan goes to Stripe with all of them; in Plans, the page opens in the currency of your country and you can switch it, and the payment is charged in the one you pick."$json$::jsonb),
  ('es', 'whatsNew.item.plansCurrencies.detail', $json$"Un plan de pago puede tener precios en dólar, euro, libra, real y más monedas, cada una con los países donde vale. En el sitio (Administración › Planes) añades las monedas y el plan llega a Stripe con todas; en Planes, la página se abre en la moneda de tu país y puedes cambiarla, y el pago se cobra en la que elijas."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.plansCurrencies.detail', $json$"付费套餐可以设置美元、欧元、英镑、雷亚尔等多种货币的价格，并指定每种货币适用的国家。在网站（管理 › 套餐）添加货币后，套餐会带着所有货币同步到 Stripe；在“套餐”页面默认显示你所在国家的货币，也可以切换，付款时按你选择的货币扣款。"$json$::jsonb),
  ('hi', 'whatsNew.item.plansCurrencies.detail', $json$"सशुल्क प्लान की कीमतें डॉलर, यूरो, पाउंड, रियल और अन्य मुद्राओं में हो सकती हैं, हर एक के साथ वे देश जहाँ वह लागू है। साइट (एडमिनिस्ट्रेशन › प्लान) में आप मुद्राएँ जोड़ते हैं और प्लान सभी के साथ Stripe पहुँचता है; प्लान पेज आपके देश की मुद्रा में खुलता है और आप उसे बदल सकते हैं, और भुगतान आपकी चुनी हुई मुद्रा में लिया जाता है।"$json$::jsonb),
  ('ar', 'whatsNew.item.plansCurrencies.detail', $json$"يمكن أن تكون للخطة المدفوعة أسعار بالدولار واليورو والجنيه والريال وغيرها، لكل عملة الدول التي تسري فيها. في الموقع (الإدارة › الخطط) تضيف العملات فتصل الخطة إلى Stripe بها جميعًا؛ وفي «الخطط» تفتح الصفحة بعملة بلدك ويمكنك تغييرها، ويُخصم الدفع بالعملة التي تختارها."$json$::jsonb),
  ('fr', 'whatsNew.item.plansCurrencies.detail', $json$"Un forfait payant peut avoir des prix en dollar, euro, livre, réal et d’autres devises, chacune avec les pays où elle s’applique. Sur le site (Administration › Forfaits), vous ajoutez les devises et le forfait part dans Stripe avec toutes ; dans Forfaits, la page s’ouvre dans la devise de votre pays et vous pouvez en changer, et le paiement est prélevé dans celle que vous choisissez."$json$::jsonb),
  ('ru', 'whatsNew.item.plansCurrencies.detail', $json$"У платного тарифа могут быть цены в долларах, евро, фунтах, реалах и других валютах, каждая со своими странами. На сайте (Администрирование › Тарифы) вы добавляете валюты, и тариф уходит в Stripe со всеми ними; в разделе «Тарифы» страница открывается в валюте вашей страны, её можно сменить, а оплата списывается в выбранной валюте."$json$::jsonb),
  ('ja', 'whatsNew.item.plansCurrencies.detail', $json$"有料プランには、米ドル、ユーロ、ポンド、レアルなど複数の通貨で価格を設定でき、通貨ごとに適用する国も指定できます。サイト（管理 › プラン）で通貨を追加すると、すべての通貨とともにプランが Stripe に送られます。アプリの「プラン」では自国の通貨で開き、切り替えもでき、支払いは選んだ通貨で請求されます。"$json$::jsonb),
  ('de', 'whatsNew.item.plansCurrencies.detail', $json$"Ein kostenpflichtiger Tarif kann Preise in Dollar, Euro, Pfund, Real und weiteren Währungen haben, jeweils mit den Ländern, in denen sie gilt. Auf der Website (Verwaltung › Tarife) fügen Sie die Währungen hinzu, und der Tarif geht mit allen zu Stripe; unter Tarife öffnet sich die Seite in der Währung Ihres Landes, Sie können sie wechseln, und die Zahlung wird in der gewählten Währung abgebucht."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
