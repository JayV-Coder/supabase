-- Ambientes: o pessoal e um por organização. O ambiente de um projeto vem do
-- `org_id` e leva tudo que depende dele, decidido no banco; as configurações
-- guardam o que o cliente manda; a cota é da conta e não tem ambiente.
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000e1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000e2', 'outra@teste.local', now(), '{"user_name":"outra"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into ids select 'org2', public.create_organization('Beta', 'beta');

-- Os ambientes de quem chama.
select is(
  (select jsonb_agg(e->>'id' order by ord) from jsonb_array_elements(public.my_environments()) with ordinality as t(e, ord)),
  jsonb_build_array('personal', (select id::text from ids where name = 'org'), (select id::text from ids where name = 'org2')),
  'o pessoal primeiro, depois uma organização por nome');
select is((select e->>'role' from jsonb_array_elements(public.my_environments()) e where e->>'slug' = 'acme'), 'owner', 'cada ambiente traz o papel');

-- O projeto geral da organização e o pessoal.
insert into public.projects (id, name, created_at, repo_keys, org_id) values
  ('p-org', 'Geral', '2026-10-08T12:00:00Z', '[]', (select id from ids where name = 'org')),
  ('p-own', 'Meu', '2026-10-08T12:00:00Z', '[]', null);
select is((select environment_id from public.projects where id = 'p-org'), (select id::text from ids where name = 'org'), 'o org_id decide o ambiente do projeto');
select is((select environment_id from public.projects where id = 'p-own'), 'personal', 'sem organização, é pessoal');

-- O que depende do projeto segue o projeto, mesmo que o cliente mande outro valor.
insert into public.chats (id, code, project_id, title, named, created_at, updated_at, environment_id) values
  ('c-org', 'a1', 'p-org', 'Chat', 0, '2026-10-08T12:00:00Z', '2026-10-08T12:00:00Z', 'personal');
insert into public.turns (id, chat_id, ordinal, status, created_at) values ('t-org', 'c-org', 1, 'done', '2026-10-08T12:00:00Z');
insert into public.messages (uid, chat_id, turn_id, role, content, created_at) values ('m-org', 'c-org', 't-org', 'user', 'oi', '2026-10-08T12:00:00Z');
insert into public.turn_events (id, turn_id, at, seq, kind, detail) values ('e-org', 't-org', '2026-10-08T12:00:00Z', 1, 'done', '{}');
insert into public.usage_records (id, project_id, source, model, precision, created_at) values ('u-org', 'p-org', 'claude', 'm', 'reported', '2026-10-08T12:00:00Z');
insert into public.usage_records (id, project_id, source, model, precision, created_at) values ('u-none', null, 'claude', 'm', 'reported', '2026-10-08T12:00:00Z');
select is((select environment_id from public.chats where id = 'c-org'), (select id::text from ids where name = 'org'), 'o chat segue o projeto, não o valor que o cliente mandou');
select is((select environment_id from public.turns where id = 't-org'), (select id::text from ids where name = 'org'), 'o turno segue o chat');
select is((select environment_id from public.messages where uid = 'm-org'), (select id::text from ids where name = 'org'), 'a mensagem segue o chat');
select is((select environment_id from public.turn_events where id = 'e-org'), (select id::text from ids where name = 'org'), 'o evento segue o turno');
select is((select environment_id from public.usage_records where id = 'u-org'), (select id::text from ids where name = 'org'), 'o uso segue o projeto');
select is((select environment_id from public.usage_records where id = 'u-none'), 'personal', 'o uso sem projeto fica no que o cliente mandou');

-- Um projeto que muda de organização leva tudo junto.
update public.projects set org_id = (select id from ids where name = 'org2') where id = 'p-org';
select is((select environment_id from public.messages where uid = 'm-org'), (select id::text from ids where name = 'org2'), 'trocar a organização do projeto leva chats, turnos e mensagens');
select is((select environment_id from public.usage_records where id = 'u-org'), (select id::text from ids where name = 'org2'), 'e o uso');

-- O id de outro usuário não revela o ambiente dele.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
insert into public.chats (id, code, project_id, title, named, created_at, updated_at, environment_id) values
  ('c-spy', 'a2', 'p-org', 'Intruso', 0, '2026-10-08T12:00:00Z', '2026-10-08T12:00:00Z', 'personal');
select is((select environment_id from public.chats where id = 'c-spy'), 'personal', 'o projeto de outro dono não conta');

-- Configurações guardam o que o cliente manda; valor inválido é recusado.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
insert into public.account_settings (key, value, updated_at, environment_id) values ('expertise', 'senior', '2026-10-08T12:00:00Z', (select id::text from ids where name = 'org'));
select is((select environment_id from public.account_settings where key = 'expertise'), (select id::text from ids where name = 'org'), 'a configuração fica no ambiente que o cliente disse');
select throws_ok($$insert into public.account_settings (key, value, updated_at, environment_id) values ('x', 'y', 'z', 'qualquer coisa')$$, '23514', null, 'ambiente que não é personal nem um id é recusado');

-- Projeto sem organização guarda o ambiente do banco que o mandou, se a pessoa é membro.
insert into public.projects (id, name, created_at, repo_keys, org_id, environment_id) values
  ('p-clone', 'Clone', '2026-10-08T12:00:00Z', '["github.com/acme/api"]', null, (select id::text from ids where name = 'org'));
select is((select environment_id from public.projects where id = 'p-clone'), (select id::text from ids where name = 'org'), 'o projeto sem org_id fica no ambiente que o banco mandou');
insert into public.chats (id, code, project_id, title, named, created_at, updated_at) values ('c-clone', 'a3', 'p-clone', 'Chat', 0, '2026-10-08T12:00:00Z', '2026-10-08T12:00:00Z');
select is((select environment_id from public.chats where id = 'c-clone'), (select id::text from ids where name = 'org'), 'e o chat dele vai junto');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select throws_ok($$insert into public.projects (id, name, created_at, repo_keys, environment_id) values ('p-bad', 'X', '2026-10-08T12:00:00Z', '[]', (select id::text from ids where name = 'org'))$$, '42501', 'environment.forbidden', 'quem não é membro não grava no ambiente da organização');
insert into public.projects (id, name, created_at, repo_keys, org_id) values ('p-bad2', 'X', '2026-10-08T12:00:00Z', '[]', (select id from ids where name = 'org'));
select is((select environment_id from public.projects where id = 'p-bad2'), 'personal', 'dizer o org_id sem ser membro nunca deu vínculo: fica no pessoal');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');

-- O mesmo ajuste, agente e modelo existem em cada ambiente sem se pisar.
insert into public.account_settings (key, value, updated_at, environment_id) values ('expertise', 'junior', '2026-10-08T12:00:00Z', 'personal');
select is((select count(*) from public.account_settings where key = 'expertise'), 2::bigint, 'a mesma chave de configuração vive em dois ambientes');
insert into public.llm_agents (id, enabled, command, timeout, updated_at, environment_id) values
  ('claude', 1, 'claude', 600, '2026-10-08T12:00:00Z', 'personal'),
  ('claude', 0, 'claude', 600, '2026-10-08T12:00:00Z', (select id::text from ids where name = 'org'));
insert into public.llm_models (agent, model, cost_class, speed, context_window, environment_id) values
  ('claude', 'm1', 'low', 'fast', 1000, 'personal'),
  ('claude', 'm1', 'low', 'fast', 1000, (select id::text from ids where name = 'org'));
select is((select count(*) from public.llm_agents where id = 'claude'), 2::bigint, 'o mesmo agente vive em dois ambientes');
select is((select count(*) from public.llm_models where model = 'm1'), 2::bigint, 'o mesmo modelo vive em dois ambientes');
select throws_ok($$insert into public.llm_models (agent, model, cost_class, speed, context_window, environment_id) values ('claude', 'm2', 'low', 'fast', 1, (select id::text from ids where name = 'org2'))$$, '23503', null, 'o modelo aponta para o agente do próprio ambiente');

-- A cota é da conta.
select hasnt_column('public', 'quota_snapshots', 'environment_id', 'a cota não tem ambiente');

select * from finish();
rollback;
