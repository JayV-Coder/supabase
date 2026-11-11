-- Cotas e medição de uso por Organização (ticket #31, PRD §12). A cobrança fica para a v1.0
-- (#50). Contadores com incremento atômico; a imposição fica em triggers, para valer em todo
-- caminho (API, ingestão por token, Conectores, Importação).

-- Catálogo global de limites por plano (sem tenant): inventário do #27, exceção com o motivo.
create table doctor.plan_limits (
  plan text not null check (plan in ('pilot', 'professional', 'enterprise')),
  resource text not null check (resource in ('events_ingested', 'diagnoses_llm', 'storage_bytes', 'connectors_active', 'members')),
  period text not null check (period in ('month', 'none')),
  "limit" bigint not null check ("limit" > 0),
  primary key (plan, resource)
);
comment on table doctor.plan_limits is 'Limite de cada recurso por plano (mensal ou absoluto).';
insert into doctor.plan_limits (plan, resource, period, "limit") values
  ('pilot', 'events_ingested', 'month', 3000000),
  ('pilot', 'diagnoses_llm', 'month', 1000),
  ('pilot', 'storage_bytes', 'none', 50000000000),
  ('pilot', 'connectors_active', 'none', 5),
  ('pilot', 'members', 'none', 20),
  ('professional', 'events_ingested', 'month', 30000000),
  ('professional', 'diagnoses_llm', 'month', 10000),
  ('professional', 'storage_bytes', 'none', 500000000000),
  ('professional', 'connectors_active', 'none', 20),
  ('professional', 'members', 'none', 100),
  ('enterprise', 'events_ingested', 'month', 300000000),
  ('enterprise', 'diagnoses_llm', 'month', 100000),
  ('enterprise', 'storage_bytes', 'none', 5000000000000),
  ('enterprise', 'connectors_active', 'none', 200),
  ('enterprise', 'members', 'none', 1000);
alter table doctor.plan_limits enable row level security;
revoke all on doctor.plan_limits from anon, authenticated;
grant select on doctor.plan_limits to authenticated;
create policy plan_limits_select on doctor.plan_limits for select to authenticated using (true);

-- Tolerância da ingestão acima da Cota (110% por padrão), ajustável pela plataforma.
alter table doctor.tenants
  add column quota_tolerance numeric(4, 2) not null default 1.10 check (quota_tolerance between 1 and 2);

create table doctor.usage_records (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  resource text not null check (resource in ('events_ingested', 'diagnoses_llm', 'storage_bytes')),
  -- Recurso mensal: o primeiro dia do mês (UTC); medida absoluta (armazenamento): 1970-01-01.
  period_start date not null,
  quantity bigint not null default 0 check (quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, resource, period_start)
);
comment on table doctor.usage_records is 'Consumo da Organização por recurso e período.';

create table doctor.usage_llm (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid,
  provider text not null,
  model text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  -- Estimativa pela tabela de preços configurada no worker; nula sem tabela.
  cost_estimate numeric(12, 6),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  -- O uso fica mesmo depois que a retenção apaga o Diagnóstico.
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id)
    on delete set null (diagnosis_id)
);
comment on table doctor.usage_llm is 'Tokens de LLM por Diagnóstico.';
create index usage_llm_tenant_time_idx on doctor.usage_llm (tenant_id, created_at desc);
-- Uma reserva por Diagnóstico: entrega repetida não consome a Cota duas vezes.
create unique index usage_llm_diagnosis_idx on doctor.usage_llm (tenant_id, diagnosis_id) where diagnosis_id is not null;

-- Eventos ingeridos chegam como deltas, só com insert (sem disputa de linha entre as
-- transações de ingestão); o job de 10 min (`rollup_usage`) os soma em usage_records.
create table doctor.usage_deltas (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  resource text not null check (resource in ('events_ingested')),
  period_start date not null,
  amount bigint not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table doctor.usage_deltas is 'Consumo ainda não somado em usage_records (só insert).';
create index usage_deltas_tenant_idx on doctor.usage_deltas (tenant_id, resource, period_start);
alter table doctor.usage_deltas enable row level security;
revoke all on doctor.usage_deltas from anon, authenticated;

-- Avisos de 80% e 100%: um por recurso, período e patamar.
create table doctor.usage_alerts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  resource text not null,
  period_start date not null,
  threshold integer not null check (threshold in (80, 100)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, resource, period_start, threshold)
);
comment on table doctor.usage_alerts is 'Avisos de Cota já enviados (80% e 100%).';

create trigger usage_records_set_updated_at before update on doctor.usage_records
for each row execute function doctor.set_updated_at();
create trigger usage_llm_set_updated_at before update on doctor.usage_llm
for each row execute function doctor.set_updated_at();
create trigger usage_alerts_set_updated_at before update on doctor.usage_alerts
for each row execute function doctor.set_updated_at();

alter table doctor.usage_records enable row level security;
alter table doctor.usage_llm enable row level security;
alter table doctor.usage_alerts enable row level security;
revoke all on doctor.usage_records, doctor.usage_llm, doctor.usage_alerts from anon, authenticated;
grant select on doctor.usage_records, doctor.usage_llm, doctor.usage_alerts to authenticated;
create policy usage_records_select on doctor.usage_records
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy usage_llm_select on doctor.usage_llm
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy usage_alerts_select on doctor.usage_alerts
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));

