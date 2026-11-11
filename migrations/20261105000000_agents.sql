-- Ticket #39: agente local para SAP on-premises (ADR-0015). O agente roda na rede do cliente, só
-- abre conexões de saída e se identifica com um segredo próprio (só o hash fica aqui) e uma
-- chave Ed25519 gerada por ele (a chave pública fica aqui; a privada nunca sai da máquina).
-- Status checado a cada chamada: revogar recusa a próxima requisição.

create table doctor.agents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  status text not null default 'pending' check (status in ('pending', 'active', 'revoked')),
  -- Coletas autorizadas (diretório de exportações, tabelas RFC da allowlist), validadas pela API.
  config jsonb not null default '{"collections": []}' check (jsonb_typeof(config) = 'object'),
  config_version integer not null default 1 check (config_version > 0),
  -- Registro: token de uso único, válido por 24 h.
  registration_token_hash text check (registration_token_hash ~ '^[0-9a-f]{64}$'),
  registration_expires_at timestamptz,
  -- Depois do registro: o segredo do agente e a chave pública que assina as requisições.
  secret_hash text unique check (secret_hash ~ '^[0-9a-f]{64}$'),
  public_key text check (public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  cert_fingerprint text check (cert_fingerprint ~ '^[0-9a-f]{64}$'),
  version text check (char_length(version) <= 40),
  last_seen_at timestamptz,
  registered_at timestamptz,
  revoked_at timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (registration_token_hash),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  check (status <> 'active' or (secret_hash is not null and public_key is not null)),
  check (status <> 'pending' or registration_token_hash is not null)
);
comment on table doctor.agents is 'Agente local na rede do cliente (SAP on-premises), só de saída.';
create index agents_tenant_idx on doctor.agents (tenant_id, created_at desc);

create trigger agents_set_updated_at
before update on doctor.agents
for each row execute function doctor.set_updated_at();

-- Lotes do agente entram pelo mesmo caminho da API e dos Conectores.
alter table doctor.ingestion_batches add column agent_id uuid;
alter table doctor.ingestion_batches
  add constraint ingestion_batches_agent_fk
  foreign key (tenant_id, agent_id) references doctor.agents (tenant_id, id) on delete cascade;
create index ingestion_batches_agent_idx on doctor.ingestion_batches (tenant_id, agent_id)
  where agent_id is not null;
alter table doctor.ingestion_batches drop constraint ingestion_batches_one_source;
alter table doctor.ingestion_batches
  add constraint ingestion_batches_one_source check (num_nonnulls(token_id, connector_id, agent_id) = 1);

alter table doctor.agents enable row level security;
revoke all on doctor.agents from anon, authenticated;
-- Sem os hashes: a tela vê status, versão e quando o agente falou pela última vez.
grant select (
  id, tenant_id, integration_id, name, status, config, config_version, cert_fingerprint, version,
  last_seen_at, registered_at, revoked_at, registration_expires_at, created_by, created_at, updated_at
) on doctor.agents to authenticated;

