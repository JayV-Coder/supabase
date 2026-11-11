-- Ticket #46: modelo local no ambiente do cliente (ADR-0019). O perfil `local` manda o prompt
-- (Evidências já sanitizadas) a um servidor compatível com a API da OpenAI (vLLM, TGI) dentro
-- da rede do cliente, pelo agente local (#39, só de saída) ou por um endpoint privado (Private
-- Service Connect). Só a resposta estruturada volta. Indisponível, o Diagnóstico sai em
-- `rules_only`: nunca vai a um provedor em nuvem.

alter table doctor.tenants drop constraint tenants_ai_profile_check;
alter table doctor.tenants add constraint tenants_ai_profile_check
  check (ai_profile in ('standard', 'br_region', 'dedicated', 'local'));
alter table doctor.tenants drop constraint tenants_llm_provider_check;
alter table doctor.tenants add constraint tenants_llm_provider_check
  check (llm_provider in ('anthropic', 'vertex', 'vertex_dedicated', 'local'));
alter table doctor.tenants drop constraint tenants_ai_profile_provider_check;
alter table doctor.tenants add constraint tenants_ai_profile_provider_check check (
  (ai_profile = 'standard' and llm_provider = 'anthropic')
  or (ai_profile = 'br_region' and llm_provider = 'vertex')
  or (ai_profile = 'dedicated' and llm_provider = 'vertex_dedicated')
  or (ai_profile = 'local' and llm_provider = 'local')
);

create or replace function doctor.sync_ai_profile()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.ai_profile = 'standard' and new.llm_provider = 'vertex' then
    new.ai_profile := 'br_region';
  elsif tg_op = 'UPDATE' and new.ai_profile is not distinct from old.ai_profile
      and new.llm_provider is distinct from old.llm_provider then
    new.ai_profile := case new.llm_provider
      when 'anthropic' then 'standard' when 'vertex' then 'br_region'
      when 'vertex_dedicated' then 'dedicated' when 'local' then 'local'
      else new.ai_profile end;
  elsif tg_op = 'INSERT' or new.ai_profile is distinct from old.ai_profile then
    new.llm_provider := case new.ai_profile
      when 'standard' then case when tg_op = 'UPDATE' or new.llm_provider in ('vertex', 'vertex_dedicated', 'local')
        then 'anthropic' else new.llm_provider end
      when 'br_region' then 'vertex' when 'dedicated' then 'vertex_dedicated' else 'local' end;
  end if;
  if new.ai_profile <> 'dedicated' then
    new.ai_project := null;
  end if;
  return new;
end;
$$;

-- Onde está o modelo local de cada Organização (a operação da plataforma configura).
create table doctor.local_ai_settings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  transport text not null check (transport in ('agent', 'private_endpoint')),
  -- `agent`: o agente que leva o prompt ao servidor da rede do cliente.
  agent_id uuid,
  -- `private_endpoint`: o endereço privado (Private Service Connect) do servidor do cliente.
  endpoint_url text check (endpoint_url ~ '^https://[^/@\s]+(/[^\s]*)?$' and char_length(endpoint_url) <= 300),
  model text not null check (char_length(btrim(model)) between 1 and 120),
  timeout_seconds integer not null default 120 check (timeout_seconds between 10 and 600),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  -- Uma configuração por Organização.
  unique (tenant_id),
  foreign key (tenant_id, agent_id) references doctor.agents (tenant_id, id),
  check ((transport = 'agent') = (agent_id is not null)),
  check ((transport = 'private_endpoint') = (endpoint_url is not null))
);
comment on table doctor.local_ai_settings is 'Modelo local da Organização: pelo agente ou por endpoint privado (ADR-0019).';

create trigger local_ai_settings_set_updated_at
before update on doctor.local_ai_settings
for each row execute function doctor.set_updated_at();

alter table doctor.local_ai_settings enable row level security;
revoke all on doctor.local_ai_settings from anon, authenticated;
grant select (id, tenant_id, transport, agent_id, model, timeout_seconds, created_at, updated_at)
  on doctor.local_ai_settings to authenticated;
create policy local_ai_settings_select on doctor.local_ai_settings
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- Pedidos ao modelo local pelo agente: o worker põe o pedido, o agente o busca por long-poll e
-- devolve a resposta, e o worker apaga a linha ao ler. O pedido só leva o prompt já sanitizado.
create table doctor.local_llm_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  agent_id uuid not null,
  status text not null default 'queued' check (status in ('queued', 'claimed', 'done', 'failed')),
  request jsonb not null check (jsonb_typeof(request) = 'object'),
  response jsonb,
  error text check (char_length(error) <= 500),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, agent_id) references doctor.agents (tenant_id, id) on delete cascade
);
comment on table doctor.local_llm_requests is 'Fila curta de pedidos ao modelo local pelo agente; a linha sai ao ser lida.';
create index local_llm_requests_queue_idx on doctor.local_llm_requests (tenant_id, agent_id, created_at)
  where status = 'queued';

