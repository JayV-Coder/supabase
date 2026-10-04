-- O chat da organização: o projeto que diz a organização em `org_id` entra
-- nela se o dono for membro, e roda sob a política da organização junto com a
-- de todos os repositórios dela, pela mais rígida.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000c3', 'fora@teste.local', now(), '{"user_name":"fora"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into ids select 'api', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api');
insert into ids select 'web', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/web');
reset role;
-- Começa sem política nenhuma, seja qual for a padrão da organização nova.
delete from public.organization_llm_policies;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000c2', 'member');

-- Antes de qualquer política, o projeto entra na organização e não tem política.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
insert into public.projects (id, name, created_at, repo_keys, org_id) values
  ('p-org', 'Acme', '2026-10-02T12:00:00Z', '[]', (select id from ids where name = 'org'));
select is(public.project_organization('p-org'), (select id from ids where name = 'org'), 'o org_id associa o projeto à organização');
select is((select org_id from public.my_project_organizations() where project_id = 'p-org'), (select id from ids where name = 'org'), 'aparece nos projetos da organização');
select is_empty($$select 1 from public.my_project_policies() where project_id = 'p-org'$$, 'sem política nenhuma, o projeto não tem política');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select public.set_llm_policy((select id from ids where name = 'org'), null, '{"agents": ["claude", "codex"], "deny": ["secrets/**"], "min_write": "ask"}');
select public.set_llm_policy((select id from ids where name = 'org'), (select id from ids where name = 'api'), '{"agents": ["codex", "cursor"], "deny": ["*.sql"], "min_shell": "deny"}');
select public.set_llm_policy((select id from ids where name = 'org'), (select id from ids where name = 'web'), '{"blocked_models": ["codex/o3"], "local_only": ["internal/**"], "safe_agents": true, "min_read": "ask"}');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select is((select policy from public.my_project_policies() where project_id = 'p-org'),
  '{"agents": ["codex"], "blocked_models": ["codex/o3"], "blocked_mechanisms": [], "deny": ["secrets/**", "*.sql"], "local_only": ["internal/**"],
    "safe_agents": true, "redact_secrets": false, "min_read": "ask", "min_write": "ask", "min_shell": "deny"}'::jsonb,
  'a organização e todos os repositórios juntos, pela mais rígida');
select is((select org_slug from public.my_project_policies() where project_id = 'p-org'), 'acme', 'a política diz de que organização é');
select throws_ok($$select public.llm_policy_of_organization((select id from ids where name = 'org'))$$, '42501', null, 'a junção é interna');

-- Só a política de um repositório: agentes sem lista da organização ficam os do repositório.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select public.clear_llm_policy((select id from ids where name = 'org'), null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select is((select policy->'agents' from public.my_project_policies() where project_id = 'p-org'), '["codex", "cursor"]'::jsonb, 'sem a da organização, valem os agentes do repositório');

-- Quem não é membro não leva o projeto para a organização dizendo o org_id.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c3');
insert into public.projects (id, name, created_at, repo_keys, org_id) values
  ('p-intruso', 'Acme', '2026-10-02T12:00:00Z', '[]', (select id from ids where name = 'org'));
select is(public.project_organization('p-intruso'), null, 'org_id de quem não é membro não associa');
select is_empty($$select 1 from public.my_project_policies()$$, 'nem traz política');

select * from finish();
rollback;
