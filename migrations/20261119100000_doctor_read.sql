-- Leituras do site direto no Supabase (ADR-0026 do jayv-doctor). A API do Doctor roda longe do
-- banco (Railway nos EUA, banco em São Paulo), e cada leitura passava por ela comando a comando.
-- O site passa a ler pelo schema `doctor_read`, exposto na API de dados (PostgREST): uma função
-- por tela, que devolve tudo de uma vez, com o RLS de quem chama. As escritas continuam pela API.
--
-- O schema `doctor` continua fora da API de dados: `anon` executa nele as funções por token
-- (ingestão, SCIM, agente, webhooks), que só a API deve chamar.

-- A Organização do JWT só vale com Vínculo vivo. O token dura até 1 h: sem isto, quem foi
-- removido (na tela, por SCIM ou pelo SSO) continuaria lendo pelo RLS e recebendo o Realtime até
-- ele vencer. A API já conferia isso a cada pedido; agora o banco confere para todos. Quem age
-- sem Usuário (os workers, com a claim do tenant) segue como antes.
create function doctor.has_membership(tenant uuid, member uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from doctor.memberships m where m.tenant_id = tenant and m.user_id = member
  )
$$;

create or replace function doctor.current_tenant_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select case
    when claim.tenant is null then null
    when auth.uid() is null or doctor.has_membership(claim.tenant, auth.uid()) then claim.tenant
  end
  from (select nullif(auth.jwt() ->> 'tenant_id', '')::uuid as tenant) claim
$$;

revoke all on function doctor.has_membership(uuid, uuid) from public, anon;
-- `current_tenant_id()` a chama para todo papel que avalia o RLS, inclusive os jobs de plataforma.
grant execute on function doctor.has_membership(uuid, uuid) to authenticated, service_role;

create schema doctor_read;
comment on schema doctor_read is
  'Leituras do site direto no Supabase (ADR-0026): funções com o RLS de quem chama.';
revoke all on schema doctor_read from public, anon;
grant usage on schema doctor_read to authenticated;

-- Auxiliares das leituras: ficam em `doctor`, fora da API de dados, para o PostgREST oferecer só
-- uma função por tela.

-- A Organização ativa de quem chama, com Vínculo; sem ela, nada a ler.
create function doctor.read_tenant()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  if tenant is null then
    raise insufficient_privilege using message = 'sem Organização ativa';
  end if;
  return tenant;
end;
$$;

-- Variação relativa; sem valor ou com base zero, não há comparação (como na API).
create function doctor.read_change(current_value numeric, previous_value numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when current_value is null or previous_value is null or previous_value = 0 then null
    else (current_value - previous_value) / previous_value end
$$;

create function doctor.read_incident(n doctor.incidents, i doctor.integrations)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', n.id, 'number', n.number, 'title', n.title, 'category', n.category,
    'severity', n.severity, 'status', n.status, 'rule_code', n.rule_code,
    'rule_version', n.rule_version, 'integration_id', n.integration_id,
    'integration_name', i.name, 'environment', i.environment,
    'first_seen_at', n.first_seen_at, 'last_seen_at', n.last_seen_at,
    'execution_count', n.execution_count, 'assignee_id', n.assignee_id,
    'resolved_at', n.resolved_at
  )
$$;

-- Quem entrou, as Organizações do Doctor e a ativa (o `GET /me` da API). Dá antes o Vínculo que
-- falta nas Organizações do jayv-coder em que o Doctor está ativo (ADR-0025); se isso falhar, a
-- leitura segue com o que há.
create function doctor_read.me()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  active uuid;
begin
  if auth.uid() is null then
    raise insufficient_privilege using message = 'sessão obrigatória';
  end if;
  begin
    perform doctor.join_organizations();
  exception when others then
    raise warning 'doctor_read.me: acesso automático falhou: %', sqlstate;
  end;
  active := doctor.current_tenant_id();
  return jsonb_build_object(
    'id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'aal', auth.jwt() ->> 'aal',
    'profile', (
      select jsonb_build_object('full_name', p.display_name, 'avatar_url', p.avatar_url, 'locale', 'pt-BR')
      from public.profiles p where p.user_id = auth.uid()
    ),
    'organizations', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug, 'role', o.role) order by o.name)
      from doctor.list_organizations() o
    ), '[]'::jsonb),
    'available_organizations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'slug', a.slug, 'coder_role', a.coder_role) order by a.name)
      from doctor.available_organizations() a
    ), '[]'::jsonb),
    'active_tenant_id', active,
    'active_role', case when active is not null then auth.jwt() ->> 'tenant_role' end
  );
end;
$$;

