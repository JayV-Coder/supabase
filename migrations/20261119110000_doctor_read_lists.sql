-- Leituras diretas do site (ADR-0026 do jayv-doctor), segundo bloco: Integrações, Execuções e
-- Conectores, as listas que mais páginas do Doctor pedem. Cada uma é o equivalente da rota da
-- API (`GET /integrations`, `POST /executions/search` sem termo, `GET /connectors`), com o RLS de
-- quem chama e a Organização só com Vínculo (`doctor.read_tenant`).

-- As Integrações, por nome e Ambiente, com a taxa de erro das últimas 24 h (falhas sobre o total
-- das estatísticas por hora; sem Execução, nula: 0% passaria a ideia de que está tudo bem).
create function doctor_read.integrations(include_archived boolean default false)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform doctor.read_tenant();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'description', i.description,
      'source_system', i.source_system, 'target_system', i.target_system,
      'owner_team', i.owner_team, 'environment', i.environment,
      'archived_at', i.archived_at, 'created_at', i.created_at,
      'error_rate_24h', (
        select sum(s.failed)::float8 / nullif(sum(s.total), 0)
        from doctor.execution_stats_hourly s
        where s.tenant_id = i.tenant_id and s.integration_id = i.id
          and s.hour >= date_trunc('hour', now() - interval '24 hours')
      )
    ) order by i.name, i.environment)
    from doctor.integrations i
    where integrations.include_archived or i.archived_at is null
  ), '[]'::jsonb);
end;
$$;

-- O Explorador de Execuções sem a busca por texto (que precisa do HMAC da Referência de negócio
-- e continua pela API): filtros, página por cursor (first_event_at, id) e o Incidente ligado.
create function doctor_read.executions(
  status text default null,
  integration uuid default null,
  environment text default null,
  since timestamptz default null,
  until timestamptz default null,
  cursor_at timestamptz default null,
  cursor_id uuid default null,
  lim integer default 50
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  size integer := least(greatest(coalesce(lim, 50), 1), 50);
  rows jsonb;
  more boolean;
  last_item jsonb;
begin
  perform doctor.read_tenant();
  select coalesce(jsonb_agg(r.item order by r.first_event_at desc, r.id desc), '[]'::jsonb)
  into rows
  from (
    select x.first_event_at, x.id, jsonb_build_object(
      'id', x.id, 'integration_id', x.integration_id, 'integration_name', i.name,
      'environment', i.environment, 'status', x.status, 'low_confidence', x.low_confidence,
      'first_event_at', x.first_event_at, 'last_event_at', x.last_event_at,
      'duration_ms', x.duration_ms, 'event_count', x.event_count, 'closed_at', x.closed_at,
      'correlation_keys', x.correlation_keys,
      'incident', case when inc.id is null then null else jsonb_build_object(
        'id', inc.id, 'title', inc.title, 'severity', inc.severity, 'status', inc.status) end
    ) as item
    from doctor.executions x
    join doctor.integrations i on i.tenant_id = x.tenant_id and i.id = x.integration_id
    left join doctor.incident_executions ie on ie.tenant_id = x.tenant_id and ie.execution_id = x.id
    left join doctor.incidents inc on inc.tenant_id = ie.tenant_id and inc.id = ie.incident_id
    where x.merged_into is null
      and (executions.status is null or x.status = executions.status)
      and (executions.integration is null or x.integration_id = executions.integration)
      and (executions.environment is null or i.environment = executions.environment)
      and (executions.since is null or x.last_event_at >= executions.since)
      and (executions.until is null or x.first_event_at <= executions.until)
      and (executions.cursor_at is null or (x.first_event_at, x.id) < (executions.cursor_at, executions.cursor_id))
    order by x.first_event_at desc, x.id desc
    limit size + 1
  ) r;

  more := jsonb_array_length(rows) > size;
  if more then
    rows := rows - size;
  end if;
  last_item := rows -> (jsonb_array_length(rows) - 1);
  return jsonb_build_object(
    'items', rows,
    'next_cursor', case when more then jsonb_build_object('at', last_item -> 'first_event_at', 'id', last_item -> 'id') end
  );
end;
$$;

-- Os Conectores, do mais novo ao mais antigo, com os registros da última coleta terminada. A
-- referência da credencial (`secret_id`, no Vault) não sai.
create function doctor_read.connectors()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform doctor.read_tenant();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'integration_id', c.integration_id, 'provider', c.provider, 'name', c.name,
      'config', c.config, 'status', c.status, 'paused_reason', c.paused_reason,
      'consecutive_failures', c.consecutive_failures,
      'sync_interval_seconds', c.sync_interval_seconds, 'checkpoint', c.checkpoint,
      'last_sync_at', c.last_sync_at, 'last_error', c.last_error,
      'next_run_at', c.next_run_at, 'created_at', c.created_at,
      'last_sync_records', (
        select s.records from doctor.connector_syncs s
        where s.tenant_id = c.tenant_id and s.connector_id = c.id and s.finished_at is not null
        order by s.started_at desc limit 1
      )
    ) order by c.created_at desc)
    from doctor.connectors c
  ), '[]'::jsonb);
end;
$$;

revoke all on function doctor_read.integrations(boolean) from public, anon, service_role;
revoke all on function doctor_read.executions(text, uuid, text, timestamptz, timestamptz, timestamptz, uuid, integer) from public, anon, service_role;
revoke all on function doctor_read.connectors() from public, anon, service_role;
grant execute on function doctor_read.integrations(boolean) to authenticated;
grant execute on function doctor_read.executions(text, uuid, text, timestamptz, timestamptz, timestamptz, uuid, integer) to authenticated;
grant execute on function doctor_read.connectors() to authenticated;
