-- Ticket #34: trace de ponta a ponta e as medidas da plataforma.

-- O `traceparent` (W3C) de quem gravou a mensagem: a API e os workers o põem na sessão
-- (`doctor.traceparent`), e o relay o publica como atributo do Pub/Sub.
alter table doctor.outbox_messages
  add column traceparent text check (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$');

create function doctor.fill_outbox_traceparent()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current text := nullif(current_setting('doctor.traceparent', true), '');
begin
  if new.traceparent is null
    and current ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$' then
    new.traceparent := current;
  end if;
  return new;
end;
$$;

revoke all on function doctor.fill_outbox_traceparent() from public;

create trigger outbox_messages_traceparent
before insert on doctor.outbox_messages
for each row execute function doctor.fill_outbox_traceparent();

-- Medidas da plataforma, de todas as Organizações juntas e só números (sem tenant_id): vão para
-- o Cloud Monitoring a cada minuto e para o `/admin/health` dos operadores.
create function doctor.platform_health()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with finished as (
    select d.status, d.duration_ms,
      exists (select 1 from doctor.usage_llm u where u.tenant_id = d.tenant_id
        and u.diagnosis_id = d.id) as used_llm
    from doctor.diagnoses d
    where d.status in ('published', 'inconclusive', 'failed_llm', 'failed')
      and d.updated_at > now() - interval '1 hour'
  )
  select jsonb_build_object(
    'outbox_pending', (select count(*) from doctor.outbox_messages
      where published_at is null and attempts < 10),
    'outbox_lag_seconds', coalesce((select extract(epoch from now() - min(created_at))
      from doctor.outbox_messages where published_at is null and attempts < 10), 0),
    'outbox_stuck', (select count(*) from doctor.outbox_messages
      where published_at is null and attempts >= 10),
    'ingestion_batches_pending', (select count(*) from doctor.ingestion_batches
      where processed_at is null and failed_at is null),
    'ingestion_lag_seconds', coalesce((select extract(epoch from now() - min(created_at))
      from doctor.ingestion_batches where processed_at is null and failed_at is null), 0),
    'ingestion_batches_failed_1h', (select count(*) from doctor.ingestion_batches
      where failed_at > now() - interval '1 hour'),
    'connectors_failing', (select count(*) from doctor.connectors where status = 'failing'),
    'sync_p95_seconds_1h', coalesce((select percentile_cont(0.95) within group (
      order by extract(epoch from finished_at - started_at)) from doctor.connector_syncs
      where finished_at > now() - interval '1 hour'), 0),
    'diagnoses_queued', (select count(*) from doctor.diagnoses where status = 'queued'),
    'diagnosis_queue_seconds', coalesce((select extract(epoch from now() - min(created_at))
      from doctor.diagnoses where status = 'queued'), 0),
    'diagnosis_p95_seconds_1h', coalesce((select percentile_cont(0.95) within group (
      order by duration_ms / 1000.0) from finished where duration_ms is not null), 0),
    'diagnoses_failed_1h', (select count(*) from finished where status = 'failed'),
    -- Falha do LLM sobre os Diagnósticos que chamaram o LLM (reserva de Cota, #31).
    'llm_error_rate_1h', coalesce((select (count(*) filter (where status = 'failed_llm'))::float
      / nullif(count(*), 0) from finished where used_llm), 0),
    'llm_tokens_1h', coalesce((select sum(input_tokens + output_tokens) from doctor.usage_llm
      where created_at > now() - interval '1 hour'), 0),
    'db_connections', (select count(*) from pg_stat_activity),
    'db_max_connections', current_setting('max_connections')::int
  )
$$;
revoke all on function doctor.platform_health() from public, anon, authenticated;
grant execute on function doctor.platform_health() to service_role;

-- A função roda a cada minuto no banco compartilhado com o jayv-coder (ADR-0009): cada filtro
-- dela tem um índice parcial, pequeno, em vez de varrer as tabelas.
create index ingestion_batches_pending_age_idx on doctor.ingestion_batches (created_at)
  where processed_at is null and failed_at is null;
create index ingestion_batches_failed_idx on doctor.ingestion_batches (failed_at)
  where failed_at is not null;
create index diagnoses_queued_age_idx on doctor.diagnoses (created_at) where status = 'queued';
create index diagnoses_updated_idx on doctor.diagnoses (updated_at);
create index connector_syncs_finished_idx on doctor.connector_syncs (finished_at)
  where finished_at is not null;
create index connectors_failing_idx on doctor.connectors (id) where status = 'failing';
create index usage_llm_created_idx on doctor.usage_llm (created_at);
