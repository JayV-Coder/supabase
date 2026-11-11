-- O schema `public` passa a ser o compartilhado entre os apps do projeto (jayv-coder e
-- jayv-doctor): conta, organizações, i18n e cobrança. O que é só do app do jayv-coder vai para o
-- schema `coder`.
--
-- Transição sem quebra: cada tabela movida deixa em `public` uma view de mesmo nome
-- (`security_invoker`, então o RLS da tabela vale para quem consulta; atualizável, então
-- insert/update/delete seguem funcionando). App instalado, site, edge functions e funções do
-- banco continuam como estão; cada um passa a usar `coder.*` no seu tempo, e as views saem
-- depois.
--
-- As funções do banco que citam uma tabela movida passam a citar `coder.<tabela>` (o texto do
-- corpo não acompanha o `set schema`, e `on conflict on constraint` não vale através de view).
--
-- Ficam em `public` por enquanto: `organization_git_connections` e `organization_repositories`,
-- que o app instalado escuta pelo Realtime (`postgres_changes` em `public`). Uma view não emite
-- esses eventos; elas vão para `coder` quando o app escutar lá.

create schema if not exists coder;
grant usage on schema coder to anon, authenticated, service_role;
alter default privileges in schema coder grant all on tables to service_role;
comment on schema coder is 'Tabelas do app jayv-coder (o compartilhado entre os apps fica em public).';

do $$
declare
  moved text[] := array[
    'chats', 'entry_checks', 'exit_checks', 'first_results',
    'jev_calls', 'jev_parameters', 'jev_questions', 'jev_records', 'jev_turns', 'jev_usage',
    'llm_agents', 'llm_models', 'messages', 'model_prices',
    'organization_chat_permissions', 'organization_command_rules', 'organization_llm_policies',
    'organization_mcp_servers', 'organization_skills', 'organization_validation',
    'project_notes', 'projects', 'questions', 'quota_snapshots',
    'turn_events', 'turns', 'usage_records', 'usage_telemetry'
  ];
  name text;
  grant_row record;
begin
  foreach name in array moved loop
    -- Guarda as permissões da tabela antes de mover, para repetir na view.
    create temporary table if not exists moved_grants (table_name text, grantee text, privilege text)
      on commit drop;
    insert into moved_grants
    select name, g.grantee, g.privilege_type
    from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.table_name = name
      and g.grantee in ('anon', 'authenticated', 'service_role');

    execute format('alter table public.%I set schema coder', name);
    execute format(
      'create view public.%I with (security_invoker = true) as select * from coder.%I', name, name);
    execute format('comment on view public.%I is %L', name,
      'Compatibilidade: a tabela agora é coder.' || name || '; esta view sai depois da transição.');
    execute format('revoke all on public.%I from anon, authenticated', name);
    for grant_row in select * from moved_grants where table_name = name loop
      execute format('grant %s on public.%I to %I', grant_row.privilege, name, grant_row.grantee);
      execute format('grant %s on coder.%I to %I', grant_row.privilege, name, grant_row.grantee);
    end loop;
  end loop;
end;
$$;

-- Reescreve o corpo das funções que citam as tabelas movidas.
do $$
declare
  moved text := 'chats|entry_checks|exit_checks|first_results|jev_calls|jev_parameters|jev_questions'
    || '|jev_records|jev_turns|jev_usage|llm_agents|llm_models|messages|model_prices'
    || '|organization_chat_permissions|organization_command_rules|organization_llm_policies'
    || '|organization_mcp_servers|organization_skills|organization_validation|project_notes|projects'
    || '|questions|quota_snapshots|turn_events|turns|usage_records|usage_telemetry';
  pattern text := '\mpublic\.(' || moved || ')\M';
  fn record;
  definition text;
begin
  for fn in
    select p.oid from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'coder') and p.prokind in ('f', 'p')
      and p.prosrc ~ pattern
  loop
    definition := pg_get_functiondef(fn.oid);
    execute regexp_replace(definition, pattern, 'coder.\1', 'g');
  end loop;
end;
$$;
