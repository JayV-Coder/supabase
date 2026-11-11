-- Execuções (ticket #17): o worker `correlation` agrupa os Eventos de uma Integração em
-- Execuções. Uma Execução fica aberta enquanto chegam Eventos e fecha 5 min depois da última
-- mudança; ao fechar, publica `rules.evaluate`.

create table doctor.executions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  status text not null default 'pending_confirmation'
    check (status in ('success', 'failed', 'pending_confirmation', 'unknown')),
  -- Agrupada por proximidade temporal, ou Evento que nenhuma estratégia associou.
  low_confidence boolean not null default false,
  first_event_at timestamptz not null,
  last_event_at timestamptz not null,
  duration_ms bigint not null default 0 check (duration_ms >= 0),
  event_count integer not null default 0 check (event_count >= 0),
  -- {"execution_id": [...], "trace_id": [...], "business_reference": [...]}
  correlation_keys jsonb not null default '{}' check (jsonb_typeof(correlation_keys) = 'object'),
  -- Hora da última vez que a correlação mexeu na Execução (não a dos Eventos, que numa
  -- Importação podem ser de ontem): é dela que contam os 5 min até fechar.
  last_activity_at timestamptz not null default now(),
  closed_at timestamptz,
  -- Fundida em outra (o trace chegou depois, por exemplo). A linha fica, fechada e sem Eventos:
  -- o que já apontava para ela (mensagens, Incidentes) acha a sobrevivente por aqui.
  merged_into uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  foreign key (tenant_id, merged_into) references doctor.executions (tenant_id, id),
  check (last_event_at >= first_event_at),
  check (merged_into is null or merged_into <> id)
);
comment on table doctor.executions is 'Execução: ocorrência de ponta a ponta de um fluxo, reconstruída pela correlação.';

create index executions_tenant_time_idx on doctor.executions (tenant_id, integration_id, first_event_at desc);
create index executions_status_idx on doctor.executions (tenant_id, status, first_event_at desc);
-- Exceção à convenção (sem tenant_id na frente): o fechamento é job de plataforma e busca as
-- abertas de todas as Organizações.
create index executions_open_idx on doctor.executions (last_activity_at)
  where closed_at is null and merged_into is null;
create index executions_merged_idx on doctor.executions (tenant_id, merged_into)
  where merged_into is not null;

create trigger executions_set_updated_at
before update on doctor.executions
for each row execute function doctor.set_updated_at();

-- Duas Execuções que se revelam a mesma (ex.: o trace chega depois) viram uma só; a que sai fica
-- registrada aqui, com as chaves que tinha. Nenhuma das duas é apagada (ADR-0012).
create table doctor.execution_merges (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  survivor_id uuid not null,
  merged_id uuid not null,
  merged_keys jsonb not null default '{}' check (jsonb_typeof(merged_keys) = 'object'),
  merged_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, survivor_id) references doctor.executions (tenant_id, id),
  foreign key (tenant_id, merged_id) references doctor.executions (tenant_id, id)
);
comment on table doctor.execution_merges is 'Histórico de fusões de Execuções pela correlação.';

create index execution_merges_survivor_idx on doctor.execution_merges (tenant_id, survivor_id);
create index execution_merges_merged_idx on doctor.execution_merges (tenant_id, merged_id);

create trigger execution_merges_set_updated_at
before update on doctor.execution_merges
for each row execute function doctor.set_updated_at();

alter table doctor.events
  add column execution_ref uuid,
  add column correlated_by text
    check (correlated_by in ('execution_id', 'trace_id', 'business_reference', 'temporal_proximity'));
alter table doctor.events
  add constraint events_execution_fk
  foreign key (tenant_id, execution_ref) references doctor.executions (tenant_id, id)
  on delete set null (execution_ref);
create index events_execution_ref_idx on doctor.events (tenant_id, execution_ref)
  where execution_ref is not null;
-- O que falta correlacionar, por Integração.
create index events_pending_correlation_idx on doctor.events (tenant_id, integration_id, timestamp)
  where execution_ref is null;

alter table doctor.executions enable row level security;
alter table doctor.execution_merges enable row level security;
revoke all on doctor.executions, doctor.execution_merges from anon, authenticated;
grant select on doctor.executions, doctor.execution_merges to authenticated;

create policy executions_select on doctor.executions
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy execution_merges_select on doctor.execution_merges
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
