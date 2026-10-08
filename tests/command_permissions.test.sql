-- v0.77.0: permissões de comandos da organização: só dono e mantenedor
-- gravam, o repositório só soma ao que a organização bloqueia, e o projeto
-- recebe a união (com quem bloqueia cada regra) em `my_project_policies`.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'membro@teste.local', now(), '{"user_name":"membro"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
insert into ids select 'acme', public.create_organization('Acme', 'acme');
insert into ids select 'api', public.add_repository((select id from ids where name = 'acme'), 'github', 'acme/api');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'acme'), '00000000-0000-0000-0000-0000000000d2', 'member');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');

select public.set_command_rules((select id from ids where name = 'acme'), null, '["git push", " npm publish ", "git push", "docker"]');
select public.set_command_rules((select id from ids where name = 'acme'), (select id from ids where name = 'api'), '["git reset"]');

select is((select blocked from public.organization_command_rules where repository_id is null), array['git push', 'npm publish', 'docker'], 'a lista é aparada e sem repetição');
select throws_ok($$select public.set_command_rules((select id from ids where name = 'acme'), null, '["git; rm -rf /"]')$$, 'policy.invalid', 'comando com símbolo de shell é recusado');
select throws_ok($$select public.set_command_rules((select id from ids where name = 'acme'), null, '["a b c d"]')$$, 'policy.invalid', 'mais de três palavras é recusado');
select throws_ok($$select public.set_command_rules((select id from ids where name = 'acme'), null, '"git"')$$, 'policy.invalid', 'só lista');

insert into public.projects (id, name, created_at, repo_keys, environment_id) values
  ('p-api', 'Api', '2026-10-07T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'acme'));
select is((select policy->'blocked_commands' from public.my_project_policies() where project_id = 'p-api'),
  '["docker", "git push", "git reset", "npm publish"]'::jsonb, 'o projeto recebe a união da organização e do repositório');
select is((select policy->'command_sources'->'git reset' from public.my_project_policies() where project_id = 'p-api'), '["acme"]'::jsonb, 'cada regra diz quem a bloqueia');

-- Membro lê, mas não grava.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select is((select count(*)::int from public.organization_command_rules), 2, 'o membro lê as regras');
select throws_ok($$select public.set_command_rules((select id from ids where name = 'acme'), null, '[]')$$, 'org.forbidden', 'o membro não grava');

-- Lista vazia apaga a regra do repositório.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.set_command_rules((select id from ids where name = 'acme'), (select id from ids where name = 'api'), '[]');
select is((select count(*)::int from public.organization_command_rules where repository_id is not null), 0, 'lista vazia apaga a linha');
select is((select policy->'blocked_commands' from public.my_project_policies() where project_id = 'p-api'), '["docker", "git push", "npm publish"]'::jsonb, 'sem a regra do repositório, só a da organização');
select throws_ok($$select public.set_command_rules((select id from ids where name = 'acme'), '00000000-0000-0000-0000-00000000ffff', '["git"]')$$, 'policy.repository', 'repositório de fora é recusado');

select * from finish();
rollback;
