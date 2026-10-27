-- App 0.111.0: log de auditoria da organização, plano de cada membro e tempo
-- até o primeiro resultado comprovado.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000003a1', 'admin3@teste.local', now()),
  ('00000000-0000-0000-0000-0000000003a2', 'dona3@teste.local', now()),
  ('00000000-0000-0000-0000-0000000003a3', 'membro3@teste.local', now());
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000003a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;
create function pg_temp.utc(moment timestamptz) returns text language sql as $$
  select to_char(moment at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;
create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000003a2');
insert into ids select 'acme', public.create_organization('Acme Três', 'acme-tres');
reset role;
insert into public.organization_members (org_id, user_id, role) values ((select id from ids where name = 'acme'), '00000000-0000-0000-0000-0000000003a3', 'member');

-- O membro trabalha num projeto da organização.
select pg_temp.as_user('00000000-0000-0000-0000-0000000003a3');
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id) values
  ('p3-org', 'Loja', pg_temp.utc(now()), '[]', (select id from ids where name = 'acme'), (select id::text from ids where name = 'acme'));
insert into public.chats (id, project_id, title, created_at, updated_at) values ('c3-org', 'p3-org', 'checkout', pg_temp.utc(now()), pg_temp.utc(now()));
insert into public.turns (id, chat_id, ordinal, status, created_at) values
  ('t3-1', 'c3-org', 1, 'answered', pg_temp.utc(now() - interval '1 minute')),
  ('t3-2', 'c3-org', 2, 'answered', pg_temp.utc(now()));
insert into public.entry_checks (turn_id, at, prompt, score, demand, verdict, scope, criteria, source, note) values
  ('t3-1', pg_temp.utc(now()), 'segredo do pedido', 70, 35, 'pass', 'small', '[]', 'jev', '');
insert into public.turn_events (id, turn_id, at, seq, kind, detail) values
  ('e3-1', 't3-1', pg_temp.utc(now()), 1, 'route', '{"kind":"route","provider":"claude","model":"sonnet","mode":"build"}'),
  ('e3-2', 't3-1', pg_temp.utc(now()), 2, 'agent', '{"kind":"agent","line":"assistant: Bash"}'),
  ('e3-3', 't3-1', pg_temp.utc(now()), 3, 'agent', '{"kind":"agent","line":"assistant: Edit"}'),
  ('e3-4', 't3-1', pg_temp.utc(now()), 4, 'validate_step', '{"kind":"validate_step","step":"test","command":"npm test","status":"failed"}'),
  ('e3-5', 't3-1', pg_temp.utc(now()), 5, 'repair', '{"kind":"repair","attempt":1,"max":2}'),
  ('e3-6', 't3-1', pg_temp.utc(now()), 6, 'validate_step', '{"kind":"validate_step","step":"test","command":"npm test","status":"passed"}'),
  ('e3-7', 't3-1', pg_temp.utc(now()), 7, 'validate_end', '{"kind":"validate_end","verdict":"passed"}'),
  ('e3-8', 't3-2', pg_temp.utc(now()), 1, 'chunk', 'texto solto');
insert into public.usage_records (id, project_id, chat_id, turn_id, source, model, input_tokens, output_tokens, cost_usd, precision, created_at) values
  ('u3-1', 'p3-org', 'c3-org', 't3-1', 'claude', 'sonnet', 100, 50, 0.2, 'reported', pg_temp.utc(now())),
  ('u3-2', 'p3-org', 'c3-org', 't3-1', 'jev:entry', 'jev-latest', 900, 9, 0.01, 'reported', pg_temp.utc(now()));

-- 1. Auditoria.
select throws_ok($$ select public.org_audit((select id from ids where name = 'acme'), current_date, current_date) $$, 'org.forbidden', 'o membro não exporta a auditoria');
select pg_temp.as_user('00000000-0000-0000-0000-0000000003a2');
select throws_ok($$ select public.org_audit((select id from ids where name = 'acme'), current_date, current_date - 1) $$, 'org.auditRange', 'o período ao contrário não vale');
select throws_ok($$ select public.org_audit((select id from ids where name = 'acme'), current_date - 400, current_date) $$, 'org.auditRange', 'nem mais de um ano');
create temp table audit as select public.org_audit((select id from ids where name = 'acme'), current_date - 1, current_date + 1) as rows;
select is(jsonb_array_length((select rows from audit)), 2, 'os dois pedidos do período');
select is((select rows from audit)->1->>'turn_id', 't3-1', 'o mais novo primeiro');
select is((select rows from audit)->1->>'member', 'membro3', 'quem pediu (o nome do perfil)');
select is((select rows from audit)->1->>'project', 'Loja', 'em que projeto');
select is((select rows from audit)->1->>'agent', 'claude', 'o agente');
select is((select rows from audit)->1->>'model', 'sonnet', 'o modelo');
select is((select rows from audit)->1->'commands', '["npm test"]'::jsonb, 'os comandos validados, sem repetir');
select is((select rows from audit)->1->'tools', '["Bash", "Edit"]'::jsonb, 'as ferramentas que o agente relatou');
select is((select rows from audit)->1->>'validation', 'passed', 'o último veredito');
select is((select rows from audit)->1->>'repairs', '1', 'os reparos');
select is(((select rows from audit)->1->>'tokens')::int, 150, 'tokens do agente, sem o Jev');
select ok(position('segredo' in (select rows::text from audit)) = 0, 'o texto do pedido não sai');
select is(jsonb_array_length(public.org_audit((select id from ids where name = 'acme'), current_date + 2, current_date + 3)), 0, 'fora do período, nada');

-- 2. Plano de cada membro.
select is(jsonb_array_length(public.org_member_plans((select id from ids where name = 'acme'))->'members'), 2, 'dona e membro');

-- 3. Primeiro resultado.
select pg_temp.as_user('00000000-0000-0000-0000-0000000003a3');
select is(public.record_first_result(240), false, 'sem telemetria, nada é gravado');
select public.set_usage_telemetry(true);
select public.record_first_result(240);
select pg_temp.as_user('00000000-0000-0000-0000-0000000003a1');
select is(public.admin_first_results()->>'under_10_min', '1', 'o admin vê quem chegou em menos de 10 minutos');

select * from finish();
rollback;
