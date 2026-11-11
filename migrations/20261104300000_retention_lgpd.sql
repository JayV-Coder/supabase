-- Retenção, exclusão de dados e LGPD (ticket #29, PRD §8). Os jobs rodam no worker de
-- diagnóstico, chamado pelo Cloud Scheduler às 03:00 BRT: o pg_cron do projeto é do jayv-coder
-- (ADR-0009). Cada execução fica na Trilha de auditoria (`retention.purge`).

-- Padrões do PRD e limites. Os limites por plano chegam com as cotas (#31); até lá, valem os
-- mesmos para todos, e a auditoria nunca fica abaixo de 365 dias.
create table doctor.retention_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  data_class text not null check (data_class in ('raw_logs', 'events', 'incidents', 'audit')),
  days integer not null check (days > 0),
  updated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, data_class)
);
comment on table doctor.retention_policies is 'Retenção da Organização por classe de dado (sem linha = padrão do PRD).';

create trigger retention_policies_set_updated_at
before update on doctor.retention_policies
for each row execute function doctor.set_updated_at();
create trigger retention_policies_audit after insert or update or delete on doctor.retention_policies
for each row execute function doctor.audit_change('retention_policy');

alter table doctor.retention_policies enable row level security;
revoke all on doctor.retention_policies from anon, authenticated;
grant select on doctor.retention_policies to authenticated;
create policy retention_policies_select on doctor.retention_policies
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));

create function doctor.retention_bounds(data_class text)
returns table (default_days integer, min_days integer, max_days integer)
language sql
immutable
set search_path = ''
as $$
  select b.default_days, b.min_days, b.max_days from (values
    ('raw_logs', 30, 7, 90),
    ('events', 90, 30, 365),
    ('incidents', 180, 90, 730),
    ('audit', 365, 365, 1825)
  ) as b(data_class, default_days, min_days, max_days)
  where b.data_class = retention_bounds.data_class
$$;
revoke all on function doctor.retention_bounds(text) from public, anon;
grant execute on function doctor.retention_bounds(text) to authenticated, service_role;

create function doctor.effective_retention(tenant uuid, data_class text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.days from doctor.retention_policies p
     where p.tenant_id = tenant and p.data_class = effective_retention.data_class),
    (select b.default_days from doctor.retention_bounds(effective_retention.data_class) b)
  )
$$;
revoke all on function doctor.effective_retention(uuid, text) from public, anon, authenticated;
grant execute on function doctor.effective_retention(uuid, text) to service_role;