-- O painel executivo (o `GET /dashboard` da API, ticket #21): Execuções e falhas do agregado por
-- hora, Incidentes e MTTR da tabela de Incidentes, o período e o anterior, tudo numa chamada.
create function doctor_read.dashboard(
  period text default '24h',
  environment text default null,
  integration uuid default null
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant uuid := doctor.read_tenant();
  span interval;
  bucket text;
  step interval;
  until_at timestamptz := now();
  start_at timestamptz;
  previous_at timestamptz;
  totals record;
  mttr record;
  rate numeric;
  before_rate numeric;
  baseline integer;
begin
  span := case period when '24h' then interval '24 hours' when '7d' then interval '7 days'
    when '30d' then interval '30 days' end;
  if span is null then
    raise invalid_parameter_value using message = 'período inválido';
  end if;
  bucket := case when period = '24h' then 'hour' else 'day' end;
  step := case when bucket = 'hour' then interval '1 hour' else interval '1 day' end;
  start_at := until_at - span;
  previous_at := until_at - 2 * span;

  select
    coalesce(sum(s.total) filter (where s.hour >= start_at), 0)::int as total,
    coalesce(sum(s.failed) filter (where s.hour >= start_at), 0)::int as failed,
    coalesce(sum(s.total) filter (where s.hour < start_at), 0)::int as before_total,
    coalesce(sum(s.failed) filter (where s.hour < start_at), 0)::int as before_failed
  into totals
  from doctor.execution_stats_hourly s
  join doctor.integrations i on i.tenant_id = s.tenant_id and i.id = s.integration_id
  where s.hour >= previous_at and s.hour < until_at
    and (dashboard.environment is null or i.environment = dashboard.environment)
    and (dashboard.integration is null or i.id = dashboard.integration);

  select
    round((avg(extract(epoch from (n.resolved_at - n.first_seen_at)) / 60)
      filter (where n.resolved_at >= start_at))::numeric, 1) as current_value,
    round((avg(extract(epoch from (n.resolved_at - n.first_seen_at)) / 60)
      filter (where n.resolved_at < start_at))::numeric, 1) as before_value
  into mttr
  from doctor.incidents n
  join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
  where n.status = 'resolved' and n.resolved_at >= previous_at and n.resolved_at < until_at
    and (dashboard.environment is null or i.environment = dashboard.environment)
    and (dashboard.integration is null or i.id = dashboard.integration);

  rate := case when totals.total > 0 then totals.failed::numeric / totals.total end;
  before_rate := case when totals.before_total > 0
    then totals.before_failed::numeric / totals.before_total end;
  select t.mttr_baseline_minutes into baseline from doctor.tenants t where t.id = tenant;

  return jsonb_build_object(
    'period', period,
    'bucket', bucket,
    'executions', jsonb_build_object('value', totals.total, 'previous', totals.before_total,
      'change', doctor.read_change(totals.total, totals.before_total)),
    'error_rate', jsonb_build_object('value', rate, 'previous', before_rate,
      'change', doctor.read_change(rate, before_rate)),
    'mttr_minutes', jsonb_build_object('value', mttr.current_value, 'previous', mttr.before_value,
      'change', doctor.read_change(mttr.current_value, mttr.before_value)),
    'open_incidents', (
      select count(*)::int from doctor.incidents n
      join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
      where n.status in ('open', 'investigating')
        and (dashboard.environment is null or i.environment = dashboard.environment)
        and (dashboard.integration is null or i.id = dashboard.integration)
    ),
    'mttr_baseline_minutes', baseline,
    'mttr_vs_baseline', doctor.read_change(mttr.current_value, baseline),
    -- Série completa, em UTC: intervalo sem falha aparece como zero, não some.
    'failures', coalesce((
      with series as (
        select generate_series(
          date_trunc(bucket, start_at, 'UTC'), date_trunc(bucket, until_at, 'UTC'), step
        ) as start
      ),
      sums as (
        select date_trunc(bucket, s.hour, 'UTC') as start, sum(s.total)::int as total,
          sum(s.failed)::int as failed
        from doctor.execution_stats_hourly s
        join doctor.integrations i on i.tenant_id = s.tenant_id and i.id = s.integration_id
        where s.hour >= start_at and s.hour < until_at
          and (dashboard.environment is null or i.environment = dashboard.environment)
          and (dashboard.integration is null or i.id = dashboard.integration)
        group by 1
      )
      select jsonb_agg(jsonb_build_object('start', series.start, 'total', coalesce(sums.total, 0),
        'failed', coalesce(sums.failed, 0)) order by series.start)
      from series left join sums using (start)
    ), '[]'::jsonb),
    'failures_by_category', coalesce((
      select jsonb_agg(jsonb_build_object('category', c.category, 'count', c.count)
        order by c.count desc, c.category)
      from (
        select k.key as category, sum(k.value::int)::int as count
        from doctor.execution_stats_hourly s
        join doctor.integrations i on i.tenant_id = s.tenant_id and i.id = s.integration_id
        cross join lateral jsonb_each_text(s.by_category) k
        where s.hour >= start_at and s.hour < until_at
          and (dashboard.environment is null or i.environment = dashboard.environment)
          and (dashboard.integration is null or i.id = dashboard.integration)
        group by k.key
      ) c
    ), '[]'::jsonb),
    'critical_incident', (
      select doctor.read_incident(n, i) from doctor.incidents n
      join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
      where n.status in ('open', 'investigating') and n.severity = 'critical'
        and (dashboard.environment is null or i.environment = dashboard.environment)
        and (dashboard.integration is null or i.id = dashboard.integration)
      order by n.last_seen_at desc limit 1
    ),
    'recent_incidents', coalesce((
      select jsonb_agg(doctor.read_incident(r.n, r.i) order by (r.n).last_seen_at desc)
      from (
        select n, i from doctor.incidents n
        join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
        where (dashboard.environment is null or i.environment = dashboard.environment)
          and (dashboard.integration is null or i.id = dashboard.integration)
        order by n.last_seen_at desc limit 5
      ) r
    ), '[]'::jsonb)
  );
end;
$$;

-- A lista de Incidentes (o `POST /incidents/search` da API, Tela 5), sem a busca por texto, que
-- precisa do HMAC da Referência de negócio e continua pela API. Página por cursor
-- (last_seen_at, id) e, na primeira página, a contagem por status com os outros filtros.
create function doctor_read.incidents(
  status text[] default null,
  severity text[] default null,
  category text default null,
  integration uuid default null,
  environment text default null,
  assignee uuid default null,
  since timestamptz default null,
  until timestamptz default null,
  cursor_at timestamptz default null,
  cursor_id uuid default null,
  lim integer default 20
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant uuid := doctor.read_tenant();
  size integer := least(greatest(coalesce(lim, 20), 1), 50);
  rows jsonb;
  more boolean;
  last_item jsonb;
begin
  select coalesce(jsonb_agg(doctor.read_incident(r.n, r.i) order by (r.n).last_seen_at desc, (r.n).id desc), '[]'::jsonb)
  into rows
  from (
    select n, i from doctor.incidents n
    join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
    where (incidents.status is null or n.status = any(incidents.status))
      and (incidents.severity is null or n.severity = any(incidents.severity))
      and (incidents.category is null or n.category = incidents.category)
      and (incidents.integration is null or n.integration_id = incidents.integration)
      and (incidents.environment is null or i.environment = incidents.environment)
      and (incidents.assignee is null or n.assignee_id = incidents.assignee)
      and (incidents.since is null or n.last_seen_at >= incidents.since)
      and (incidents.until is null or n.first_seen_at <= incidents.until)
      and (incidents.cursor_at is null or (n.last_seen_at, n.id) < (incidents.cursor_at, incidents.cursor_id))
    order by n.last_seen_at desc, n.id desc
    limit size + 1
  ) r;

  more := jsonb_array_length(rows) > size;
  if more then
    rows := rows - size;
  end if;
  last_item := rows -> (jsonb_array_length(rows) - 1);

  return jsonb_build_object(
    'items', rows,
    'next_cursor', case when more then jsonb_build_object('at', last_item -> 'last_seen_at', 'id', last_item -> 'id') end,
    -- Os chips só usam as contagens da primeira página.
    'counts', case when incidents.cursor_at is null then coalesce((
      select jsonb_object_agg(c.status, c.total) from (
        select n.status, count(*)::int as total from doctor.incidents n
        join doctor.integrations i on i.tenant_id = n.tenant_id and i.id = n.integration_id
        where (incidents.severity is null or n.severity = any(incidents.severity))
          and (incidents.category is null or n.category = incidents.category)
          and (incidents.integration is null or n.integration_id = incidents.integration)
          and (incidents.environment is null or i.environment = incidents.environment)
          and (incidents.assignee is null or n.assignee_id = incidents.assignee)
          and (incidents.since is null or n.last_seen_at >= incidents.since)
          and (incidents.until is null or n.first_seen_at <= incidents.until)
        group by n.status
      ) c
    ), '{}'::jsonb) else '{}'::jsonb end
  );
end;
$$;

revoke all on function doctor.read_tenant() from public, anon, service_role;
revoke all on function doctor.read_change(numeric, numeric) from public, anon, service_role;
revoke all on function doctor.read_incident(doctor.incidents, doctor.integrations) from public, anon, service_role;
grant execute on function doctor.read_tenant() to authenticated;
grant execute on function doctor.read_change(numeric, numeric) to authenticated;
grant execute on function doctor.read_incident(doctor.incidents, doctor.integrations) to authenticated;

revoke all on all functions in schema doctor_read from public, anon, service_role;
grant execute on all functions in schema doctor_read to authenticated;
