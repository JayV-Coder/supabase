-- v0.100.0: permissões do chat da organização: só dono e mantenedor gravam,
-- só as três permissões do seletor valem, e o projeto recebe o que está
-- bloqueado (com quem bloqueia) em `my_project_policies`.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000e1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000e2', 'membro@teste.local', now(), '{"user_name":"membro"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'acme'), '00000000-0000-0000-0000-0000000000e2', 'member');
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id, user_id) values
  ('p-acme', 'Acme', '2026-10-14T12:00:00Z', '[]', (select id from ids where name = 'acme'), (select id::text from ids where name = 'acme'), '00000000-0000-0000-0000-0000000000e2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');

select public.set_chat_permissions((select id from ids where name = 'acme'), '["git", " network ", "git"]');
select is((select blocked from public.organization_chat_permissions), array['git', 'network'], 'a lista é aparada e sem repetição');
select throws_ok($$select public.set_chat_permissions((select id from ids where name = 'acme'), '["docker"]')$$, 'policy.invalid', 'só as três permissões do seletor');
select throws_ok($$select public.set_chat_permissions((select id from ids where name = 'acme'), '"git"')$$, 'policy.invalid', 'só lista');
select is((select blocked from public.organization_chat_permissions), array['git', 'network'], 'a recusa não mexe no que estava gravado');

-- Quem é do projeto recebe o bloqueio, com a organização que o faz.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select is((select policy->'blocked_grants' from public.my_project_policies() where project_id = 'p-acme'), '["git", "network"]'::jsonb, 'o projeto recebe as permissões bloqueadas');
select is((select policy->'grant_sources'->'git' from public.my_project_policies() where project_id = 'p-acme'), '["acme"]'::jsonb, 'cada permissão diz quem a bloqueia');

-- Membro lê, mas não grava.
select is((select count(*)::int from public.organization_chat_permissions), 1, 'o membro lê as permissões');
select throws_ok($$select public.set_chat_permissions((select id from ids where name = 'acme'), '[]')$$, 'org.forbidden', 'o membro não grava');

-- Lista vazia apaga a linha, e o projeto sem política nem bloqueio some da lista.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select public.set_chat_permissions((select id from ids where name = 'acme'), '[]');
select is((select count(*)::int from public.organization_chat_permissions), 0, 'lista vazia apaga a linha');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select is((select count(*)::int from public.my_project_policies() where project_id = 'p-acme' and policy ? 'blocked_grants'), 0, 'sem bloqueio, a chave sai da política');

-- v0.101.0: permissões sempre ligadas.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select public.set_chat_permissions((select id from ids where name = 'acme'), '["network"]', '["shell", "git"]');
select is((select enabled from public.organization_chat_permissions), array['shell', 'git'], 'grava as sempre ligadas');
select throws_ok($$select public.set_chat_permissions((select id from ids where name = 'acme'), '["git"]', '["git"]')$$, 'policy.invalid', 'a mesma permissão não é bloqueada e ligada');
select throws_ok($$select public.set_chat_permissions((select id from ids where name = 'acme'), '[]', '["docker"]')$$, 'policy.invalid', 'só as três permissões do seletor, também nas ligadas');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select is((select policy->'enabled_grants' from public.my_project_policies() where project_id = 'p-acme'), '["git", "shell"]'::jsonb, 'o projeto recebe as sempre ligadas');
select is((select policy->'grant_defaults'->'shell' from public.my_project_policies() where project_id = 'p-acme'), '["acme"]'::jsonb, 'cada uma diz quem a liga');

select * from finish();
rollback;
