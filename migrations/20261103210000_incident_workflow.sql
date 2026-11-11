-- Fluxo dos Incidentes (ticket #20): número por Organização (INC-0001), status com transições
-- validadas no banco, histórico, responsável e comentários com menções.

-- Número sequencial por Organização, sem buracos visíveis por concorrência: o contador da
-- Organização é travado na mesma transação do insert.
create table doctor.incident_counters (
  tenant_id uuid primary key references doctor.tenants (id) on delete cascade,
  last_number integer not null default 0,
  updated_at timestamptz not null default now()
);
comment on table doctor.incident_counters is 'Último número de Incidente de cada Organização (INC-0001…).';
alter table doctor.incident_counters enable row level security;
revoke all on doctor.incident_counters from anon, authenticated;

alter table doctor.incidents add column number integer;

create function doctor.assign_incident_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into doctor.incident_counters as c (tenant_id, last_number)
  values (new.tenant_id, 1)
  on conflict (tenant_id) do update set last_number = c.last_number + 1, updated_at = now()
  returning last_number into new.number;
  return new;
end;
$$;

create trigger incidents_assign_number
before insert on doctor.incidents
for each row execute function doctor.assign_incident_number();

-- Incidentes abertos antes desta migração ganham número na ordem de criação.
with numbered as (
  select id, row_number() over (partition by tenant_id order by created_at, id) as n
  from doctor.incidents
)
update doctor.incidents i set number = numbered.n from numbered where i.id = numbered.id;
insert into doctor.incident_counters (tenant_id, last_number)
select tenant_id, max(number) from doctor.incidents group by tenant_id;

alter table doctor.incidents alter column number set not null;
alter table doctor.incidents add constraint incidents_number_unique unique (tenant_id, number);

-- Resolver exige nota (ela alimenta a Base de conhecimento no #26).
alter table doctor.incidents add constraint incidents_resolution_note
  check (
    status <> 'resolved'
    or (resolved_at is not null and coalesce(char_length(btrim(resolution_note)), 0) > 0)
  );

-- open → investigating → resolved | dismissed, com reabertura. O banco valida a transição, venha
-- de onde vier (API, worker de Regras).
create function doctor.check_incident_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = old.status then
    return new;
  end if;
  if not (
    (old.status = 'open' and new.status in ('investigating', 'resolved', 'dismissed'))
    or (old.status = 'investigating' and new.status in ('open', 'resolved', 'dismissed'))
    or (old.status in ('resolved', 'dismissed') and new.status = 'open')
  ) then
    raise exception 'transição de % para % não é permitida', old.status, new.status
      using errcode = 'DR010';
  end if;
  if new.status = 'resolved' then
    new.resolved_at := coalesce(new.resolved_at, now());
  elsif old.status = 'resolved' then
    new.resolved_at := null;
  end if;
  return new;
end;
$$;

create trigger incidents_check_transition
before update of status on doctor.incidents
for each row execute function doctor.check_incident_transition();

create table doctor.incident_history (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  -- Nulo quando foi a plataforma (reabertura por Execução nova).
  actor_id uuid references auth.users (id) on delete set null,
  action text not null check (action in ('status', 'severity', 'assignee', 'reopened')),
  from_value text,
  to_value text,
  note text check (char_length(note) <= 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade
);
comment on table doctor.incident_history is 'Mudanças de status, severidade e responsável de um Incidente.';
create index incident_history_incident_idx on doctor.incident_history (tenant_id, incident_id, created_at);

create trigger incident_history_set_updated_at
before update on doctor.incident_history
for each row execute function doctor.set_updated_at();

create table doctor.incident_comments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  author_id uuid references auth.users (id) on delete set null,
  body_md text not null check (char_length(btrim(body_md)) between 1 and 4000),
  -- Membros mencionados com @ (a API confere que são da Organização).
  mentions uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade
);
comment on table doctor.incident_comments is 'Comentários de um Incidente, com menções a membros.';
create index incident_comments_incident_idx on doctor.incident_comments (tenant_id, incident_id, created_at);

create trigger incident_comments_set_updated_at
before update on doctor.incident_comments
for each row execute function doctor.set_updated_at();

create index incidents_status_idx on doctor.incidents (tenant_id, status, last_seen_at desc);

alter table doctor.incident_history enable row level security;
alter table doctor.incident_comments enable row level security;
revoke all on doctor.incident_history, doctor.incident_comments from anon, authenticated;
grant select on doctor.incident_history, doctor.incident_comments to authenticated;

create policy incident_history_select on doctor.incident_history
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy incident_comments_select on doctor.incident_comments
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- Mudanças pela API: Analyst ou acima (o Viewer só lê), com o Papel conferido na tabela.
create function doctor.update_incident(
  target uuid, new_status text, new_severity text, new_assignee uuid, set_assignee boolean, note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current_row doctor.incidents;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  select * into current_row from doctor.incidents i
  where i.tenant_id = tenant and i.id = target for update;
  if not found then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  if set_assignee and new_assignee is not null and not exists (
    select 1 from doctor.memberships m where m.tenant_id = tenant and m.user_id = new_assignee
  ) then
    raise exception 'responsável não é membro da Organização' using errcode = 'DR011';
  end if;

  update doctor.incidents i set
    status = coalesce(new_status, i.status),
    severity = coalesce(new_severity, i.severity),
    assignee_id = case when set_assignee then new_assignee else i.assignee_id end,
    resolution_note = case when new_status = 'resolved' then note else i.resolution_note end
  where i.id = current_row.id;

  if new_status is not null and new_status <> current_row.status then
    insert into doctor.incident_history (tenant_id, incident_id, actor_id, action, from_value, to_value, note)
    values (tenant, target, auth.uid(), 'status', current_row.status, new_status, note);
  end if;
  if new_severity is not null and new_severity <> current_row.severity then
    insert into doctor.incident_history (tenant_id, incident_id, actor_id, action, from_value, to_value)
    values (tenant, target, auth.uid(), 'severity', current_row.severity, new_severity);
  end if;
  if set_assignee and new_assignee is distinct from current_row.assignee_id then
    insert into doctor.incident_history (tenant_id, incident_id, actor_id, action, from_value, to_value)
    values (tenant, target, auth.uid(), 'assignee', current_row.assignee_id::text, new_assignee::text);
  end if;
  perform doctor.record_audit(tenant, 'incident.update', target::text);
end;
$$;

create function doctor.add_incident_comment(target uuid, body text, mentioned uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  created uuid;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  if not exists (select 1 from doctor.incidents i where i.tenant_id = tenant and i.id = target) then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  -- Menção a quem não é da Organização é descartada, sem erro: o texto continua.
  insert into doctor.incident_comments (tenant_id, incident_id, author_id, body_md, mentions)
  values (
    tenant, target, auth.uid(), body,
    coalesce(array(
      select distinct m.user_id from doctor.memberships m
      where m.tenant_id = tenant and m.user_id = any (mentioned)
    ), '{}')
  )
  returning id into created;
  return created;
end;
$$;

revoke all on function doctor.update_incident(uuid, text, text, uuid, boolean, text) from public, service_role;
revoke all on function doctor.add_incident_comment(uuid, text, uuid[]) from public, service_role;
revoke all on function doctor.assign_incident_number() from public;
revoke all on function doctor.check_incident_transition() from public;
grant execute on function doctor.update_incident(uuid, text, text, uuid, boolean, text) to authenticated;
grant execute on function doctor.add_incident_comment(uuid, text, uuid[]) to authenticated;

-- Lista em tempo real: o evento passa pelo RLS de quem assina e só dispara a busca na API.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'doctor' and tablename = 'incidents'
    )
  then
    alter publication supabase_realtime add table doctor.incidents;
  end if;
end;
$$;
