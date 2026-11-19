-- #49 (Políticas avançadas), MFA obrigatório para todos os Papéis. Com a política ligada na
-- Organização, sessão sem o segundo fator (aal1) não lê nem grava nada dela: a regra fica em
-- `doctor.current_tenant_id()`, o mesmo ponto do Vínculo (ADR-0026), e vale para a API, as
-- leituras diretas do site e o Realtime. Quem age sem Usuário (os workers) segue como antes.

alter table doctor.tenants add column require_mfa boolean not null default false;
comment on column doctor.tenants.require_mfa is
  'Exige o segundo fator (aal2) de todos os Papéis para ler e gravar na Organização (#49).';

-- Por que quem pede não acessa a Organização: nulo se acessa; `no_membership` sem Vínculo;
-- `mfa_required` se a Organização exige MFA e a sessão não o tem. Só fala de quem pede
-- (`auth.uid()` e o aal da sessão), e "sem Vínculo" vem antes: de fora, a política não vaza.
create function doctor.tenant_access(tenant uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (
      select 1 from doctor.memberships m where m.tenant_id = tenant and m.user_id = auth.uid()
    ) then 'no_membership'
    when doctor.current_aal() is distinct from 'aal2' and exists (
      select 1 from doctor.tenants t where t.id = tenant and t.require_mfa
    ) then 'mfa_required'
  end
$$;

-- O Vínculo agora é conferido em tenant_access.
drop function doctor.has_membership(uuid, uuid);

create or replace function doctor.current_tenant_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select case
    when claim.tenant is null then null
    when auth.uid() is null then claim.tenant
    when doctor.tenant_access(claim.tenant) is null then claim.tenant
  end
  from (select nullif(auth.jwt() ->> 'tenant_id', '')::uuid as tenant) claim
$$;

-- O motivo para a Organização do JWT de quem pede (a API e o site o mostram).
create function doctor.access_problem()
returns text
language sql
stable
set search_path = ''
as $$
  select case when claim.tenant is not null and auth.uid() is not null
    then doctor.tenant_access(claim.tenant) end
  from (select nullif(auth.jwt() ->> 'tenant_id', '')::uuid as tenant) claim
$$;

-- Liga ou desliga a política e devolve o valor gravado: Owner ou Admin com MFA
-- (`require_manager`); o trigger de auditoria de `tenants` registra a mudança.
create function doctor.set_require_mfa(enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved boolean;
begin
  perform doctor.require_manager();
  update doctor.tenants t set require_mfa = enabled where t.id = doctor.current_tenant_id()
  returning t.require_mfa into saved;
  return saved;
end;
$$;

-- As leituras diretas dizem por que não leram, numa faixa própria (DR110–DR119): os DR100–DR104
-- do bloco anterior já eram do SSO. DR110: sem Organização ativa; DR111: cursor pela metade;
-- DR112: falta o MFA que a Organização exige.
-- O cursor vem inteiro (instante e id) ou não vem: num lugar só, para as buscas.
create function doctor.read_cursor(cursor_at timestamptz, cursor_id uuid)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if (cursor_at is null) <> (cursor_id is null) then
    raise exception 'cursor pela metade' using errcode = 'DR111';
  end if;
end;
$$;

create or replace function doctor.read_tenant()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  if tenant is null then
    if doctor.access_problem() is not distinct from 'mfa_required' then
      raise exception 'a Organização exige verificação em duas etapas' using errcode = 'DR112';
    end if;
    raise exception 'sem Organização ativa' using errcode = 'DR110';
  end if;
  return tenant;
end;
$$;

create or replace function doctor_read.incidents(
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
set plan_cache_mode = force_custom_plan
as $$
declare
  tenant uuid := doctor.read_tenant();
  size integer := least(greatest(coalesce(lim, 20), 1), 50);
  rows jsonb;
  more boolean;
  last_item jsonb;
begin
  perform doctor.read_cursor(cursor_at, cursor_id);
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

create or replace function doctor_read.executions(
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
set plan_cache_mode = force_custom_plan
as $$
declare
  size integer := least(greatest(coalesce(lim, 50), 1), 50);
  rows jsonb;
  more boolean;
  last_item jsonb;
begin
  perform doctor.read_tenant();
  perform doctor.read_cursor(cursor_at, cursor_id);
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

create or replace function doctor_read.me()
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
    'active_role', case when active is not null then auth.jwt() ->> 'tenant_role' end,
    -- A Organização do JWT exige MFA e esta sessão não o tem: o site manda configurar.
    'mfa_required', doctor.access_problem() is not distinct from 'mfa_required'
  );
end;
$$;

revoke all on function doctor.tenant_access(uuid) from public, anon;
grant execute on function doctor.tenant_access(uuid) to authenticated, service_role;
revoke all on function doctor.read_cursor(timestamptz, uuid) from public, anon, service_role;
grant execute on function doctor.read_cursor(timestamptz, uuid) to authenticated;
revoke all on function doctor.access_problem() from public, anon;
grant execute on function doctor.access_problem() to authenticated, service_role;
revoke all on function doctor.set_require_mfa(boolean) from public, anon, service_role;
grant execute on function doctor.set_require_mfa(boolean) to authenticated;
