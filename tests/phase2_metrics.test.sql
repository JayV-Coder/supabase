-- App 0.110.0: preços por modelo, teto do Jev em pedidos, custo do Jev para o
-- admin, uso da equipe por semana e telemetria opcional dos recursos.
begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000002a1', 'admin@teste.local', now()),
  ('00000000-0000-0000-0000-0000000002a2', 'dona@teste.local', now()),
  ('00000000-0000-0000-0000-0000000002a3', 'membro@teste.local', now());
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000002a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;
create function pg_temp.utc(moment timestamptz) returns text language sql as $$
  select to_char(moment at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;
create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- 1. Preços.
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a1');
select lives_ok($$ select public.admin_save_model_price(' GPT ', 1, 2) $$, 'o admin grava um preço');
select lives_ok($$ select public.admin_save_model_price('gpt-5-mini', 0.5, 1, 0.01, null) $$, 'e outro, mais específico');
select is((select pattern from public.model_prices order by pattern limit 1), 'gpt', 'o padrão fica em minúsculas, sem espaço');
select throws_ok($$ select public.admin_save_model_price('x', -1, 2) $$, 'admin.error.priceInvalid', 'preço negativo não vale');
select throws_ok($$ select public.admin_save_model_price('gpt', 1, 2, null, null, 'gpt-5-mini') $$, 'admin.error.priceDuplicate', 'renomear para um padrão que já existe não vale');
select lives_ok($$ select public.admin_save_model_price('opus', 5, 25, null, null, 'gpt-5-mini') $$, 'renomeia o padrão');
select is((select count(*)::int from public.model_prices where pattern = 'gpt-5-mini'), 0, 'o nome antigo sai');
select lives_ok($$ select public.admin_save_model_price('gpt-5-mini', 0.5, 1, 0.01, null) $$, 'grava de novo');
reset role;
select is(public.usage_money('GPT-5-mini-2026', null, 1000000, 0, 1000000, 0), 0.51::double precision, 'o padrão mais longo vence, com o preço do cache lido');
select is(public.usage_money('gpt-4', null, 0, 0, 1000000, 1000000), 0.1::double precision + 1.25, 'cache sem preço: um décimo e 1,25× da entrada');
select is(public.usage_money('sonnet', 0.25, 9999, 9999, 0, 0), 0.25::double precision, 'o custo informado vence a tabela');
select is(public.usage_money('sonnet', null, 10, 10, 0, 0), null, 'sem custo e sem preço, nulo');

select pg_temp.as_user('00000000-0000-0000-0000-0000000002a3');
select is((select count(*)::int from public.model_prices), 3, 'quem entrou lê a tabela');
select throws_ok($$ select public.admin_save_model_price('x', 1, 1) $$, 'admin.forbidden', 'só o admin grava');

-- 2. Teto em pedidos.
reset role;
select is((select jev_daily_requests from public.plans where is_default), 20, 'o plano padrão começa com 20 pedidos por dia');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a3');
select is(public.my_jev_request_limit(), 20, 'quem está no Free tem o teto');
select is((public.my_features()->'limits'->>'jevDailyRequests')::int, 20, 'e o app o recebe em my_features');
select is(public.jev_count_turn('turn-1'), 1, 'o primeiro pedido conta');
select is(public.jev_count_turn('turn-1'), 1, 'outra chamada do mesmo pedido não conta de novo');
select is(public.jev_count_turn('turn-2'), 2, 'outro pedido conta');
select throws_ok($$ select public.jev_count_turn('não vale') $$, 'jev.turnInvalid', 'id fora do formato');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a1');
select is(public.my_jev_request_limit(), null, 'o admin do sistema não tem teto');
select lives_ok($$ select public.admin_set_plan_jev_requests((select key from public.plans where is_default), 30) $$, 'o admin muda o teto');
reset role;
select is((select jev_daily_requests from public.plans where is_default), 30, 'o teto novo vale');

-- 3. Custo do Jev para o admin.
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a3');
insert into public.projects (id, name, created_at) values ('p-pessoal', 'app', pg_temp.utc(now()));
insert into public.usage_records (id, project_id, chat_id, turn_id, source, model, input_tokens, output_tokens, precision, created_at) values
  ('jev-1', 'p-pessoal', 'c-x', 't-x', 'jev:entry', 'jev-latest', 1000, 10, 'reported', pg_temp.utc(now())),
  ('jev-2', 'p-pessoal', 'c-x', 't-x', 'jev:routing', 'jev-latest', 1000, 10, 'reported', pg_temp.utc(now()));
select throws_ok($$ select public.admin_jev_costs(30) $$, 'admin.forbidden', 'só o admin vê o custo do Jev');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a1');
select is(public.admin_jev_costs(30)->'plans'->0->>'requests', '1', 'as duas chamadas são um pedido');
select is(public.admin_jev_costs(30)->'top'->0->>'email', 'membro@teste.local', 'quem mais gastou');

-- 4. Uso da equipe.
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a2');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
reset role;
insert into public.organization_members (org_id, user_id, role) values ((select id from ids where name = 'acme'), '00000000-0000-0000-0000-0000000002a3', 'member');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a3');
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id) values
  ('p-org', 'Org', pg_temp.utc(now()), '[]', (select id from ids where name = 'acme'), (select id::text from ids where name = 'acme'));
