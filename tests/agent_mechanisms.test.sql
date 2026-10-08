-- v0.52.0: a política de LLM bloqueia mecanismos dos agentes (`agente/
-- mecanismo`), juntando organização, repositório e organizações diferentes
-- pela união.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'dona@teste.local', now(), '{"user_name":"dona"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
insert into ids select 'outra', public.create_organization('Outra', 'outra');
insert into ids select 'api', public.add_repository((select id from ids where name = 'acme'), 'github', 'acme/api');
insert into ids select 'x', public.add_repository((select id from ids where name = 'outra'), 'github', 'outra/x');

select throws_ok($$select public.set_llm_policy((select id from ids where name = 'acme'), null, '{"blocked_mechanisms": ["gemini/webSearch"]}')$$,
  'P0001', 'policy.invalid', 'agente desconhecido');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'acme'), null, '{"blocked_mechanisms": ["claude/web search"]}')$$,
  'P0001', 'policy.invalid', 'mecanismo fora do formato');

select lives_ok($$select public.set_llm_policy((select id from ids where name = 'acme'), null, '{"blocked_mechanisms": ["claude/webSearch", " claude/webSearch "]}')$$,
  'grava os mecanismos bloqueados');
select is((select blocked_mechanisms from public.organization_llm_policies where org_id = (select id from ids where name = 'acme')),
  array['claude/webSearch'], 'aparados e sem repetição');

select public.set_llm_policy((select id from ids where name = 'acme'), (select id from ids where name = 'api'), '{"blocked_mechanisms": ["copilot/shell"]}');
select public.set_llm_policy((select id from ids where name = 'outra'), null, '{"blocked_mechanisms": ["codex/webSearch", "claude/webSearch"]}');

insert into public.projects (id, name, created_at, repo_keys, environment_id) values
  ('p-um', 'Um', '2026-10-04T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'acme')),
  ('p-dois', 'Dois', '2026-10-04T12:00:00Z', '["github.com/acme/api","github.com/outra/x"]', (select id::text from ids where name = 'acme'));

select is((select policy->'blocked_mechanisms' from public.my_project_policies() where project_id = 'p-um'),
  '["claude/webSearch", "copilot/shell"]'::jsonb, 'a da organização junto com a do repositório');
select is((select policy->'blocked_mechanisms' from public.my_project_policies() where project_id = 'p-dois'),
  '["claude/webSearch", "copilot/shell"]'::jsonb, 'dois repositórios: vale só a organização do ambiente');

select * from finish();
rollback;