create trigger local_llm_requests_set_updated_at
before update on doctor.local_llm_requests
for each row execute function doctor.set_updated_at();
alter table doctor.local_llm_requests enable row level security;
revoke all on doctor.local_llm_requests from anon, authenticated;
grant select, insert, update, delete on doctor.local_llm_requests to service_role;

-- Liga o modo local (só a operação da plataforma: depende do servidor no cliente).
create function doctor.set_local_ai(
  tenant uuid, transport text, agent uuid, endpoint_url text, model text, timeout_seconds integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous text;
begin
  select t.ai_profile into previous from doctor.tenants t where t.id = tenant for update;
  if previous is null then
    raise no_data_found using message = 'Organização não encontrada';
  end if;
  insert into doctor.local_ai_settings (tenant_id, transport, agent_id, endpoint_url, model, timeout_seconds)
  values (tenant, set_local_ai.transport, agent, set_local_ai.endpoint_url, set_local_ai.model,
    coalesce(set_local_ai.timeout_seconds, 120))
  on conflict (tenant_id) do update set transport = excluded.transport, agent_id = excluded.agent_id,
    endpoint_url = excluded.endpoint_url, model = excluded.model,
    timeout_seconds = excluded.timeout_seconds;
  update doctor.tenants t set ai_profile = 'local' where t.id = tenant;
  perform doctor.write_audit(tenant, 'org.ai_profile_changed', 'org', tenant::text,
    jsonb_build_object('ai_profile', previous),
    jsonb_build_object('ai_profile', 'local', 'transport', set_local_ai.transport));
end;
$$;

-- O agente busca o próximo pedido da sua Organização (como `anon`, pelo hash do segredo). O
-- prazo vem junto: é o mesmo que o worker espera (uma fonte só, `local_ai_settings`).
create function doctor.claim_local_llm(secret_hash text)
returns table (id uuid, request jsonb, timeout_seconds integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_agent record;
begin
  select * into found_agent from doctor.resolve_agent(claim_local_llm.secret_hash);
  if found_agent.agent_id is null then
    raise exception 'agente inválido ou revogado' using errcode = 'DR071';
  end if;
  return query
  with claimed as (
    update doctor.local_llm_requests r set status = 'claimed', claimed_at = now()
    where r.id = (
      select q.id from doctor.local_llm_requests q
      where q.tenant_id = found_agent.tenant_id and q.agent_id = found_agent.agent_id
        and q.status = 'queued'
      order by q.created_at limit 1 for update skip locked
    )
    returning r.id, r.request, r.tenant_id
  )
  select c.id, c.request, coalesce(s.timeout_seconds, 120)
  from claimed c left join doctor.local_ai_settings s on s.tenant_id = c.tenant_id;
end;
$$;

-- A resposta do modelo local (ou o erro): só para pedido deste agente ainda em aberto.
create function doctor.finish_local_llm(secret_hash text, request_id uuid, response jsonb, error text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_agent record;
begin
  select * into found_agent from doctor.resolve_agent(finish_local_llm.secret_hash);
  if found_agent.agent_id is null then
    raise exception 'agente inválido ou revogado' using errcode = 'DR071';
  end if;
  update doctor.local_llm_requests r
  set status = case when finish_local_llm.error is null then 'done' else 'failed' end,
    response = finish_local_llm.response, error = left(finish_local_llm.error, 500),
    completed_at = now(), request = '{}'
  where r.id = finish_local_llm.request_id and r.agent_id = found_agent.agent_id
    and r.tenant_id = found_agent.tenant_id and r.status = 'claimed';
  return found;
end;
$$;

revoke all on function doctor.set_local_ai(uuid, text, uuid, text, text, integer) from public, anon, authenticated;
revoke all on function doctor.claim_local_llm(text) from public, service_role;
revoke all on function doctor.finish_local_llm(text, uuid, jsonb, text) from public, service_role;
grant execute on function doctor.set_local_ai(uuid, text, uuid, text, text, integer) to service_role;
grant execute on function doctor.claim_local_llm(text) to anon;
grant execute on function doctor.finish_local_llm(text, uuid, jsonb, text) to anon;
