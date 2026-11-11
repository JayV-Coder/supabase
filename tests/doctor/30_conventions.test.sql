-- Inventário automático (ticket #27): tabela nova do schema doctor fora das convenções
-- (supabase/CONVENTIONS.md, ADR-0004) quebra o CI. Cada exceção tem o motivo ao lado.
begin;
select plan(13);

create temporary table tenant_tables as
select c.oid, c.relname
from pg_class c
where c.relnamespace = 'doctor'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition;

create temporary table exceptions (relname name primary key, reason text not null);
insert into exceptions values
  ('tenants', 'é a própria Organização (id = tenant)'),
  ('global_knowledge_documents', 'Base global, comum a todas, só leitura'),
  ('global_knowledge_chunks', 'Base global, comum a todas, só leitura'),
  ('rule_definitions', 'catálogo global das Regras versionadas'),
  ('plan_limits', 'catálogo global de limites por plano'),
  ('platform_jobs', 'estado dos jobs de plataforma, sem dado de tenant'),
  ('ai_profile_checks', 'verificação diária dos perfis de IA, sem dado de tenant (ADR-0018)'),
  ('schema_migrations', 'controle das migrações do Doctor (ADR-0009)');

-- Sem `unique (tenant_id, id)`, com o motivo: a chave delas é outra.
create temporary table keyless (relname name primary key, reason text not null);
insert into keyless values
  ('events', 'particionada: a chave inclui a partição, (tenant_id, id, timestamp)'),
  ('audit_logs', 'particionada: a chave inclui a partição, (tenant_id, id, occurred_at)'),
  ('execution_stats_dirty', 'fila de horas a recalcular: (tenant_id, integration_id, hour)'),
  ('incident_counters', 'um contador por Organização: tenant_id é a chave'),
  ('user_active_tenant', 'uma Organização ativa por Usuário: user_id é a chave');

-- As regras como views: as asserções e o meta-teste do fim usam exatamente as mesmas consultas.
create temporary view without_rls as
select relname from tenant_tables t where not (select relrowsecurity from pg_class where oid = t.oid);

create temporary view without_tenant as
select relname from tenant_tables t
where t.relname not in (select relname from exceptions)
  and not exists (select 1 from pg_attribute a
                  where a.attrelid = t.oid and a.attname = 'tenant_id' and not a.attisdropped);

create temporary view without_tenant_key as
select relname from tenant_tables t
where t.relname not in (select relname from exceptions)
  and t.relname not in (select relname from keyless)
  and not exists (
    select 1 from pg_constraint k
    where k.conrelid = t.oid and k.contype in ('u', 'p')
      and (select array_agg(a.attname::text order by a.attname) from pg_attribute a
           where a.attrelid = t.oid and a.attnum = any(k.conkey)) = array['id', 'tenant_id']);

create temporary view loose_foreign_keys as
select k.conname::text as conname, t.relname
from pg_constraint k
join tenant_tables t on t.oid = k.conrelid
join pg_class f on f.oid = k.confrelid
where k.contype = 'f' and f.relnamespace = 'doctor'::regnamespace and f.relname <> 'tenants'
  and exists (select 1 from pg_attribute a where a.attrelid = f.oid and a.attname = 'tenant_id')
  and not exists (select 1 from pg_attribute a
                  where a.attrelid = k.conrelid and a.attname = 'tenant_id'
                    and a.attnum = any(k.conkey));

select is((select array_agg(relname order by relname) from without_rls), null,
  'toda tabela do schema doctor tem RLS');
select is((select array_agg(relname order by relname) from without_tenant), null,
  'toda tabela de tenant tem tenant_id');
select is((select array_agg(relname order by relname) from without_tenant_key), null,
  'toda tabela de tenant tem unique (tenant_id, id)');
select is((select array_agg(conname order by conname) from loose_foreign_keys), null,
  'FK para tabela de tenant é sempre composta com tenant_id');

select is(
  (select array_agg(relname order by relname) from tenant_tables t
   where has_table_privilege('authenticated', t.oid, 'select')
     and not exists (select 1 from pg_policy p where p.polrelid = t.oid)),
  null, 'tabela legível por authenticated tem política de RLS'
);

select is(
  (select array_agg(c.relname order by c.relname) from pg_class c
   where c.relnamespace = 'doctor'::regnamespace and c.relispartition
     and (has_table_privilege('authenticated', c.oid, 'select')
          or has_table_privilege('anon', c.oid, 'select'))),
  null, 'partições não são acessíveis direto (só pela tabela-mãe, com RLS)'
);

select is(
  (select array_agg(relname order by relname) from tenant_tables t
   where has_table_privilege('anon', t.oid, 'select') or has_table_privilege('anon', t.oid, 'insert')
      or has_table_privilege('anon', t.oid, 'update') or has_table_privilege('anon', t.oid, 'delete')),
  null, 'anon não tem privilégio em tabela do Doctor'
);

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
   where p.pronamespace = 'doctor'::regnamespace and p.prosecdef
     and (p.proconfig is null
          or not exists (select 1 from unnest(p.proconfig) x where x like 'search_path=%')
          or p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) e
                     where e.grantee = 0 and e.privilege_type = 'EXECUTE'))),
  null, 'security definer: search_path fixo e sem execute para public'
);

-- As portas anônimas resolvem o tenant pelo hash de um token: as duas da ingestão e a abertura do
-- link compartilhável do Relatório técnico (#32, ADR-0014).
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
   where p.pronamespace = 'doctor'::regnamespace and has_function_privilege('anon', p.oid, 'execute')),
  array['accept_agent_batch', 'accept_ingestion_batch', 'agent_seen', 'claim_local_llm', 'finish_local_llm', 'jira_hook', 'open_report_share', 'record_report_share_access', 'register_agent', 'resolve_agent', 'resolve_ingestion_token', 'servicenow_hook'],
  'anon só executa as funções por token (ingestão, link do Relatório, agente, modelo local e webhooks de ITSM)'
);

-- O inventário pega a tabela nova fora do padrão (é o que bloqueia o merge): as mesmas views.
create table doctor.zz_fora_do_padrao (id uuid primary key);
create table doctor.zz_filha_solta (
  id uuid primary key, tenant_id uuid, parent_id uuid references doctor.incidents (id)
);
insert into tenant_tables select oid, relname from pg_class
where oid in ('doctor.zz_fora_do_padrao'::regclass, 'doctor.zz_filha_solta'::regclass);
select is((select string_agg(relname::text, ',' order by relname::text) from without_rls),
  'zz_filha_solta,zz_fora_do_padrao', 'tabela sem RLS é detectada');
select is((select string_agg(relname::text, ',' order by relname::text) from without_tenant),
  'zz_fora_do_padrao', 'tabela sem tenant_id é detectada');
select is((select string_agg(relname::text, ',' order by relname::text) from without_tenant_key),
  'zz_filha_solta,zz_fora_do_padrao', 'tabela sem unique (tenant_id, id) é detectada');
select is((select string_agg(relname::text, ',' order by relname::text) from loose_foreign_keys),
  'zz_filha_solta', 'FK sem tenant_id é detectada');

select * from finish();
rollback;
