-- Site 2.11.0: os projetos da organização. Owner e maintainer listam e
-- excluem o projeto de um repositório no app de todos os membros que o têm; o
-- membro e quem é de fora, não. Só os projetos do ambiente da organização
-- entram: o projeto geral, o pessoal com o mesmo remote, o de outro
-- repositório e o de outra organização ficam como estão.
begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'mantem@teste.local', now(), '{"user_name":"mantem"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000f4', 'fora@teste.local', now(), '{"user_name":"fora"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into ids select 'api', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api');
insert into ids select 'web', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/web');
-- Sem projeto de ninguém: não aparece na lista.
insert into ids select 'docs', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/docs');
-- Outra organização, de quem é de fora da Acme, com o mesmo repositório.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
insert into ids select 'beta', public.create_organization('Beta', 'beta');
insert into ids select 'beta_api', public.add_repository((select id from ids where name = 'beta'), 'github', 'acme/api');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000f2', 'maintainer'),
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000f3', 'member');

-- Cada membro tem a própria linha para o mesmo repositório, no ambiente da organização.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into public.projects (id, name, created_at, repo_keys, environment_id) values
  ('p-dona-api', 'api', '2026-10-01T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'org'));
insert into public.chats (id, code, project_id, title, created_at, updated_at) values
  ('c-dona-api', 'f1a', 'p-dona-api', 'Chat', '2026-10-01T12:00:00Z', '2026-10-05T09:30:00-03:00');

-- O relógio deste computador está adiantado: a marca não pode recuar.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
insert into public.projects (id, name, created_at, repo_keys, environment_id, row_updated_at) values
  ('p-mantem-api', 'api', '2026-10-04T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'org'), '2999-01-01T00:00:00Z');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id, row_updated_at) values
  ('p-membro-api', 'api', '2026-10-02T12:00:00Z', '["github.com/acme/api"]', null, (select id::text from ids where name = 'org'), '2000-01-01T12:00:00Z'),
  ('p-membro-web', 'web', '2026-10-06T12:00:00Z', '["github.com/acme/web"]', null, (select id::text from ids where name = 'org'), '2000-01-01T12:00:00Z'),
  -- Dois remotes: vale o primeiro (o `origin`), então é do web.
  ('p-membro-fork', 'fork', '2026-10-07T12:00:00Z', '["github.com/acme/web", "github.com/acme/api"]', null, (select id::text from ids where name = 'org'), '2000-01-01T12:00:00Z'),
  -- O mesmo remote, aberto no ambiente pessoal: é da pessoa.
  ('p-membro-pessoal', 'api', '2026-10-08T12:00:00Z', '["github.com/acme/api"]', null, 'personal', '2000-01-01T12:00:00Z'),
  -- O projeto geral do chat da organização.
  ('p-membro-geral', 'Acme', '2026-10-08T12:00:00Z', '[]', (select id from ids where name = 'org'), 'personal', '2000-01-01T12:00:00Z');
insert into public.chats (id, code, project_id, title, created_at, updated_at, row_updated_at) values
  ('c-membro-api', 'f3a', 'p-membro-api', 'Chat', '2026-10-02T12:00:00Z', '2026-10-03T12:00:00Z', '2000-01-01T12:00:00Z'),
  ('c-membro-pessoal', 'f3b', 'p-membro-pessoal', 'Chat', '2026-10-08T12:00:00Z', '2026-10-08T12:00:00Z', '2000-01-01T12:00:00Z'),
  ('c-membro-geral', 'f3c', 'p-membro-geral', 'Chat', '2026-10-08T12:00:00Z', '2026-10-08T12:00:00Z', '2000-01-01T12:00:00Z');
-- Um chat já apagado não conta nem como atividade.
insert into public.chats (id, code, project_id, title, created_at, updated_at, row_updated_at, row_deleted_at) values
  ('c-membro-velho', 'f3d', 'p-membro-api', 'Velho', '2026-10-02T12:00:00Z', '2026-10-09T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.turns (id, chat_id, ordinal, status, created_at, row_updated_at) values
  ('t-membro-api', 'c-membro-api', 1, 'answered', '2026-10-03T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.messages (uid, chat_id, turn_id, role, content, created_at, row_updated_at) values
  ('m-membro-api', 'c-membro-api', 't-membro-api', 'user', 'oi', '2026-10-03T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.project_notes (id, project_id, kind, body, created_at, updated_at, row_updated_at) values
  ('n-membro-api', 'p-membro-api', 'note', 'Os testes rodam com npm test.', '2026-10-03T12:00:00Z', '2026-10-03T12:00:00Z', '2000-01-01T12:00:00Z');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
insert into public.projects (id, name, created_at, repo_keys, environment_id) values
  ('p-fora-beta', 'api', '2026-10-08T12:00:00Z', '["github.com/acme/api"]', (select id::text from ids where name = 'beta'));

-- A lista: um repositório por linha, só os que alguém tem.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select is((select array_agg(repo_key order by repo_key) from public.org_projects((select id from ids where name = 'org'))),
  array['github.com/acme/api', 'github.com/acme/web'], 'um repositório por linha, só os que algum membro tem como projeto');
select is((select members from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'api')),
  3::bigint, 'conta os membros que têm o repositório, não o projeto pessoal nem o geral');
select is((select members from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'web')),
  1::bigint, 'dois projetos da mesma pessoa contam como um membro; o primeiro remote decide o repositório');
select is((select chats from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'api')),
  2::bigint, 'só os chats vivos');
select is((select last_activity from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'api')),
  '2026-10-05T12:30:00Z'::timestamptz, 'a última atividade é o chat mais recente, lido com o fuso que o app gravou');
select is((select last_activity from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'web')),
  '2026-10-07T12:00:00Z'::timestamptz, 'sem chat, vale o projeto mais novo');