create policy agents_select on doctor.agents
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- Gestão: Owner ou Admin com MFA (como os Conectores e os tokens de ingestão).
create function doctor.create_agent(name text, integration_id uuid, token_hash text, config jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  created uuid;
begin
  perform doctor.require_manager();
  perform 1 from doctor.integrations i
  where i.tenant_id = tenant and i.id = create_agent.integration_id and i.archived_at is null;
  if not found then
    raise no_data_found using message = 'Integração não encontrada';
  end if;
  insert into doctor.agents (tenant_id, integration_id, name, config, registration_token_hash,
    registration_expires_at, created_by)
  values (tenant, create_agent.integration_id, btrim(create_agent.name), create_agent.config,
    token_hash, now() + interval '24 hours', auth.uid())
  returning id into created;
  perform doctor.write_audit(tenant, 'agent.created', 'agent', created::text, null,
    jsonb_build_object('name', btrim(create_agent.name), 'integration_id', create_agent.integration_id));
  return created;
end;
$$;

create function doctor.update_agent_config(target uuid, config jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  next_version integer;
begin
  perform doctor.require_manager();
  update doctor.agents a set config = update_agent_config.config, config_version = a.config_version + 1
  where a.tenant_id = tenant and a.id = target and a.status <> 'revoked'
  returning a.config_version into next_version;
  if next_version is null then
    raise no_data_found using message = 'Agente não encontrado';
  end if;
  perform doctor.write_audit(tenant, 'agent.config_updated', 'agent', target::text, null,
    jsonb_build_object('config_version', next_version));
  return next_version;
end;
$$;

-- Revogar vale na hora: as funções do agente checam o status a cada chamada.
create function doctor.revoke_agent(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  update doctor.agents a set status = 'revoked', revoked_at = now(), secret_hash = null,
    registration_token_hash = null, registration_expires_at = null
  where a.tenant_id = tenant and a.id = target and a.status <> 'revoked';
  if not found then
    raise no_data_found using message = 'Agente não encontrado';
  end if;
  perform doctor.write_audit(tenant, 'agent.revoked', 'agent', target::text, null, null);
end;
$$;

-- Rotação: o segredo e a chave atuais deixam de valer já; o agente se registra de novo com o
-- token novo e uma chave nova (mesmo id, mesma Integração e config).
create function doctor.rotate_agent(target uuid, token_hash text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  update doctor.agents a set status = 'pending', secret_hash = null, public_key = null,
    cert_fingerprint = null, registration_token_hash = rotate_agent.token_hash,
    registration_expires_at = now() + interval '24 hours'
  where a.tenant_id = tenant and a.id = target and a.status <> 'revoked';
  if not found then
    raise no_data_found using message = 'Agente não encontrado';
  end if;
  perform doctor.write_audit(tenant, 'agent.rotated', 'agent', target::text, null, null);
end;
$$;

-- Chamadas do próprio agente (sem sessão, como `anon`): cada uma prova a posse do segredo pelo
-- hash e confere o status. A API, antes, confere a assinatura Ed25519 com a chave pública.
create function doctor.register_agent(token_hash text, secret_hash text, public_key text, fingerprint text, version text)
returns table (agent_id uuid, tenant_id uuid, integration_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_agent doctor.agents;
begin
  select * into found_agent from doctor.agents a
  where a.registration_token_hash = register_agent.token_hash and a.status = 'pending'
    and a.registration_expires_at > now()
  for update;
  if found_agent.id is null then
    raise exception 'token de registro inválido ou vencido' using errcode = 'DR070';
  end if;
  update doctor.agents a set status = 'active', secret_hash = register_agent.secret_hash,
    public_key = register_agent.public_key, cert_fingerprint = fingerprint,
    version = left(register_agent.version, 40), registered_at = now(), last_seen_at = now(),
    registration_token_hash = null, registration_expires_at = null
  where a.id = found_agent.id;
  perform doctor.write_audit(found_agent.tenant_id, 'agent.registered', 'agent', found_agent.id::text,
    null, jsonb_build_object('fingerprint', fingerprint, 'version', left(register_agent.version, 40)));
  return query select found_agent.id, found_agent.tenant_id, found_agent.integration_id;
end;
$$;

create function doctor.resolve_agent(secret_hash text)
returns table (agent_id uuid, tenant_id uuid, integration_id uuid, public_key text, config jsonb,
  config_version integer)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.tenant_id, a.integration_id, a.public_key, a.config, a.config_version
  from doctor.agents a
  join doctor.tenants t on t.id = a.tenant_id and t.status = 'active'
  join doctor.integrations i on i.tenant_id = a.tenant_id and i.id = a.integration_id
    and i.archived_at is null
  where a.secret_hash = resolve_agent.secret_hash and a.status = 'active'
$$;

create function doctor.agent_seen(secret_hash text, version text)
returns void
language sql
security definer
set search_path = ''
as $$
  update doctor.agents a set last_seen_at = now(), version = left(agent_seen.version, 40)
  where a.secret_hash = agent_seen.secret_hash and a.status = 'active'
$$;

create function doctor.accept_agent_batch(secret_hash text, events jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_agent record;
  batch_id uuid;
begin
  select * into found_agent from doctor.resolve_agent(accept_agent_batch.secret_hash);
  if found_agent.agent_id is null then
    raise exception 'agente inválido ou revogado' using errcode = 'DR071';
  end if;
  insert into doctor.ingestion_batches (tenant_id, integration_id, agent_id, events, event_count)
  values (found_agent.tenant_id, found_agent.integration_id, found_agent.agent_id, events,
    jsonb_array_length(events))
  returning id into batch_id;
  update doctor.agents set last_seen_at = now() where id = found_agent.agent_id;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (found_agent.tenant_id, 'ingestion.raw', jsonb_build_object('batch_id', batch_id));
  return batch_id;
end;
$$;

revoke all on function doctor.create_agent(text, uuid, text, jsonb) from public, anon, service_role;
revoke all on function doctor.update_agent_config(uuid, jsonb) from public, anon, service_role;
revoke all on function doctor.revoke_agent(uuid) from public, anon, service_role;
revoke all on function doctor.rotate_agent(uuid, text) from public, anon, service_role;
revoke all on function doctor.register_agent(text, text, text, text, text) from public, service_role;
revoke all on function doctor.resolve_agent(text) from public, service_role;
revoke all on function doctor.agent_seen(text, text) from public, service_role;
revoke all on function doctor.accept_agent_batch(text, jsonb) from public, service_role;
grant execute on function doctor.create_agent(text, uuid, text, jsonb) to authenticated;
grant execute on function doctor.update_agent_config(uuid, jsonb) to authenticated;
grant execute on function doctor.revoke_agent(uuid) to authenticated;
grant execute on function doctor.rotate_agent(uuid, text) to authenticated;
grant execute on function doctor.register_agent(text, text, text, text, text) to anon;
grant execute on function doctor.resolve_agent(text) to anon;
grant execute on function doctor.agent_seen(text, text) to anon;
grant execute on function doctor.accept_agent_batch(text, jsonb) to anon;
