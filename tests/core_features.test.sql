-- v0.60.0: recursos de núcleo, recursos travados por plano e limites do plano.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@teste.local'),
  ('00000000-0000-0000-0000-0000000000b2', 'user@teste.local');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select is((select array_agg(key order by key) from public.features where core),
  array['adaptiveRouting','agentSessions','contextCache','entryGate','exitGate','secretRedaction','sensitiveFiles'], 'os recursos de núcleo');
select is((select count(*) from public.plan_features where plan_key = 'free' and mode = 'locked'), 7::bigint, 'o plano que já existia ganha o núcleo travado');
select is((select default_on from public.plan_features where plan_key = 'free' and feature_key = 'symbolIndex'), false, 'o índice de símbolos entra desligado, como na tela');
select is((select default_on from public.plan_features where plan_key = 'free' and feature_key = 'answerRecall'), true, 'a resposta já dada entra ligada, como hoje');
select throws_ok($$ update public.features set enabled = false where key = 'secretRedaction' $$, '23514', null, 'nem pelo SQL o núcleo desliga');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is(public.my_features()->'locked', '["entryGate","exitGate","secretRedaction","sensitiveFiles","agentSessions","contextCache","adaptiveRouting"]'::jsonb, 'o núcleo vem travado');
select is(public.my_features()->'defaults'->'symbolIndex', 'false'::jsonb, 'o valor de partida do opcional');
select is(public.my_features()->'limits', '{"jevDailyLimit":null,"maxConcurrentTurns":1}'::jsonb, 'os limites do plano');
select is(public.my_jev_daily_limit(), null::integer, 'sem limite próprio, vale o da função');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.admin_set_feature('secretRedaction', false) $$, 'P0001', 'admin.error.coreFeature', 'o admin não desliga recurso de núcleo');
select lives_ok($$ select public.admin_set_feature('secretRedaction', true) $$, 'ligar o que já está ligado não é erro');
select lives_ok($$ select public.admin_save_plan('{"key":"team","name":"Team","stripe_price_id":"price_TEAM1234","price_cents":9900,"currency":"brl","billing_interval":"month","jev_daily_limit":2000,"max_concurrent_turns":3,"features":[{"key":"parallelTasks","mode":"locked"},{"key":"secondOpinion","mode":"optional","default_on":false},"stats"]}') $$, 'o plano novo com modos e limites');
select is((select count(*) from public.plan_features where plan_key = 'team' and mode = 'locked'), 8::bigint, 'o núcleo entra travado sem estar na lista, mais o travado pelo admin');
select is((select (mode, default_on)::text from public.plan_features where plan_key = 'team' and feature_key = 'secondOpinion'), '(optional,f)', 'opcional desligado de partida');
select throws_ok($$ select public.admin_save_plan('{"key":"team","name":"Team","features":[{"key":"stats","mode":"forever"}]}') $$, 'P0001', 'admin.error.planInvalid', 'modo fora da lista recusa');
select throws_ok($$ select public.admin_save_plan('{"key":"team","name":"Team","max_concurrent_turns":20,"features":[]}') $$, 'P0001', 'admin.error.planInvalid', 'concorrência fora do limite recusa');
select lives_ok($$ select public.admin_save_plan('{"key":"team","name":"Team","stripe_price_id":"price_TEAM1234","features":["stats"]}') $$, 'o formato antigo, só chaves, continua valendo');
select is((select count(*) from public.plan_features where plan_key = 'team' and mode = 'locked'), 7::bigint, 'e o núcleo continua travado');

reset role;
insert into public.subscriptions (user_id, plan_key, stripe_subscription_id, status) values ('00000000-0000-0000-0000-0000000000b2', 'team', 'sub_team', 'active');
update public.plans set jev_daily_limit = 2000 where key = 'team';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is(public.my_jev_daily_limit(), 2000, 'o assinante recebe o limite do plano dele');

select * from finish();
rollback;