create function doctor.usage_period(resource text, at timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select case when resource = 'storage_bytes' then date '1970-01-01'
    else date_trunc('month', at at time zone 'UTC')::date end
$$;
revoke all on function doctor.usage_period(text, timestamptz) from public, anon;
grant execute on function doctor.usage_period(text, timestamptz) to authenticated, service_role;

create function doctor.plan_limit(tenant uuid, resource text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select l."limit" from doctor.plan_limits l
  join doctor.tenants t on t.plan = l.plan
  where t.id = tenant and l.resource = plan_limit.resource
$$;

-- Consumo atual: contador do período, ou contagem viva para Conectores e membros.
create function doctor.current_usage(tenant uuid, resource text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case resource
    when 'connectors_active' then
      (select count(*) from doctor.connectors c where c.tenant_id = tenant and c.status <> 'disabled')
    -- Como a imposição: os convites pendentes contam como membros.
    when 'members' then
      (select count(*) from doctor.memberships m where m.tenant_id = tenant)
      + (select count(*) from doctor.invitations i
         where i.tenant_id = tenant and i.accepted_at is null and i.expires_at > now())
    else coalesce((
      select u.quantity from doctor.usage_records u
      where u.tenant_id = tenant and u.resource = current_usage.resource
        and u.period_start = doctor.usage_period(current_usage.resource)
    ), 0) + coalesce((
      select sum(d.amount) from doctor.usage_deltas d
      where d.tenant_id = tenant and d.resource = current_usage.resource
        and d.period_start = doctor.usage_period(current_usage.resource)
    ), 0)
  end
$$;

-- Cruzou 80% ou 100% entre `before` e `after`: o aviso sai uma vez por patamar e período.
create function doctor.usage_thresholds(tenant uuid, resource text, before bigint, after bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  quota bigint := doctor.plan_limit(tenant, resource);
  threshold integer;
begin
  if quota is null then
    return;
  end if;
  foreach threshold in array array[80, 100] loop
    if after * 100 >= quota * threshold and before * 100 < quota * threshold then
      insert into doctor.usage_alerts (tenant_id, resource, period_start, threshold)
      values (tenant, usage_thresholds.resource, doctor.usage_period(usage_thresholds.resource), threshold)
      on conflict do nothing;
      if found then
        insert into doctor.outbox_messages (tenant_id, topic, payload)
        values (tenant, 'usage.threshold', jsonb_build_object(
          'tenant_id', tenant, 'resource', usage_thresholds.resource, 'threshold', threshold,
          'used', after, 'limit', quota));
      end if;
    end if;
  end loop;
end;
$$;

-- Incremento atômico (`insert … on conflict do update`): 50 workers ao mesmo tempo não perdem
-- unidade.
create function doctor.increment_usage(tenant uuid, resource text, amount bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  total bigint;
begin
  if amount <= 0 then
    return doctor.current_usage(tenant, resource);
  end if;
  insert into doctor.usage_records as u (tenant_id, resource, period_start, quantity)
  values (tenant, increment_usage.resource, doctor.usage_period(increment_usage.resource), amount)
  on conflict on constraint usage_records_tenant_id_resource_period_start_key
  do update set quantity = u.quantity + excluded.quantity
  returning u.quantity into total;
  perform doctor.usage_thresholds(tenant, resource, total - amount, total);
  return total;
end;
$$;

-- Medida absoluta (armazenamento, pelo job diário), com os mesmos avisos.
create function doctor.set_usage(tenant uuid, resource text, value bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  before bigint := doctor.current_usage(tenant, resource);
begin
  insert into doctor.usage_records as u (tenant_id, resource, period_start, quantity)
  values (tenant, set_usage.resource, doctor.usage_period(set_usage.resource), greatest(value, 0))
  on conflict on constraint usage_records_tenant_id_resource_period_start_key
  do update set quantity = excluded.quantity;
  perform doctor.usage_thresholds(tenant, resource, before, greatest(value, 0));
end;
$$;

-- Soma os deltas em usage_records (job de 10 min), com os avisos. `delete … returning` numa
-- instrução só: delta que chega no meio fica para a próxima rodada.
create function doctor.rollup_usage()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  item record;
  rolled integer := 0;
  after bigint;
begin
  for item in
    with taken as (delete from doctor.usage_deltas returning tenant_id, resource, period_start, amount)
    select tenant_id, resource, period_start, sum(amount)::bigint as amount
    from taken group by 1, 2, 3 order by 1, 2, 3
  loop
    insert into doctor.usage_records as u (tenant_id, resource, period_start, quantity)
    values (item.tenant_id, item.resource, item.period_start, item.amount)
    on conflict on constraint usage_records_tenant_id_resource_period_start_key
    do update set quantity = u.quantity + excluded.quantity;
    if item.period_start = doctor.usage_period(item.resource) then
      after := doctor.current_usage(item.tenant_id, item.resource);
      perform doctor.usage_thresholds(item.tenant_id, item.resource, after - item.amount, after);
    end if;
    rolled := rolled + 1;
  end loop;
  return rolled;
end;
$$;

-- Eventos gravados contam no consumo do mês: um trigger por comando, com a tabela de transição,
-- vale para a ingestão, a Importação e os Conectores (o que o `on conflict do nothing` descartou
-- não entra).
create function doctor.count_ingested_events()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into doctor.usage_deltas (tenant_id, resource, period_start, amount)
  select n.tenant_id, 'events_ingested', doctor.usage_period('events_ingested'), count(*)
  from inserted n group by n.tenant_id;
  return null;
end;
$$;
create trigger events_count_usage after insert on doctor.events
referencing new table as inserted
for each statement execute function doctor.count_ingested_events();

-- Ingestão acima da Cota com a tolerância (110%): o lote é recusado (`DR050`, 429 na API). A
-- Importação é recusada quando a Cota já passou da tolerância (o tamanho do arquivo em Eventos
-- só se sabe depois).
create function doctor.ingestion_over_quota(tenant uuid, pending bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select doctor.plan_limit(tenant, 'events_ingested') is not null
    and doctor.current_usage(tenant, 'events_ingested') + pending
      > doctor.plan_limit(tenant, 'events_ingested')
        * (select t.quota_tolerance from doctor.tenants t where t.id = tenant)
$$;
revoke all on function doctor.ingestion_over_quota(uuid, bigint) from public, anon, authenticated;

create function doctor.enforce_batch_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if doctor.ingestion_over_quota(new.tenant_id, new.event_count) then
    raise exception 'Cota de Eventos do mês esgotada' using errcode = 'DR050';
  end if;
  return new;
end;
$$;

create function doctor.enforce_import_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if doctor.ingestion_over_quota(new.tenant_id, 0) then
    raise exception 'Cota de Eventos do mês esgotada' using errcode = 'DR050';
  end if;
  return new;
end;
$$;
create trigger ingestion_batches_quota before insert on doctor.ingestion_batches
for each row execute function doctor.enforce_batch_quota();
create trigger imports_quota before insert on doctor.imports
for each row execute function doctor.enforce_import_quota();

-- Conectores e membros no limite do plano: a criação é bloqueada (`DR051`, 409 na API). O
-- convite pendente conta como membro.
create function doctor.enforce_seat_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  resource text := case when tg_table_name = 'connectors' then 'connectors_active' else 'members' end;
  quota bigint := doctor.plan_limit(new.tenant_id, resource);
  used bigint;
begin
  if tg_table_name = 'memberships' then
    -- No aceite, o convite ainda está pendente: conta só os Vínculos, para ele não ocupar a
    -- vaga duas vezes.
    used := (select count(*) from doctor.memberships m where m.tenant_id = new.tenant_id);
  else
    -- Conectores ativos; ou membros com os convites pendentes (como a Tela 17 mostra).
    used := doctor.current_usage(new.tenant_id, resource);
  end if;
  if quota is not null and used >= quota then
    raise exception 'Limite do plano atingido: %', resource using errcode = 'DR051';
  end if;
  return new;
end;
$$;
create trigger connectors_quota before insert on doctor.connectors
for each row execute function doctor.enforce_seat_quota();
create trigger memberships_quota before insert on doctor.memberships
for each row execute function doctor.enforce_seat_quota();
create trigger invitations_quota before insert on doctor.invitations
for each row execute function doctor.enforce_seat_quota();

-- Cota de IA: o worker reserva uma unidade antes de chamar o LLM, de forma atômica (sem
-- conferir e depois somar), e uma vez por Diagnóstico; os tokens entram ao publicar.
create function doctor.reserve_llm_quota(tenant uuid, diagnosis uuid, provider text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  quota bigint := doctor.plan_limit(tenant, 'diagnoses_llm');
  period date := doctor.usage_period('diagnoses_llm');
  total bigint;
begin
  if exists (select 1 from doctor.usage_llm u where u.tenant_id = tenant and u.diagnosis_id = diagnosis) then
    return true;
  end if;
  insert into doctor.usage_records as u (tenant_id, resource, period_start, quantity)
  values (tenant, 'diagnoses_llm', period, 1)
  on conflict on constraint usage_records_tenant_id_resource_period_start_key
  do update set quantity = u.quantity + 1 where quota is null or u.quantity < quota
  returning u.quantity into total;
  if total is null then
    return false;
  end if;
  insert into doctor.usage_llm (tenant_id, diagnosis_id, provider) values (tenant, diagnosis, provider);
  perform doctor.usage_thresholds(tenant, 'diagnoses_llm', total - 1, total);
  return true;
end;
$$;

-- Para a Tela 17: o uso da Organização ativa, com o limite do plano.
create function doctor.my_usage()
returns table (resource text, period text, used bigint, quota bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select l.resource, l.period, doctor.current_usage(doctor.current_tenant_id(), l.resource), l."limit"
  from doctor.plan_limits l
  join doctor.tenants t on t.plan = l.plan
  where t.id = doctor.current_tenant_id()
  order by array_position(array['events_ingested', 'diagnoses_llm', 'storage_bytes', 'connectors_active', 'members'], l.resource)
$$;

revoke all on function doctor.plan_limit(uuid, text) from public, anon, authenticated;
revoke all on function doctor.current_usage(uuid, text) from public, anon, authenticated;
revoke all on function doctor.increment_usage(uuid, text, bigint) from public, anon, authenticated;
revoke all on function doctor.set_usage(uuid, text, bigint) from public, anon, authenticated;
revoke all on function doctor.count_ingested_events() from public;
revoke all on function doctor.enforce_batch_quota() from public;
revoke all on function doctor.enforce_import_quota() from public;
revoke all on function doctor.enforce_seat_quota() from public;
revoke all on function doctor.reserve_llm_quota(uuid, uuid, text) from public, anon, authenticated;
revoke all on function doctor.usage_thresholds(uuid, text, bigint, bigint) from public, anon, authenticated;
revoke all on function doctor.rollup_usage() from public, anon, authenticated;
revoke all on function doctor.my_usage() from public, anon, service_role;
grant execute on function doctor.plan_limit(uuid, text) to service_role;
grant execute on function doctor.current_usage(uuid, text) to service_role;
grant execute on function doctor.increment_usage(uuid, text, bigint) to service_role;
grant execute on function doctor.set_usage(uuid, text, bigint) to service_role;
grant execute on function doctor.reserve_llm_quota(uuid, uuid, text) to service_role;
grant execute on function doctor.rollup_usage() to service_role;
grant execute on function doctor.my_usage() to authenticated;

-- Destinatários do aviso de Cota: Owner e Admin da Organização, com o nome dela (o worker não lê
-- `auth.users` direto).
create function doctor.quota_recipients(tenant uuid)
returns table (organization text, email text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.name, u.email::text
  from doctor.memberships m
  join auth.users u on u.id = m.user_id
  join public.organizations o on o.id = m.tenant_id
  where m.tenant_id = tenant and m.role in ('owner', 'admin') and u.email is not null
$$;
revoke all on function doctor.quota_recipients(uuid) from public, anon, authenticated;
grant execute on function doctor.quota_recipients(uuid) to service_role;
