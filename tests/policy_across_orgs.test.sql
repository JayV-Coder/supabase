-- v0.51.4: o projeto com repositórios de duas organizações roda sob a
-- política mais rígida das duas, e não só sob a do primeiro repositório.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'dona@teste.local', now(), '{"user_name":"dona"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
insert into ids select 'outra', public.create_organization('Outra', 'outra');
insert into ids select 'api', public.add_repository((select id from ids where name = 'acme'), 'github', 'acme/api');
insert into ids select 'x', public.add_repository((select id from ids where name = 'outra'), 'github', 'outra/x');
select public.set_llm_policy((select id from ids where name = 'acme'), null,
  '{"agents": ["claude", "codex"], "deny": ["secrets/**"], "min_shell": "ask"}');
select public.set_llm_policy((select id from ids where name = 'outra'), null,
  '{"agents": ["codex", "cursor"], "deny": ["*.pem", "secrets/**"], "redact_secrets": true, "min_write": "deny"}');

insert into public.projects (id, name, created_at, repo_keys, environment_id) values
  ('p-dois', 'Dois', '2026-10-04T12:00:00Z', '["github.com/acme/api","github.com/outra/x"]', (select id::text from ids where name = 'acme')),
  ('p-um', 'Um', '2026-10-04T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'acme')),
  ('p-pessoal', 'Pessoal', '2026-10-04T12:00:00Z', '["github.com/acme/api","github.com/outra/x"]', 'personal');

-- A política vale só no ambiente do projeto: no ambiente da Acme, só a da Acme.
select is((select count(*)::int from public.my_project_policies() where project_id = 'p-dois'), 1, 'uma linha por projeto');
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-dois'), '["claude", "codex"]'::jsonb, 'no ambiente da Acme vale a política da Acme');
select is((select org_slug from public.my_project_policies() where project_id = 'p-dois'), 'acme', 'e só ela');
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-um'), '["claude", "codex"]'::jsonb, 'com um repositório só, nada muda');
select is_empty($$select 1 from public.my_project_policies() where project_id = 'p-pessoal'$$, 'no ambiente pessoal a política da organização não vale');
-- Movido para o ambiente da outra organização, passa a valer a dela.
update public.projects set environment_id = (select id::text from ids where name = 'outra') where id = 'p-dois';
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-dois'), '["codex", "cursor"]'::jsonb, 'movido para a Outra, vale a da Outra');

select * from finish();
rollback;