-- Para a tela: só a da Organização ativa (o tenant sai do JWT, nunca do argumento).
create function doctor.my_retention(data_class text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select doctor.effective_retention(doctor.current_tenant_id(), my_retention.data_class)
$$;
revoke all on function doctor.my_retention(text) from public, anon, service_role;
grant execute on function doctor.my_retention(text) to authenticated;

create function doctor.set_retention_policy(data_class text, days integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  bounds record;
begin
  perform doctor.require_manager();
  select * into bounds from doctor.retention_bounds(set_retention_policy.data_class);
  if bounds.default_days is null then
    raise exception 'classe de dado inválida' using errcode = '22023';
  end if;
  if days < bounds.min_days or days > bounds.max_days then
    raise exception 'retenção fora dos limites (% a % dias)', bounds.min_days, bounds.max_days
      using errcode = 'DR040';
  end if;
  insert into doctor.retention_policies (tenant_id, data_class, days, updated_by)
  values (tenant, set_retention_policy.data_class, days, auth.uid())
  on conflict on constraint retention_policies_tenant_id_data_class_key
  do update set days = excluded.days, updated_by = excluded.updated_by;
  -- Os Logs brutos já aceitos passam a vencer pela política nova (o upload pendente, de 1 dia,
  -- e o recusado não mudam).
  if set_retention_policy.data_class = 'raw_logs' then
    update doctor.raw_log_objects r set expires_at = r.created_at + make_interval(days => days)
    where r.tenant_id = tenant and r.expires_at > r.created_at + interval '2 days';
  end if;
end;
$$;
revoke all on function doctor.set_retention_policy(text, integer) from public, anon, service_role;
grant execute on function doctor.set_retention_policy(text, integer) to authenticated;

-- "Enviar evidências ao LLM": desligado, nada da Organização vai a provedor de IA (nem o
-- embedding da Base): o Diagnóstico roda como rules_only e a Base fica só com o texto.
alter table doctor.tenants
  add column llm_enabled boolean not null default true,
  add column deletion_requested_at timestamptz,
  add column deletion_requested_by uuid references auth.users (id) on delete set null,
  add column deletion_scheduled_for timestamptz,
  add constraint tenants_deletion_dates check ((deletion_requested_at is null) = (deletion_scheduled_for is null));

-- A exclusão tem registros próprios (`org.deletion_requested`/`_canceled`); o trigger genérico da
-- Organização não repete. O envio ao LLM fica no `org.updated`, com before e after.
drop trigger tenants_audit on doctor.tenants;
create trigger tenants_audit after update on doctor.tenants
for each row execute function doctor.audit_change('org', 'auto_diagnose_critical',
  'deletion_requested_at', 'deletion_requested_by', 'deletion_scheduled_for');

create function doctor.set_llm_enabled(enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  update doctor.tenants t set llm_enabled = enabled where t.id = tenant;
end;
$$;
revoke all on function doctor.set_llm_enabled(boolean) from public, anon, service_role;
grant execute on function doctor.set_llm_enabled(boolean) to authenticated;

-- Exclusão total: só o Owner com MFA, digitando o slug. Carência de 7 dias (cancelável); depois o
-- job apaga banco, Storage e Vault e deixa um comprovante. `public.organizations` é do jayv-coder
-- (ADR-0009) e não é tocada: sai só o que é do Doctor.
create function doctor.request_tenant_deletion(confirmation text)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  role text := doctor.require_manager();
  slug text;
  scheduled timestamptz := now() + interval '7 days';
begin
  if role <> 'owner' then
    raise insufficient_privilege using message = 'exige o Owner com MFA';
  end if;
  select o.slug into slug from public.organizations o where o.id = tenant;
  if slug is null or confirmation is distinct from slug then
    raise exception 'confirmação não confere com o slug da Organização' using errcode = 'DR041';
  end if;
  update doctor.tenants t
  set deletion_requested_at = now(), deletion_requested_by = auth.uid(), deletion_scheduled_for = scheduled
  where t.id = tenant and t.deletion_requested_at is null;
  if not found then
    select t.deletion_scheduled_for into scheduled from doctor.tenants t where t.id = tenant;
  end if;
  perform doctor.write_audit(tenant, 'org.deletion_requested', 'org', tenant::text, null,
    jsonb_build_object('scheduled_for', scheduled));
  return scheduled;
end;
$$;

create function doctor.cancel_tenant_deletion()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  if doctor.require_manager() <> 'owner' then
    raise insufficient_privilege using message = 'exige o Owner com MFA';
  end if;
  update doctor.tenants t
  set deletion_requested_at = null, deletion_requested_by = null, deletion_scheduled_for = null
  where t.id = tenant and t.deletion_requested_at is not null;
  if found then
    perform doctor.write_audit(tenant, 'org.deletion_canceled', 'org', tenant::text, null, null);
  end if;
end;
$$;
revoke all on function doctor.request_tenant_deletion(text) from public, anon, service_role;
revoke all on function doctor.cancel_tenant_deletion() from public, anon, service_role;
grant execute on function doctor.request_tenant_deletion(text) to authenticated;
grant execute on function doctor.cancel_tenant_deletion() to authenticated;

-- Comprovante da exclusão: sobrevive à Organização (sem FK para tenants) e não guarda dado dela
-- além do id e das contagens. Só a plataforma lê.
create table doctor.deletion_receipts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  requested_by uuid,
  requested_at timestamptz not null,
  completed_at timestamptz not null default now(),
  removed jsonb not null default '{}' check (jsonb_typeof(removed) = 'object'),
  unique (tenant_id, id)
);
comment on table doctor.deletion_receipts is 'Comprovante da exclusão total de uma Organização (LGPD).';
alter table doctor.deletion_receipts enable row level security;
revoke all on doctor.deletion_receipts from anon, authenticated;

-- Execuções: a fundida e o registro da fusão saem junto com a sobrevivente.
alter table doctor.executions drop constraint executions_tenant_id_merged_into_fkey,
  add constraint executions_tenant_id_merged_into_fkey foreign key (tenant_id, merged_into)
    references doctor.executions (tenant_id, id) on delete cascade;
alter table doctor.execution_merges drop constraint execution_merges_tenant_id_merged_id_fkey,
  add constraint execution_merges_tenant_id_merged_id_fkey foreign key (tenant_id, merged_id)
    references doctor.executions (tenant_id, id) on delete cascade;
alter table doctor.execution_merges drop constraint execution_merges_tenant_id_survivor_id_fkey,
  add constraint execution_merges_tenant_id_survivor_id_fkey foreign key (tenant_id, survivor_id)
    references doctor.executions (tenant_id, id) on delete cascade;
-- A Importação fica no histórico; o Log bruto vencido sai do Storage e dela.
alter table doctor.imports drop constraint imports_tenant_id_raw_log_object_id_fkey,
  add constraint imports_tenant_id_raw_log_object_id_fkey foreign key (tenant_id, raw_log_object_id)
    references doctor.raw_log_objects (tenant_id, id) on delete set null (raw_log_object_id);

-- `expires_at` do Log bruto aceito segue a retenção da Organização: a ingestão e a Importação
-- gravam o padrão de 30 dias, e o trigger troca pela política (o upload pendente, que vence em 1
-- dia, e o recusado, que vence na hora, ficam como estão). O Explorador mostra os dias que faltam
-- por essa mesma coluna.
create function doctor.raw_log_expiry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.expires_at > now() + interval '2 days' then
    new.expires_at := new.created_at
      + make_interval(days => doctor.effective_retention(new.tenant_id, 'raw_logs'));
  end if;
  return new;
end;
$$;
revoke all on function doctor.raw_log_expiry() from public;

create trigger raw_log_objects_expiry
before insert or update of expires_at on doctor.raw_log_objects
for each row execute function doctor.raw_log_expiry();

create index raw_log_objects_due_idx on doctor.raw_log_objects (expires_at);

-- Logs brutos vencidos: o worker apaga o objeto no Storage e depois a linha.
create function doctor.expired_raw_logs(batch integer)
returns table (id uuid, tenant_id uuid, storage_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.tenant_id, r.storage_path
  from doctor.raw_log_objects r
  where r.expires_at < now()
  order by r.expires_at
  limit batch
$$;

create function doctor.forget_raw_logs(targets uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from doctor.raw_log_objects r where r.id = any(targets);
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- Eventos, Execuções, Incidentes (e os Diagnósticos deles) e auditoria de uma Organização,
-- pela retenção dela. Incidente aberto não sai; Execução ligada a um Incidente que fica, também
-- não. Grava `retention.purge` com as contagens.
create function doctor.purge_tenant_data(tenant uuid, raw_logs integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  events_cutoff timestamptz := now() - make_interval(days => doctor.effective_retention(tenant, 'events'));
  incidents_cutoff timestamptz := now() - make_interval(days => doctor.effective_retention(tenant, 'incidents'));
  audit_cutoff timestamptz := now() - make_interval(days => doctor.effective_retention(tenant, 'audit'));
  counts jsonb := jsonb_build_object('raw_logs', raw_logs);
  removed integer;
begin
  delete from doctor.incidents i
  where i.tenant_id = tenant and i.status in ('resolved', 'dismissed')
    and coalesce(i.resolved_at, i.last_seen_at) < incidents_cutoff;
  get diagnostics removed = row_count;
  counts := counts || jsonb_build_object('incidents', removed);

  delete from doctor.events e where e.tenant_id = tenant and e.timestamp < events_cutoff;
  get diagnostics removed = row_count;
  counts := counts || jsonb_build_object('events', removed);

  -- A sobrevivente leva as fundidas junto (cascade): nenhuma das duas pode estar num Incidente.
  delete from doctor.executions x
  where x.tenant_id = tenant and x.merged_into is null and x.last_event_at < events_cutoff
    and not exists (
      select 1 from doctor.incident_executions ie
      where ie.tenant_id = x.tenant_id and ie.execution_id = x.id
    )
    and not exists (
      select 1 from doctor.executions m
      join doctor.incident_executions ie on ie.tenant_id = m.tenant_id and ie.execution_id = m.id
      where m.tenant_id = x.tenant_id and m.merged_into = x.id
    );
  get diagnostics removed = row_count;
  counts := counts || jsonb_build_object('executions', removed);

  perform set_config('doctor.retention', 'on', true);
  delete from doctor.audit_logs a where a.tenant_id = tenant and a.occurred_at < audit_cutoff;
  get diagnostics removed = row_count;
  perform set_config('doctor.retention', 'off', true);
  counts := counts || jsonb_build_object('audit', removed);

  perform doctor.write_audit(tenant, 'retention.purge', 'retention', null, null, counts);
  return counts;
end;
$$;

-- Partições inteiras que nenhuma Organização ainda precisa: `drop`, sem varrer linha a linha.
create function doctor.drop_expired_partitions()
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  dropped text[] := '{}'::text[];
  part record;
  horizon timestamptz;
begin
  for part in
    select c.relname, p.relname as parent,
      (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz as upper_bound
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    where p.relnamespace = 'doctor'::regnamespace and p.relname in ('events', 'audit_logs')
      and pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
  loop
    select now() - make_interval(days => greatest(
      (select b.default_days from doctor.retention_bounds(case part.parent when 'events' then 'events' else 'audit' end) b),
      coalesce((select max(r.days) from doctor.retention_policies r
                where r.data_class = case part.parent when 'events' then 'events' else 'audit' end), 0)
    )) into horizon;
    if part.upper_bound < horizon then
      -- Evidência de Diagnóstico aponta para Eventos (FK com set null): as linhas saem antes,
      -- aplicando a FK; depois a partição vazia sai inteira.
      if part.parent = 'events' then
        execute format('delete from doctor.%I', part.relname);
      end if;
      execute format('alter table doctor.%I detach partition doctor.%I', part.parent, part.relname);
      execute format('drop table doctor.%I', part.relname);
      dropped := dropped || part.relname::text;
    end if;
  end loop;
  return dropped;
end;
$$;

-- Fim da carência: a Organização para de aceitar escrita (token de ingestão e API exigem
-- `active`) antes de o worker listar os arquivos, para nada novo chegar no meio da exclusão.
create function doctor.freeze_tenant(tenant uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update doctor.tenants t set status = 'deleted'
  where t.id = tenant and t.deletion_scheduled_for <= now()
$$;
revoke all on function doctor.freeze_tenant(uuid) from public, anon, authenticated;
grant execute on function doctor.freeze_tenant(uuid) to service_role;

create function doctor.due_tenant_deletions()
returns table (tenant_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id from doctor.tenants t where t.deletion_scheduled_for <= now()
$$;

-- Depois do Storage (que o worker esvazia antes): Vault, tokens (com a Organização) e tudo do
-- schema doctor pelo cascade de tenants. O comprovante guarda as contagens.
create function doctor.purge_tenant(tenant uuid, storage_objects integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_tenant doctor.tenants;
  secrets integer;
  receipt uuid;
  counts jsonb;
begin
  select * into found_tenant from doctor.tenants t
  where t.id = tenant and t.deletion_scheduled_for <= now() for update;
  if found_tenant.id is null then
    raise exception 'Organização sem exclusão vencida' using errcode = 'DR042';
  end if;
  delete from vault.secrets s
  where s.id in (select c.secret_id from doctor.connectors c where c.tenant_id = tenant and c.secret_id is not null);
  get diagnostics secrets = row_count;
  counts := jsonb_build_object(
    'storage_objects', storage_objects,
    'vault_secrets', secrets,
    -- Para a verificação conferir o Vault depois (o nome do segredo leva o id do Conector).
    'connectors', (select coalesce(jsonb_agg(c.id), '[]') from doctor.connectors c where c.tenant_id = tenant),
    'events', (select count(*) from doctor.events e where e.tenant_id = tenant),
    'incidents', (select count(*) from doctor.incidents i where i.tenant_id = tenant),
    'knowledge_documents', (select count(*) from doctor.knowledge_documents k where k.tenant_id = tenant),
    'ingestion_tokens', (select count(*) from doctor.ingestion_tokens k where k.tenant_id = tenant),
    'memberships', (select count(*) from doctor.memberships m where m.tenant_id = tenant)
  );
  delete from doctor.user_active_tenant u where u.tenant_id = tenant;
  -- A fila do Dashboard (#21) não tem FK de propósito; sai à mão.
  delete from doctor.execution_stats_dirty d where d.tenant_id = tenant;
  delete from doctor.tenants t where t.id = tenant;
  insert into doctor.deletion_receipts (tenant_id, requested_by, requested_at, removed)
  values (tenant, found_tenant.deletion_requested_by, found_tenant.deletion_requested_at, counts)
  returning id into receipt;
  return receipt;
end;
$$;

-- Direitos do titular: os Eventos com a Referência de negócio dele (o HMAC, calculado pela API
-- com a chave da Organização). Owner ou Admin com MFA, a pedido do controlador.
create function doctor.find_subject_events(reference text)
returns table (events bigint, first_seen timestamptz, last_seen timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  return query
    select count(*) + (
        select count(*) from doctor.executions x
        where x.tenant_id = doctor.current_tenant_id()
          and x.correlation_keys -> 'business_reference' ? reference
      ),
      min(e.timestamp), max(e.timestamp)
    from doctor.events e
    where e.tenant_id = doctor.current_tenant_id() and e.business_reference = reference;
end;
$$;

create function doctor.erase_subject_events(reference text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  removed bigint;
begin
  perform doctor.require_manager();
  if reference !~ '^hmac:[0-9a-f]{16,64}$' then
    raise exception 'Referência inválida' using errcode = '22023';
  end if;
  delete from doctor.events e where e.tenant_id = tenant and e.business_reference = reference;
  get diagnostics removed = row_count;
  -- A Referência também está nas chaves de correlação das Execuções e das fusões.
  update doctor.executions x
  set correlation_keys = jsonb_set(x.correlation_keys, '{business_reference}',
    (x.correlation_keys -> 'business_reference') - reference)
  where x.tenant_id = tenant and x.correlation_keys -> 'business_reference' ? reference;
  update doctor.execution_merges m
  set merged_keys = jsonb_set(m.merged_keys, '{business_reference}',
    (m.merged_keys -> 'business_reference') - reference)
  where m.tenant_id = tenant and m.merged_keys -> 'business_reference' ? reference;
  -- O registro guarda a quantidade, não a Referência (que já identifica o titular).
  perform doctor.write_audit(tenant, 'subject.erased', 'subject', null, null,
    jsonb_build_object('events', removed));
  return removed;
end;
$$;

revoke all on function doctor.expired_raw_logs(integer) from public, anon, authenticated;
revoke all on function doctor.forget_raw_logs(uuid[]) from public, anon, authenticated;
revoke all on function doctor.purge_tenant_data(uuid, integer) from public, anon, authenticated;
revoke all on function doctor.drop_expired_partitions() from public, anon, authenticated;
revoke all on function doctor.due_tenant_deletions() from public, anon, authenticated;
revoke all on function doctor.purge_tenant(uuid, integer) from public, anon, authenticated;
grant execute on function doctor.expired_raw_logs(integer) to service_role;
grant execute on function doctor.forget_raw_logs(uuid[]) to service_role;
grant execute on function doctor.purge_tenant_data(uuid, integer) to service_role;
grant execute on function doctor.drop_expired_partitions() to service_role;
grant execute on function doctor.due_tenant_deletions() to service_role;
grant execute on function doctor.purge_tenant(uuid, integer) to service_role;
revoke all on function doctor.find_subject_events(text) from public, anon, service_role;
revoke all on function doctor.erase_subject_events(text) from public, anon, service_role;
grant execute on function doctor.find_subject_events(text) to authenticated;
grant execute on function doctor.erase_subject_events(text) to authenticated;