insert into public.chats (id, project_id, title, created_at, updated_at) values ('c-org', 'p-org', 'objetivo', pg_temp.utc(now()), pg_temp.utc(now()));
insert into public.turns (id, chat_id, ordinal, status, created_at) values
  ('t-org-1', 'c-org', 1, 'answered', pg_temp.utc(now())),
  ('t-org-2', 'c-org', 2, 'answered', pg_temp.utc(now()));
insert into public.usage_records (id, project_id, chat_id, turn_id, source, model, input_tokens, output_tokens, cost_usd, precision, created_at) values
  ('u-org-1', 'p-org', 'c-org', 't-org-1', 'codex', 'gpt-5', 1000000, 0, null, 'reported', pg_temp.utc(now())),
  ('u-org-2', 'p-org', 'c-org', 't-org-2', 'claude', 'sonnet', 10, 10, 0.5, 'reported', pg_temp.utc(now())),
  ('u-org-3', 'p-org', 'c-org', 't-org-2', 'jev:entry', 'jev-latest', 5000, 5, null, 'reported', pg_temp.utc(now()));
insert into public.jev_records (id, project_id, chat_id, turn_id, kind, amount, precision, created_at) values
  ('j-org-1', 'p-org', 'c-org', 't-org-1', 'validation:failed', 1, 'reported', pg_temp.utc(now() - interval '1 second')),
  ('j-org-2', 'p-org', 'c-org', 't-org-1', 'validation:passed', 1, 'reported', pg_temp.utc(now())),
  ('j-org-3', 'p-org', 'c-org', 't-org-2', 'entry:pass', 1, 'reported', pg_temp.utc(now()));
select throws_ok($$ select public.org_usage((select id from ids where name = 'acme'), 4) $$, 'org.forbidden', 'o membro não vê o uso da equipe');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a2');
select is(public.org_usage((select id from ids where name = 'acme'), 4)->'series'->-1->>'requests', '2', 'os pedidos da semana');
select is(public.org_usage((select id from ids where name = 'acme'), 4)->'series'->-1->>'verified', '1', 'o turno vale pelo último veredito');
select is((public.org_usage((select id from ids where name = 'acme'), 4)->'series'->-1->>'cost_usd')::numeric, 1.5, 'dinheiro informado + estimado, sem o Jev');

-- 5. Telemetria.
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a3');
select is(public.record_feature_usage(('[{"feature":"stats","day":"' || (now() at time zone 'utc')::date || '","uses":3}]')::jsonb), 0, 'sem consentimento nada entra');
select public.set_usage_telemetry(true);
select is(public.record_feature_usage(('[{"feature":"stats","day":"' || (now() at time zone 'utc')::date || '","uses":3},{"feature":"naoexiste","day":"' || (now() at time zone 'utc')::date || '","uses":1},{"feature":"stats","day":"2000-01-01","uses":1}]')::jsonb), 1, 'só o recurso do catálogo, no dia certo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000002a1');
select is((select x->>'uses_30' from jsonb_array_elements(public.admin_feature_usage()->'features') x where x->>'feature' = 'stats'), '3', 'o admin vê o uso em 30 dias');

select * from finish();
rollback;
