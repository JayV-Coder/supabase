-- Ticket #12: Eventos normalizados (Contrato v1) e rejeições por linha da Importação.
-- Particionamento nativo por mês, sem pg_partman (ADR-0011): extensão nova exigiria aprovação no
-- projeto compartilhado com o jayv-coder, e a criação de partições cabe ao worker de ingestão.

create table doctor.events (
  id uuid not null,
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  raw_log_object_id uuid,
  timestamp timestamptz not null,
  schema_version text not null,
  execution_id text,
  trace_id text,
  source jsonb not null,
  operation text not null,
  severity text not null check (severity in ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')),
  error jsonb,
  business_context jsonb,
  -- Copiada de business_context.entity_reference (sempre `hmac:<hex>`) para a busca exata.
  business_reference text,
  attributes jsonb,
  sanitization_report jsonb,
  -- sha256 de tenant, fonte e event_id da origem (ou do conteúdo canônico): o mesmo Evento
  -- chegando de novo não duplica.
  dedup_key text not null,
  ingested_at timestamptz not null default now(),
  -- A chave de partição entra em toda chave única: (tenant_id, id, timestamp) é o alvo das FKs
  -- compostas que apontarem para Eventos (Evidências do Diagnóstico).
  primary key (tenant_id, id, timestamp),
  unique (tenant_id, dedup_key, timestamp),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  -- Log bruto vence pela retenção; o Evento fica, sem a referência.
  foreign key (tenant_id, raw_log_object_id) references doctor.raw_log_objects (tenant_id, id)
    on delete set null (raw_log_object_id)
) partition by range (timestamp);
comment on table doctor.events is 'Evento normalizado no Contrato v1, já sanitizado. Particionada por mês.';

create index events_execution_idx on doctor.events (tenant_id, execution_id) where execution_id is not null;
create index events_trace_idx on doctor.events (tenant_id, trace_id) where trace_id is not null;
create index events_integration_time_idx on doctor.events (tenant_id, integration_id, timestamp desc);
create index events_business_reference_idx on doctor.events (tenant_id, business_reference)
  where business_reference is not null;
create index events_raw_log_object_idx on doctor.events (tenant_id, raw_log_object_id);

alter table doctor.events enable row level security;
revoke all on doctor.events from anon, authenticated;
grant select on doctor.events to authenticated;

create policy events_select on doctor.events
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- security definer: cria a partição do mês de `day`, se ainda não existir. Chamada pelo worker
-- antes de gravar; concorrência entre workers vira no-op. A partição nasce com RLS e sem grant
-- para o cliente: só se lê pela tabela-mãe, com a política dela.
create function doctor.ensure_event_partition(day date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  first_day date := date_trunc('month', day)::date;
  partition_name text := format('events_%s', to_char(first_day, 'YYYY_MM'));
begin
  -- Partição que já existe: nada a fazer, sem lock nenhum. Só a criação trava a tabela-mãe, e o
  -- worker a chama numa transação curta, separada do insert do lote.
  if to_regclass(format('doctor.%I', partition_name)) is not null then
    return partition_name;
  end if;
  begin
    execute format(
      'create table doctor.%I partition of doctor.events for values from (%L) to (%L)',
      partition_name, first_day::text || ' 00:00:00+00', (first_day + interval '1 month')::date::text || ' 00:00:00+00'
    );
  exception when duplicate_table then
    return partition_name;
  end;
  execute format('alter table doctor.%I enable row level security', partition_name);
  execute format('revoke all on doctor.%I from anon, authenticated', partition_name);
  return partition_name;
end;
$$;

revoke all on function doctor.ensure_event_partition(date) from public, anon, authenticated;
grant execute on function doctor.ensure_event_partition(date) to service_role;

-- Prazo do worker que pegou a Importação: outra entrega da mesma mensagem espera, e só assume
-- depois que o prazo vence (worker morto). O worker renova o prazo a cada lote gravado.
alter table doctor.imports add column processing_started_at timestamptz;

-- Linhas da Importação que não viraram Evento, com o motivo. Sem o conteúdo da linha: ele
-- pode ter dado pessoal, e o Log bruto original continua no Storage até a retenção.
create table doctor.import_rejections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  import_id uuid not null,
  line_number integer not null check (line_number > 0),
  reason text not null check (char_length(reason) <= 500),
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, import_id) references doctor.imports (tenant_id, id) on delete cascade
);

create index import_rejections_import_idx on doctor.import_rejections (tenant_id, import_id, line_number);

alter table doctor.import_rejections enable row level security;
revoke all on doctor.import_rejections from anon, authenticated;
grant select on doctor.import_rejections to authenticated;

create policy import_rejections_select on doctor.import_rejections
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
