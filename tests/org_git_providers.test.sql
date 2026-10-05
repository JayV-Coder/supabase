-- O provedor git da organização e os repositórios associados por ele: só o
-- owner conecta, associa e remove; todo membro lê.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e1', 'owner@teste.local'),
  ('00000000-0000-0000-0000-0000000000e2', 'maint@teste.local'),
  ('00000000-0000-0000-0000-0000000000e3', 'membro@teste.local'),
  ('00000000-0000-0000-0000-0000000000e4', 'fora@teste.local');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
insert into ids select 'org', public.create_organization('Acme', 'acme-git');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000e2', 'maintainer'),
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000e3', 'member');

-- Conectar.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select throws_ok($$select public.org_connect_git((select id from ids where name = 'org'), 'github', 'acme-bot')$$, 'P0001', 'org.forbidden', 'maintainer não conecta provedor');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select throws_ok($$select public.org_link_repositories((select id from ids where name = 'org'), 'github', '[{"path":"acme/api"}]')$$, 'P0001', 'org.gitNotConnected', 'sem provedor conectado não associa');
select lives_ok($$select public.org_connect_git((select id from ids where name = 'org'), 'github', 'acme-bot')$$, 'owner conecta o GitHub');
select lives_ok($$select public.org_connect_git((select id from ids where name = 'org'), 'github', 'acme-admin')$$, 'reconectar troca a conta');
select is((select account from public.organization_git_connections), 'acme-admin', 'uma conexão por provedor');
select throws_ok($$select public.org_connect_git((select id from ids where name = 'org'), 'gitea', 'x')$$, 'P0001', 'org.repoInvalid', 'provedor fora da lista');

-- Associar.
select is(public.org_link_repositories((select id from ids where name = 'org'), 'github',
  '[{"path":"Acme/API","external_id":"42","default_branch":"main","private":true,"description":"A API","web_url":"https://github.com/acme/api"},{"path":"acme/web.git","private":false,"web_url":"javascript:alert(1)"}]'),
  2, 'owner associa dois repositórios');
select is((select (repo_key, private, default_branch, linked_via)::text from public.organization_repositories where path = 'acme/api'), '(github.com/acme/api,t,main,provider)', 'os dados do provedor ficam gravados');
select is((select web_url from public.organization_repositories where path = 'acme/web'), null, 'endereço que não é https é descartado');
select is(public.org_link_repositories((select id from ids where name = 'org'), 'github', '[{"path":"acme/api","default_branch":"develop","private":true}]'), 1, 'associar de novo atualiza');
select is((select count(*)::int from public.organization_repositories), 2, 'sem repetir o repositório');
select is((select default_branch from public.organization_repositories where path = 'acme/api'), 'develop', 'com os dados novos');
select throws_ok($$select public.org_link_repositories((select id from ids where name = 'org'), 'github', '[{"path":"so-um"}]')$$, 'P0001', 'org.repoInvalid', 'caminho sem dono recusa');

-- Ler, remover e desconectar.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e3');
select is((select count(*)::int from public.organization_git_connections), 1, 'o membro vê o provedor conectado');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e4');
select is((select count(*)::int from public.organization_git_connections), 0, 'quem está fora não vê');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select throws_ok($$select public.remove_repository((select id from public.organization_repositories where path = 'acme/web'))$$, 'P0001', 'org.forbidden', 'maintainer não remove repositório');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select public.org_disconnect_git((select id from ids where name = 'org'), 'github');
select is((select (select count(*) from public.organization_git_connections) || '/' || (select count(*) from public.organization_repositories)), '0/2', 'desconectar mantém os repositórios');

reset role;
select * from finish();
rollback;
