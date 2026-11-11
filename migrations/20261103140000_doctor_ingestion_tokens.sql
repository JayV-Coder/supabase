-- Ticket #12 (parte 3): tokens de ingestão para sistemas externos e lotes recebidos pela API.
-- O sistema externo não tem sessão: a API chama as funções abaixo como `anon`, e o tenant sai do
-- token, nunca do payload. Nada de service_role numa rota da API (ADR-0004).

create table doctor.ingestion_tokens (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  integration_id uuid not null,
  -- sha256 do token `aid_ing_…`; o valor em claro só aparece uma vez, na criação.
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  -- Começo do token, para o Usuário reconhecer qual é sem guardar o segredo.
  prefix text not null check (char_length(prefix) between 8 and 16),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id)
);
comment on table doctor.ingestion_tokens is 'Token de ingestão (aid_ing_…) de um sistema externo, preso a uma Integração.';

create index ingestion_tokens_tenant_idx on doctor.ingestion_tokens (tenant_id, created_at desc);

-- Lote aceito pela API, à espera do worker de ingestão. Fica no banco (até 1 MB), e não no
-- Storage: a API, sem sessão de Usuário, só gravaria no bucket com a chave de serviço.
create table doctor.ingestion_batches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  token_id uuid not null,
  events jsonb not null check (jsonb_typeof(events) = 'array'),
  event_count integer not null,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  -- Erro permanente no worker: o lote fica registrado em vez de sumir na DLQ.
  failed_at timestamptz,
  error text check (char_length(error) <= 500),
  -- Eventos descartados na revalidação do worker (fora do contrato depois da Sanitização).
  skipped integer not null default 0,
  -- Ainda não sanitizado: vence como o Log bruto, e a retenção (ticket #29) apaga.
  expires_at timestamptz not null default now() + interval '7 days',
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  foreign key (tenant_id, token_id) references doctor.ingestion_tokens (tenant_id, id)
);
comment on table doctor.ingestion_batches is 'Lote de Eventos recebido por POST /ingestion/events, antes do worker.';

create index ingestion_batches_expires_idx on doctor.ingestion_batches (tenant_id, expires_at);

alter table doctor.ingestion_tokens enable row level security;
alter table doctor.ingestion_batches enable row level security;
revoke all on doctor.ingestion_tokens, doctor.ingestion_batches from anon, authenticated;
-- Sem o hash: só o que a tela precisa.
grant select (id, tenant_id, name, integration_id, prefix, created_at, last_used_at, revoked_at)
  on doctor.ingestion_tokens to authenticated;

create policy ingestion_tokens_select on doctor.ingestion_tokens
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- security definer: Owner ou Admin com MFA (Papel da tabela) cria token para Integração ativa.
create function doctor.create_ingestion_token(name text, integration_id uuid, token_hash text, prefix text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  new_id uuid;
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  if not exists (
    select 1 from doctor.integrations i
    where i.id = create_ingestion_token.integration_id and i.tenant_id = tenant and i.archived_at is null
  ) then
    raise no_data_found using message = 'Integração não encontrada';
  end if;
  insert into doctor.ingestion_tokens (tenant_id, name, integration_id, token_hash, prefix)
  values (tenant, create_ingestion_token.name, create_ingestion_token.integration_id,
    create_ingestion_token.token_hash, create_ingestion_token.prefix)
  returning id into new_id;
  return new_id;
end;
$$;

create function doctor.revoke_ingestion_token(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  update doctor.ingestion_tokens set revoked_at = coalesce(revoked_at, now())
  where id = target and tenant_id = doctor.current_tenant_id();
  if not found then
    raise no_data_found using message = 'token não encontrado';
  end if;
end;
$$;

-- security definer: identifica o sistema externo. Token desconhecido, revogado, de Integração
-- arquivada ou de Organização inativa respondem igual (DR006), sem dizer qual foi o caso.
create function doctor.resolve_ingestion_token(token_hash text)
returns table (token_id uuid, tenant_id uuid, integration_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select t.id, t.tenant_id, t.integration_id
  from doctor.ingestion_tokens t
  join doctor.integrations i on i.tenant_id = t.tenant_id and i.id = t.integration_id
  join doctor.tenants o on o.id = t.tenant_id
  where t.token_hash = resolve_ingestion_token.token_hash
    and t.revoked_at is null and i.archived_at is null and o.status = 'active';
  if not found then
    raise exception 'token de ingestão inválido' using errcode = 'DR006';
  end if;
end;
$$;

-- security definer: grava o lote já validado pela API e enfileira o processamento, numa transação.
create function doctor.accept_ingestion_batch(token_hash text, events jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  token record;
  batch_id uuid;
begin
  select * into token from doctor.resolve_ingestion_token(accept_ingestion_batch.token_hash);
  insert into doctor.ingestion_batches (tenant_id, integration_id, token_id, events, event_count)
  values (token.tenant_id, token.integration_id, token.token_id, events, jsonb_array_length(events))
  returning id into batch_id;
  update doctor.ingestion_tokens set last_used_at = now() where id = token.token_id;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (token.tenant_id, 'ingestion.raw', jsonb_build_object('batch_id', batch_id));
  return batch_id;
end;
$$;

revoke all on function doctor.create_ingestion_token(text, uuid, text, text) from public, service_role;
revoke all on function doctor.revoke_ingestion_token(uuid) from public, service_role;
revoke all on function doctor.resolve_ingestion_token(text) from public;
revoke all on function doctor.accept_ingestion_batch(text, jsonb) from public;
grant execute on function doctor.create_ingestion_token(text, uuid, text, text) to authenticated;
grant execute on function doctor.revoke_ingestion_token(uuid) to authenticated;
-- `anon` passa a enxergar o schema. As funções do Doctor revogam `public` uma a uma; a única que
-- ainda não revogava (helper puro do caminho no Storage) passa a revogar. O pgTAP confere que anon
-- executa só as duas funções do token, então uma função nova esquecida quebra o CI.
revoke all on function doctor.import_storage_path(uuid, uuid, text) from public;
grant usage on schema doctor to anon;
grant execute on function doctor.resolve_ingestion_token(text) to anon, authenticated;
grant execute on function doctor.accept_ingestion_batch(text, jsonb) to anon, authenticated;
