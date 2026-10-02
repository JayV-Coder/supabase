-- Política de LLM: quem grava, o que o banco recusa, quem lê e a junção da
-- política da organização com a do repositório que associa o projeto.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000b1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'manu@teste.local', now(), '{"user_name":"manu"}'),
  ('00000000-0000-0000-0000-0000000000b3', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000b4', 'fora@teste.local', now(), '{"user_name":"fora"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- A organização, com um maintainer, um member e dois repositórios; e outra
-- organização, para o repositório de fora.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into ids select 'other', public.create_organization('Outra', 'outra');
insert into ids select 'api', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api');
insert into ids select 'web', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/web');
insert into ids select 'foreign', public.add_repository((select id from ids where name = 'other'), 'github', 'outra/x');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000b2', 'maintainer'),
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000b3', 'member');

-- Quem grava.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"safe_agents": true}')$$, 'P0001', 'org.forbidden', 'member não grava política');
select throws_ok($$select public.clear_llm_policy((select id from ids where name = 'org'), null)$$, 'P0001', 'org.forbidden', 'member não remove política');
select throws_ok($$insert into public.organization_llm_policies (org_id) values ((select id from ids where name = 'org'))$$, '42501', null, 'ninguém escreve direto');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select lives_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{
  "agents": ["codex", "claude", "copilot"], "blocked_models": [" claude/opus ", "claude/opus", ""],
  "deny": ["secrets/**"], "local_only": ["internal/**"], "min_write": "ask", "min_shell": "ask"
}')$$, 'maintainer grava a política da organização');
select is((select agents from public.organization_llm_policies where repository_id is null), array['claude', 'codex', 'copilot'], 'agentes na ordem do app');
select is((select blocked_models from public.organization_llm_policies where repository_id is null), array['claude/opus'], 'lista aparada e sem repetição');
select lives_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"agents": ["claude", "codex", "copilot"], "blocked_models": ["claude/opus"], "deny": ["secrets/**"], "local_only": ["internal/**"], "min_write": "ask", "min_shell": "ask"}')$$, 'gravar de novo troca a política');
select is((select count(*)::int from public.organization_llm_policies), 1, 'uma política por organização');

-- O que o banco recusa.
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"agents": []}')$$, 'P0001', 'policy.invalid', 'nenhum agente');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"agents": ["gemini"]}')$$, 'P0001', 'policy.invalid', 'agente desconhecido');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"blocked_models": ["opus"]}')$$, 'P0001', 'policy.invalid', 'modelo sem agente');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"min_shell": "maybe"}')$$, 'P0001', 'policy.invalid', 'regra de saída desconhecida');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"safe_agents": "talvez"}')$$, 'P0001', 'policy.invalid', 'booleano inválido');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), null, '{"deny": "secrets/**"}')$$, 'P0001', 'policy.invalid', 'padrões fora de uma lista');
select throws_ok($$select public.set_llm_policy((select id from ids where name = 'org'), (select id from ids where name = 'foreign'), '{}')$$, 'P0001', 'policy.repository', 'repositório de outra organização');
select is((select agents from public.organization_llm_policies where repository_id is null), array['claude', 'codex', 'copilot'], 'a recusa não apaga a política anterior');

-- A política do repositório.
select lives_ok($$select public.set_llm_policy((select id from ids where name = 'org'), (select id from ids where name = 'api'), '{
  "agents": ["codex", "cursor"], "blocked_models": ["codex/o3", "claude/opus"], "deny": ["*.sql"], "safe_agents": true, "min_write": "deny", "min_read": "ask"
}')$$, 'maintainer grava a política de um repositório');

-- Quem lê.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select is((select count(*)::int from public.organization_llm_policies), 2, 'member lê as políticas');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b4');
select is_empty($$select 1 from public.organization_llm_policies$$, 'quem não é membro não lê');
select throws_ok($$select public.llm_policy_of((select id from ids where name = 'org'), null)$$, '42501', null, 'a junção é interna');

-- A junção, pelo projeto de um member: o fork casa pelo upstream `acme/api`.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
insert into public.projects (id, name, created_at, repo_keys) values
  ('p-api', 'Api', '2026-10-02T12:00:00Z', '["github.com/membro/api","github.com/acme/api"]'),
  ('p-web', 'Web', '2026-10-02T12:00:00Z', '["github.com/acme/web"]'),
  ('p-solto', 'Solto', '2026-10-02T12:00:00Z', '["github.com/membro/solto"]');
select is(public.project_repository('p-api'), (select id from ids where name = 'api'), 'o repositório que associa o projeto');
select is((select policy from public.my_project_policies() where project_id = 'p-api'),
  '{"agents": ["codex"], "blocked_models": ["claude/opus", "codex/o3"], "deny": ["secrets/**", "*.sql"], "local_only": ["internal/**"],
    "safe_agents": true, "redact_secrets": false, "min_read": "ask", "min_write": "deny", "min_shell": "ask"}'::jsonb,
  'organização e repositório juntos, pela mais rígida');
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-web'), '["claude", "codex", "copilot"]'::jsonb, 'sem política própria, vale a da organização');
select is((select array_agg(project_id order by project_id) from public.my_project_policies()), array['p-api', 'p-web'], 'projeto fora da organização não tem política');

-- Remover.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.clear_llm_policy((select id from ids where name = 'org'), null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-api'), '["codex", "cursor"]'::jsonb, 'sem a da organização, fica a do repositório');

select * from finish();
rollback;
