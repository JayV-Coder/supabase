-- v0.51.0: recursos ativáveis e planos (v0.60.0: o núcleo vem em todo plano). Quem não assina recebe o plano
-- padrão; o admin liga, desliga e monta planos; ninguém mais escreve.
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@teste.local'),
  ('00000000-0000-0000-0000-0000000000b2', 'user@teste.local');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is(public.my_plan(), 'free', 'sem assinatura, o plano padrão');
select is(jsonb_array_length(public.my_features()->'features'), 9, 'o gratuito é bem limitado: o núcleo e a busca');
select is((select count(*) from public.plan_features where plan_key = 'pro' and feature_key in ('organizations', 'orgChat')), 0::bigint, 'o Pro não traz as funções de organização');
select is((select count(*) from public.plan_features where plan_key = 'enterprise' and feature_key in ('organizations', 'orgChat')), 2::bigint, 'o Enterprise traz as de organização');
select is((select count(*) from public.plan_features pf join public.features f on f.key = pf.feature_key where pf.plan_key = 'pro' and not f.core), (select count(*) - 2 from public.features where not core), 'e o Pro traz todo o resto');
select is(jsonb_array_length(public.public_plans()), 1, 'a página pública mostra só o que está à venda: o gratuito, por enquanto');
select is(public.public_plans()->0->>'key', 'free', 'e é o gratuito');
select is((public.my_features()->>'admin')::boolean, false, 'quem não é admin não é admin');
select throws_ok($$ select public.admin_set_feature('stats', false) $$, 'P0001', 'admin.forbidden', 'só o admin desliga recurso');
select throws_ok($$ insert into public.plans (key, name) values ('x', 'X') $$, '42501', null, 'ninguém escreve planos direto');
select throws_ok($$ insert into public.subscriptions (user_id, stripe_subscription_id, status) values ('00000000-0000-0000-0000-0000000000b2', 'sub_1', 'active') $$, '42501', null, 'nem a própria assinatura');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select is((public.my_features()->>'admin')::boolean, true, 'o admin se vê admin');
select lives_ok($$ select public.admin_set_feature('stats', false) $$, 'o admin desliga um recurso');
select lives_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":["stats","secondOpinion"]}') $$, 'e cria um plano pago');
select lives_ok($$ select public.admin_save_plan('{"key":"free","name":"Free","is_default":true,"features":["organizations"]}') $$, 'e tira recursos do gratuito');
select throws_ok($$ select public.admin_save_plan('{"key":"free","name":"Free","is_default":false,"features":[]}') $$, 'P0001', 'admin.error.default', 'sempre há um plano padrão');
select throws_ok($$ select public.admin_save_plan('{"key":"xx","name":"X","features":["nada"]}') $$, 'P0001', 'admin.error.unknownFeature', 'recurso fora do catálogo recusa');
select is((select count(*) from public.plans where key in ('pro', 'enterprise', 'free')), 3::bigint, 'Free, Pro e Enterprise existem');
select is((select stripe_price_id from public.plans where key = 'pro'), null, 'o admin não grava o preço do Stripe: quem grava é a função');
select lives_ok($$ select public.admin_save_plan('{"key":"yy","name":"Y","stripe_price_id":"price_ABC12345","stripe_product_id":"prod_ABC12345","features":[]}') $$, 'ids do Stripe no corpo não dão erro');
select is((select stripe_price_id || stripe_product_id from public.plans where key = 'yy') is null, true, 'mas são ignorados também na criação');

reset role;
select set_config('request.jwt.claims', '', true);
update public.plans set stripe_product_id = 'prod_PRO12345', stripe_price_id = 'price_PRO12345', stripe_synced_at = now() where key = 'pro';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":4900,"currency":"brl","billing_interval":"month","features":["stats","secondOpinion"]}') $$, 'salvar o plano sem mudar nada');
select is((select stripe_synced_at is not null from public.plans where key = 'pro'), true, 'não tira o plano do Stripe');
select lives_ok($$ select public.admin_save_plan('{"key":"pro","name":"Pro","price_cents":5900,"currency":"brl","billing_interval":"month","features":["stats","secondOpinion"]}') $$, 'mudar o preço');
select is((select stripe_price_id || stripe_product_id from public.plans where key = 'pro'), 'price_PRO12345prod_PRO12345', 'os ids do Stripe seguem os mesmos');
select is((select stripe_synced_at from public.plans where key = 'pro'), null, 'mas o plano fica para ser enviado de novo');

reset role;
insert into public.subscriptions (user_id, plan_key, stripe_subscription_id, status) values ('00000000-0000-0000-0000-0000000000b2', 'pro', 'sub_1', 'active');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is(public.my_features() - 'locked' - 'defaults' - 'limits', '{"plan":"pro","admin":false,"features":["entryGate","exitGate","secretRedaction","sensitiveFiles","agentSessions","contextCache","adaptiveRouting","secondOpinion"]}'::jsonb, 'assinante recebe o plano dele, com o núcleo e sem o recurso desligado pelo admin');
reset role;
update public.subscriptions set status = 'canceled';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is(public.my_features()->'features', '["entryGate","exitGate","secretRedaction","sensitiveFiles","agentSessions","contextCache","organizations","adaptiveRouting"]'::jsonb, 'assinatura cancelada volta ao padrão, com o núcleo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.admin_delete_plan('pro') $$, 'P0001', 'admin.error.inUse', 'plano com assinatura não é apagado');

select * from finish();
rollback;
