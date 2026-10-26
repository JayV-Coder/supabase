-- v0.109.0: política de validação da organização: só dono e mantenedor
-- gravam, reter commit exige a validação, e o projeto recebe a exigência (com
-- quem a faz) em `my_project_policies`, unida entre as organizações.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'membro@teste.local', now(), '{"user_name":"membro"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
insert into ids select 'beta', public.create_organization('Beta', 'beta');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'acme'), '00000000-0000-0000-0000-0000000000f2', 'member'),
  ((select id from ids where name = 'beta'), '00000000-0000-0000-0000-0000000000f2', 'member');
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id, user_id) values
  ('p-acme', 'Acme', '2026-10-26T12:00:00Z', '[]', (select id from ids where name = 'acme'), (select id::text from ids where name = 'acme'), '00000000-0000-0000-0000-0000000000f2'),
  ('p-beta', 'Beta', '2026-10-26T12:00:00Z', '[]', (select id from ids where name = 'beta'), (select id::text from ids where name = 'beta'), '00000000-0000-0000-0000-0000000000f2');

-- Sem política gravada, o projeto não recebe a exigência.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select count(*)::int from public.my_project_policies() where policy ? 'validation_required'), 0, 'sem política, a chave não existe');

-- A dona exige a validação.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select public.set_validation_policy((select id from ids where name = 'acme'), true, false);
select is((select required from public.organization_validation), true, 'grava a exigência');
select throws_ok($$select public.set_validation_policy((select id from ids where name = 'acme'), false, true)$$, 'policy.invalid', 'reter commit sem exigir não vale');
select is((select hold_commits from public.organization_validation), false, 'a recusa não mexe no que estava gravado');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select policy->'validation_required' from public.my_project_policies() where project_id = 'p-acme'), 'true'::jsonb, 'o projeto recebe a exigência');
select is((select policy->'validation_sources' from public.my_project_policies() where project_id = 'p-acme'), '["acme"]'::jsonb, 'a exigência diz quem a faz');
select is((select policy->'hold_commits' from public.my_project_policies() where project_id = 'p-acme'), 'false'::jsonb, 'sem reter commit');
select is((select count(*)::int from public.my_project_policies() where project_id = 'p-beta' and policy ? 'validation_required'), 0, 'o projeto de outra organização não recebe');

-- Membro lê, mas não grava.
select is((select count(*)::int from public.organization_validation), 1, 'o membro lê a política');
select throws_ok($$select public.set_validation_policy((select id from ids where name = 'acme'), false, false)$$, 'org.forbidden', 'o membro não grava');

-- Reter commit.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select public.set_validation_policy((select id from ids where name = 'acme'), true, true);
select public.set_validation_policy((select id from ids where name = 'beta'), true, false);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select policy->'hold_commits' from public.my_project_policies() where project_id = 'p-acme'), 'true'::jsonb, 'a organização manda reter commit');
select is((select policy->'hold_commits' from public.my_project_policies() where project_id = 'p-beta'), 'false'::jsonb, 'cada projeto segue a sua organização');

-- Desligar apaga a linha, e o projeto volta a não ter a chave.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select public.set_validation_policy((select id from ids where name = 'acme'), false, false);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select count(*)::int from public.my_project_policies() where project_id = 'p-acme' and policy ? 'validation_required'), 0, 'desligada, a chave sai da política');

select * from finish();
rollback;
