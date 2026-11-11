-- Dashboard executivo (ticket #21): agregado por hora das Execuções e baseline do MTTR.

alter table doctor.tenants add column mttr_baseline_minutes integer
  check (mttr_baseline_minutes is null or mttr_baseline_minutes > 0);
comment on column doctor.tenants.mttr_baseline_minutes is
  'MTTR de referência do piloto, em minutos: o Dashboard mostra a variação contra ele.';

create table doctor.execution_stats_hourly (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  hour timestamptz not null check (date_trunc('hour', hour, 'UTC') = hour),
  total integer not null default 0 check (total >= 0),
  failed integer not null default 0 check (failed >= 0 and failed <= total),
  -- Falhas por categoria do Incidente da Execução; sem Incidente, `UNCLASSIFIED`.
  by_category jsonb not null default '{}' check (jsonb_typeof(by_category) = 'object'),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, integration_id, hour),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id) on delete cascade
);
comment on table doctor.execution_stats_hourly is 'Execuções e falhas por Integração e hora (pelo primeiro Evento).';
create index execution_stats_hourly_time_idx on doctor.execution_stats_hourly (tenant_id, hour desc);

create trigger execution_stats_hourly_set_updated_at
before update on doctor.execution_stats_hourly
for each row execute function doctor.set_updated_at();

alter table doctor.execution_stats_hourly enable row level security;
revoke all on doctor.execution_stats_hourly from anon, authenticated;
grant select on doctor.execution_stats_hourly to authenticated;
create policy execution_stats_hourly_select on doctor.execution_stats_hourly
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- Horas a recalcular. Triggers anotam a hora antiga e a nova de toda mudança que mexe no
-- agregado (Execução criada, fundida, com status ou primeiro Evento novos; Execução que entra
-- ou sai de um Incidente); o job drena a fila. Assim nenhuma hora fica para trás, nem depois de
-- uma falha longa do job, e quem escrever no futuro não precisa lembrar de avisar ninguém.
-- Fila interna da plataforma: sem id próprio nem updated_at (exceção à convenção).
-- Sem FK: apagar uma Organização apaga as Execuções em cascata, e o trigger delas ainda anota
-- horas; o job descarta as de Integração que não existe mais.
create table doctor.execution_stats_dirty (
  tenant_id uuid not null,
  integration_id uuid not null,
  hour timestamptz not null,
  queued_at timestamptz not null default now(),
  primary key (tenant_id, integration_id, hour)
);
comment on table doctor.execution_stats_dirty is 'Fila de horas do agregado do Dashboard a recalcular.';
alter table doctor.execution_stats_dirty enable row level security;
revoke all on doctor.execution_stats_dirty from anon, authenticated;

create function doctor.utc_hour(moment timestamptz)
returns timestamptz
language sql
immutable
set search_path = ''
as $$ select date_trunc('hour', moment, 'UTC') $$;

create function doctor.mark_execution_hours()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    insert into doctor.execution_stats_dirty (tenant_id, integration_id, hour)
    select old.tenant_id, old.integration_id, doctor.utc_hour(old.first_event_at)
    where exists (select 1 from doctor.integrations i where i.id = old.integration_id)
    on conflict do nothing;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    insert into doctor.execution_stats_dirty (tenant_id, integration_id, hour)
    values (new.tenant_id, new.integration_id, doctor.utc_hour(new.first_event_at))
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger executions_mark_stats
after insert or delete or update of status, first_event_at, merged_into, integration_id
on doctor.executions
for each row execute function doctor.mark_execution_hours();

-- A categoria muda quando a Execução entra, sai ou troca de Incidente.
create function doctor.mark_incident_execution_hours()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into doctor.execution_stats_dirty (tenant_id, integration_id, hour)
  select x.tenant_id, x.integration_id, doctor.utc_hour(x.first_event_at)
  from doctor.executions x
  where (x.tenant_id, x.id) in (
    select old.tenant_id, old.execution_id where tg_op <> 'INSERT'
    union all
    select new.tenant_id, new.execution_id where tg_op <> 'DELETE'
  )
  on conflict do nothing;
  return null;
end;
$$;

create trigger incident_executions_mark_stats
after insert or delete or update on doctor.incident_executions
for each row execute function doctor.mark_incident_execution_hours();

-- Drena até `batch` horas da fila e as recalcula do zero (idempotente: repetir não conta duas
-- vezes). Job de plataforma, todas as Organizações; devolve quantas horas recalculou.
create function doctor.refresh_execution_stats(batch integer default 5000)
returns integer
language sql
set search_path = ''
as $$
  with taken as (
    delete from doctor.execution_stats_dirty d
    using (
      select tenant_id, integration_id, hour from doctor.execution_stats_dirty
      order by queued_at limit batch for update skip locked
    ) picked
    where d.tenant_id = picked.tenant_id and d.integration_id = picked.integration_id
      and d.hour = picked.hour
    returning d.tenant_id, d.integration_id, d.hour
  ),
  categorized as (
    select t.tenant_id, t.integration_id, t.hour, x.status,
      coalesce(inc.category, 'UNCLASSIFIED') as category
    from taken t
    join doctor.executions x
      on x.tenant_id = t.tenant_id and x.integration_id = t.integration_id
      and x.first_event_at >= t.hour and x.first_event_at < t.hour + interval '1 hour'
      and x.merged_into is null
    left join doctor.incident_executions ie on ie.tenant_id = x.tenant_id and ie.execution_id = x.id
    left join doctor.incidents inc on inc.tenant_id = ie.tenant_id and inc.id = ie.incident_id
  ),
  per_category as (
    select tenant_id, integration_id, hour, category, count(*)::int as n
    from categorized where status = 'failed'
    group by tenant_id, integration_id, hour, category
  ),
  counts as (
    select tenant_id, integration_id, hour, count(*)::int as total,
      (count(*) filter (where status = 'failed'))::int as failed
    from categorized
    group by tenant_id, integration_id, hour
  ),
  categories as (
    select tenant_id, integration_id, hour, jsonb_object_agg(category, n) as by_category
    from per_category
    group by tenant_id, integration_id, hour
  ),
  -- Hora sem Execução nenhuma (todas fundidas ou movidas) fica zerada, não some.
  hourly as (
    select t.tenant_id, t.integration_id, t.hour,
      coalesce(c.total, 0) as total, coalesce(c.failed, 0) as failed,
      coalesce(k.by_category, '{}') as by_category
    from taken t
    left join counts c using (tenant_id, integration_id, hour)
    left join categories k using (tenant_id, integration_id, hour)
  ),
  upserted as (
    insert into doctor.execution_stats_hourly (tenant_id, integration_id, hour, total, failed, by_category)
    select h.tenant_id, h.integration_id, h.hour, h.total, h.failed, h.by_category from hourly h
    where exists (
      select 1 from doctor.integrations i where i.tenant_id = h.tenant_id and i.id = h.integration_id
    )
    on conflict (tenant_id, integration_id, hour) do update
      set total = excluded.total, failed = excluded.failed, by_category = excluded.by_category
    returning 1
  )
  select count(*)::int from upserted
$$;

revoke all on function doctor.refresh_execution_stats(integer) from public, anon, authenticated;
revoke all on function doctor.mark_execution_hours() from public;
revoke all on function doctor.utc_hour(timestamptz) from public;
revoke all on function doctor.mark_incident_execution_hours() from public;
grant execute on function doctor.refresh_execution_stats(integer) to service_role;