select is((select path from public.org_projects((select id from ids where name = 'org')) where repository_id = (select id from ids where name = 'api')),
  'acme/api', 'traz o caminho do repositório');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select count(*) from public.org_projects((select id from ids where name = 'org'))), 2::bigint, 'o maintainer também lista');

-- Quem não gere a organização não lista nem exclui.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select throws_ok($$select * from public.org_projects((select id from ids where name = 'org'))$$, 'P0001', 'org.forbidden', 'o membro não lista');
select throws_ok($$select public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'api'))$$,
  'P0001', 'org.forbidden', 'o membro não exclui');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
select throws_ok($$select * from public.org_projects((select id from ids where name = 'org'))$$, 'P0001', 'org.forbidden', 'quem é de fora não lista');
select throws_ok($$select public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'api'))$$,
  'P0001', 'org.forbidden', 'quem é de fora não exclui');
select throws_ok($$select public.org_project_links((select id from ids where name = 'org'))$$, '42501', null, 'a ligação dos projetos é interna');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select throws_ok($$select public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'beta_api'))$$,
  'P0001', 'org.repoGone', 'o repositório de outra organização é recusado');

create temp table before_delete on commit drop as select clock_timestamp() as at;
grant all on before_delete to authenticated;

-- O maintainer exclui o projeto do api no app de todos.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is(public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'api')), 3,
  'exclui o projeto de cada membro que tem o repositório');
reset role;
select isnt((select row_deleted_at from public.projects where id = 'p-membro-api'), null, 'o projeto de outro membro é excluído');
select is((select row_updated_at from public.projects where id = 'p-membro-api'), now(), 'com o row_updated_at da exclusão');
select ok((select synced_at >= (select at from before_delete) from public.projects where id = 'p-membro-api'),
  'o synced_at anda, para o app do membro baixar a exclusão');
select is((select row_updated_at from public.projects where id = 'p-mantem-api'), '2999-01-01T00:00:00Z'::timestamptz,
  'o row_updated_at adiantado não recua');
select isnt((select row_deleted_at from public.projects where id = 'p-mantem-api'), null, 'e a exclusão não é descartada como escrita atrasada');
select isnt((select row_deleted_at from public.projects where id = 'p-dona-api'), null, 'o da owner também');
select isnt((select row_deleted_at from public.chats where id = 'c-membro-api'), null, 'os chats vão junto');
select isnt((select row_deleted_at from public.messages where uid = 'm-membro-api'), null, 'e as mensagens deles');
select isnt((select row_deleted_at from public.project_notes where id = 'n-membro-api'), null, 'e as notas do projeto');
select is(
  (select count(*) from public.projects where id in ('p-membro-web', 'p-membro-fork', 'p-membro-pessoal', 'p-membro-geral', 'p-fora-beta') and row_deleted_at is null),
  5::bigint, 'o outro repositório, o pessoal, o geral e o da outra organização ficam');
select is((select count(*) from public.chats where id in ('c-membro-pessoal', 'c-membro-geral') and row_deleted_at is null), 2::bigint,
  'e os chats deles');
select is((select count(*) from public.organization_repositories where id = (select id from ids where name = 'api')), 1::bigint,
  'o repositório continua na organização');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select is((select array_agg(repo_key) from public.org_projects((select id from ids where name = 'org'))), array['github.com/acme/web'],
  'a lista fica só com o que sobrou');
select is(public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'api')), 0,
  'excluir de novo não acha nada');

-- A owner exclui o outro.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select is(public.delete_org_project((select id from ids where name = 'org'), (select id from ids where name = 'web')), 2,
  'a owner exclui os dois projetos do web');
select is_empty($$select * from public.org_projects((select id from ids where name = 'org'))$$, 'nada mais na lista');
reset role;
select is((select row_deleted_at from public.projects where id = 'p-membro-pessoal'), null, 'o projeto pessoal continua vivo');

select * from finish();
rollback;
