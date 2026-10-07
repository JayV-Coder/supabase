-- Servidores MCP e skills da organização: só owner e maintainer gravam, o
-- membro recebe o que está ligado pela RPC (e só as skills direto da tabela),
-- e o projeto da organização ganha de uma organização de repositório.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000d3', 'fora@teste.local', now(), '{"user_name":"fora"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
reset role;
insert into public.organization_members (org_id, user_id, role) values
  ((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000d2', 'member');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.set_org_mcp_server((select id from ids where name = 'org'),
  '{"name":"github","transport":"stdio","command":"npx","args":["-y","server"],"env":{"TOKEN":"segredo"},"url":"","headers":{},"agents":[]}');
select public.set_org_mcp_server((select id from ids where name = 'org'),
  '{"name":"docs","transport":"http","command":"","args":[],"env":{},"url":"https://docs.example.com/mcp","headers":{},"agents":["claude"]}', false);
select public.set_org_skill((select id from ids where name = 'org'), 'release-notes', 'Writes release notes.', E'# Steps\nList each change.');
-- Toda organização já nasce com os quatro servidores oficiais (como linhas comuns).
select is((select count(*)::int from public.organization_mcp_servers where name in ('sequential-thinking', 'fetch', 'git', 'memory') and enabled), 4, 'a organização nasce com os quatro servidores oficiais');
select is((select config->>'command' from public.organization_mcp_servers where name = 'fetch'), 'uvx', 'fetch sobe pelo uvx (o oficial é em Python)');
select is((select count(*)::int from public.organization_mcp_servers), 6, 'o owner grava servidores além dos padrão');
select public.remove_org_mcp_server((select id from ids where name = 'org'), 'git');
select is((select count(*)::int from public.organization_mcp_servers where name = 'git'), 0, 'o padrão removido pelo owner fica removido');
select public.set_org_mcp_server((select id from ids where name = 'org'), (select config from public.organization_mcp_servers where name = 'fetch'), false);

select throws_ok($$select public.set_org_mcp_server((select id from ids where name = 'org'), '{"name":"jayv","transport":"stdio","command":"x"}')$$, 'P0001', 'mcp.invalid', 'o nome jayv é reservado');
select throws_ok($$select public.set_org_mcp_server((select id from ids where name = 'org'), '{"name":"bad name","transport":"stdio","command":"x"}')$$, 'P0001', 'mcp.invalid', 'nome com espaço não vale');
select throws_ok($$select public.set_org_mcp_server((select id from ids where name = 'org'), '{"name":"web","transport":"http","url":"ftp://x"}')$$, 'P0001', 'mcp.invalid', 'http pede URL http(s)');
select throws_ok($$select public.set_org_skill((select id from ids where name = 'org'), 'a b', 'd', 'b')$$, 'P0001', 'skill.invalid', 'nome de skill inválido');

-- O membro não lê a tabela de servidores (segredos) nem grava; lê as skills.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select is_empty($$select 1 from public.organization_mcp_servers$$, 'o membro não lê a tabela dos servidores');
select is((select count(*)::int from public.organization_skills), 1, 'o membro lê as skills');
select throws_ok($$select public.set_org_skill((select id from ids where name = 'org'), 's', 'd', 'b')$$, 'P0001', 'org.forbidden', 'o membro não grava skill');
select throws_ok($$select public.set_org_mcp_server((select id from ids where name = 'org'), '{"name":"x","transport":"stdio","command":"x"}')$$, 'P0001', 'org.forbidden', 'o membro não grava servidor');

-- O membro recebe só o que está ligado, pela linha sem projeto e pela do projeto da organização.
insert into public.projects (id, name, created_at, repo_keys, org_id) values
  ('p-org', 'Acme', '2026-10-06T12:00:00Z', '[]', (select id from ids where name = 'org'));
select is((select jsonb_array_length(mcp) from public.my_org_extensions() where project_id = ''), 5, 'os servidores descem, ligados ou desligados');
select is((select jsonb_agg(m->>'name' order by m->>'name') from public.my_org_extensions() e, jsonb_array_elements(e.mcp) m where e.project_id = '' and (m->>'enabled')::boolean), '["github", "memory", "sequential-thinking"]'::jsonb, 'cada um desce com o enabled: o desligado não vale');
select is((select m->>'command' from public.my_org_extensions() e, jsonb_array_elements(e.mcp) m where e.project_id = 'p-org' and m->>'name' = 'github'), 'npx', 'o projeto da organização recebe o servidor');
select is((select skills->0->>'name' from public.my_org_extensions() where project_id = 'p-org'), 'release-notes', 'e a skill');

-- Quem não é membro não recebe nada.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select is_empty($$select 1 from public.my_org_extensions()$$, 'quem não é membro não recebe nada');

select * from finish();
rollback;
