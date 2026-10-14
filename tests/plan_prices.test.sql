-- App 0.98.0: preço do plano em várias moedas e por país. O admin grava os preços extras
-- (validados); a moeda de quem olha sai de `plan_price_for`; mexer neles tira o plano do
-- "enviado ao Stripe".
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'admin@teste.local');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],
  "extra_prices":[{"currency":"usd","price_cents":990,"countries":["us","ca"]},{"currency":"eur","price_cents":900},{"currency":"gbp","price_cents":800,"countries":["GB"]}]}') $$, 'o admin grava preços em outras moedas');
select is(public.plan_price_for('pro')->>'currency', 'brl', 'sem país, a moeda padrão do plano');
select is(public.plan_price_for('pro', 'CA')->>'currency', 'usd', 'o país listado na moeda leva a moeda (CA → usd, pela lista)');
select is((public.plan_price_for('pro', 'us')->>'priceCents')::integer, 990, 'e o valor dela');
select is(public.plan_price_for('pro', 'DE')->>'currency', 'eur', 'sem lista, vale a moeda do país (DE → eur)');
select is(public.plan_price_for('pro', 'GB')->>'currency', 'gbp', 'GB → gbp');
select is(public.plan_price_for('pro', 'MX')->>'currency', 'brl', 'moeda do país que o plano não vende: a padrão');
select is(public.plan_price_for('pro', 'DE', 'usd')->>'currency', 'usd', 'a moeda escolhida vale mais que a do país');
select is(public.plan_price_for('pro', 'FR', 'jpy')->>'currency', 'eur', 'moeda escolhida que o plano não vende é ignorada');
select is((select extra_prices->0->'countries' from public.plans where key = 'pro'), '["CA", "US"]'::jsonb, 'países vão em maiúsculas, sem repetir');
select is(public.country_currency('xx'), null, 'país sem moeda oferecida');

select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"usd","price_cents":1},{"currency":"usd","price_cents":2}]}') $$, 'P0001', 'admin.error.planInvalid', 'a mesma moeda duas vezes');
select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"brl","price_cents":1}]}') $$, 'P0001', 'admin.error.planInvalid', 'a moeda padrão não se repete nos extras');
select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"jpy","price_cents":1}]}') $$, 'P0001', 'admin.error.planInvalid', 'moeda fora da lista (sem duas casas decimais)');
select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"usd","price_cents":0}]}') $$, 'P0001', 'admin.error.planInvalid', 'valor zero');
select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"usd","price_cents":5,"countries":["US"]},{"currency":"eur","price_cents":5,"countries":["US"]}]}') $$, 'P0001', 'admin.error.planInvalid', 'um país numa moeda só');
select throws_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"usd","price_cents":5,"countries":["USA"]}]}') $$, 'P0001', 'admin.error.planInvalid', 'país é código de duas letras');

-- Quem grava os ids do Stripe é a service role; o plano vai à venda e à página.
select set_config('request.jwt.claims', '', true);
reset role;
update public.plans set stripe_price_id = 'price_TEST1234567', stripe_product_id = 'prod_TEST1234567', stripe_synced_at = now() where key = 'pro';
select is((select (e->>'priceCents')::integer from jsonb_array_elements(public.public_plans('US')) e where e->>'key' = 'pro'), 990, 'a página pública mostra o preço na moeda do país');
select is((select e->'currencies' from jsonb_array_elements(public.public_plans('US')) e where e->>'key' = 'pro'), '["brl", "usd", "eur", "gbp"]'::jsonb, 'e as moedas que o plano vende');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":[],"extra_prices":[{"currency":"usd","price_cents":1100}]}');
select is((select stripe_synced_at is null from public.plans where key = 'pro'), true, 'mudar os preços extras tira o plano do "enviado ao Stripe"');

select * from finish();
rollback;
