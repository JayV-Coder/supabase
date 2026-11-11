-- Ticket #14: Conectores, Sincronizações e credenciais no Vault (ADR-0006).
-- Diferenças do ticket, pelo projeto compartilhado com o jayv-coder (ADR-0009):
-- * a credencial é lida só pela service_role (o worker de conectores), sem criar um papel novo no
--   cluster compartilhado;
-- * o agendamento é do Cloud Scheduler (como o relay), e não do pg_cron, que é do jayv-coder.

-- Ponto de chamada da Trilha de auditoria: o ticket #28 cria audit_logs e implementa esta função.
-- Até lá, as chamadas já ficam no lugar certo.
create function doctor.record_audit(tenant uuid, action text, target text)
returns void
language sql
set search_path = ''
as $$
  select
$$;
revoke all on function doctor.record_audit(uuid, text, text) from public;

create table doctor.connectors (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  provider text not null check (provider in ('fake', 'gcp', 'salesforce', 'sap')),
  name text not null check (char_length(btrim(name)) between 2 and 80),
  config jsonb not null default '{}' check (jsonb_typeof(config) = 'object'),
  -- Id do segredo no Vault; a credencial nunca fica em coluna (ADR-0006).
  secret_id uuid,
  status text not null default 'active' check (status in ('active', 'paused', 'failing', 'disabled')),
  consecutive_failures integer not null default 0,
  checkpoint jsonb,
  sync_interval_seconds integer not null default 300 check (sync_interval_seconds between 60 and 86400),
  last_sync_at timestamptz,
  last_error text check (char_length(last_error) <= 500),
  next_run_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id)
);
comment on table doctor.connectors is 'Conector: coleta autenticada de um provedor para uma Integração.';

-- Exceção à convenção (índice sem tenant_id na frente): o agendador é job de plataforma e busca
-- os vencidos de todas as Organizações, em ordem de vencimento.
create index connectors_due_idx on doctor.connectors (next_run_at) where status in ('active', 'failing');
create index connectors_tenant_idx on doctor.connectors (tenant_id, created_at desc);

create trigger connectors_set_updated_at
before update on doctor.connectors
for each row execute function doctor.set_updated_at();

create table doctor.connector_syncs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  connector_id uuid not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'succeeded', 'failed')),
  checkpoint_from jsonb,
  checkpoint_to jsonb,
  records integer not null default 0,
  error text check (char_length(error) <= 500),
  unique (tenant_id, id),
  foreign key (tenant_id, connector_id) references doctor.connectors (tenant_id, id) on delete cascade
);
comment on table doctor.connector_syncs is 'Sincronização: uma execução de coleta de um Conector.';

create index connector_syncs_connector_idx on doctor.connector_syncs (tenant_id, connector_id, started_at desc);

-- Lotes de Conector entram pelo mesmo caminho dos lotes da API (ticket #12).
alter table doctor.ingestion_batches alter column token_id drop not null;
alter table doctor.ingestion_batches add column connector_id uuid;
-- Lote é transitório (vence em 7 dias): sai junto com o Conector.
alter table doctor.ingestion_batches
  add constraint ingestion_batches_connector_fk
  foreign key (tenant_id, connector_id) references doctor.connectors (tenant_id, id) on delete cascade;
create index ingestion_batches_connector_idx on doctor.ingestion_batches (tenant_id, connector_id)
  where connector_id is not null;
alter table doctor.ingestion_batches
  add constraint ingestion_batches_one_source check (num_nonnulls(token_id, connector_id) = 1);

alter table doctor.connectors enable row level security;
alter table doctor.connector_syncs enable row level security;
revoke all on doctor.connectors, doctor.connector_syncs from anon, authenticated;
-- Sem secret_id: a tela não precisa nem do id do segredo.
grant select (
  id, tenant_id, integration_id, provider, name, config, status, consecutive_failures,
  sync_interval_seconds, last_sync_at, last_error, next_run_at, created_at, updated_at
) on doctor.connectors to authenticated;
grant select on doctor.connector_syncs to authenticated;

create policy connectors_select on doctor.connectors
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy connector_syncs_select on doctor.connector_syncs
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- security definer: Owner ou Admin com MFA cria o Conector e guarda a credencial no Vault, numa
-- transação. O segredo tem nome com prefixo do Doctor: o Vault é do projeto inteiro.
create function doctor.create_connector(
  integration_id uuid, provider text, name text, config jsonb, secret text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  new_id uuid := gen_random_uuid();
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  if not exists (
    select 1 from doctor.integrations i
    where i.id = create_connector.integration_id and i.tenant_id = tenant and i.archived_at is null
  ) then
    raise no_data_found using message = 'Integração não encontrada';
  end if;
  insert into doctor.connectors (id, tenant_id, integration_id, provider, name, config, secret_id)
  values (
    new_id, tenant, create_connector.integration_id, create_connector.provider,
    create_connector.name, create_connector.config,
    vault.create_secret(create_connector.secret, 'doctor/connector/' || new_id, 'Credencial de Conector do Doctor')
  );
  perform doctor.record_audit(tenant, 'connector.create', new_id::text);
  return new_id;
end;
$$;

create function doctor.put_connector_secret(target uuid, secret text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current_secret uuid;
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  select c.secret_id into current_secret from doctor.connectors c
  where c.id = target and c.tenant_id = tenant for update;
  if not found then
    raise no_data_found using message = 'Conector não encontrado';
  end if;
  if current_secret is null then
    update doctor.connectors
    set secret_id = vault.create_secret(secret, 'doctor/connector/' || target, 'Credencial de Conector do Doctor')
    where id = target;
  else
    perform vault.update_secret(current_secret, secret);
  end if;
  -- Credencial nova: o Conector pausado por erro de autenticação volta a rodar já.
  update doctor.connectors
  set consecutive_failures = 0, last_error = null, next_run_at = now(),
      status = case when status = 'paused' then 'active' else status end
  where id = target;
  perform doctor.record_audit(tenant, 'connector.secret.update', target::text);
end;
$$;

-- security definer: só a plataforma (worker de conectores, service_role) lê a credencial, e cada
-- leitura passa pela Trilha de auditoria.
create function doctor.get_connector_secret(target uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid;
  value text;
begin
  select c.tenant_id, s.decrypted_secret into tenant, value
  from doctor.connectors c join vault.decrypted_secrets s on s.id = c.secret_id
  where c.id = target;
  if tenant is null then
    raise no_data_found using message = 'Conector sem credencial';
  end if;
  perform doctor.record_audit(tenant, 'connector.secret.read', target::text);
  return value;
end;
$$;

revoke all on function doctor.create_connector(uuid, text, text, jsonb, text) from public, service_role;
revoke all on function doctor.put_connector_secret(uuid, text) from public, service_role;
revoke all on function doctor.get_connector_secret(uuid) from public, anon, authenticated;
grant execute on function doctor.create_connector(uuid, text, text, jsonb, text) to authenticated;
grant execute on function doctor.put_connector_secret(uuid, text) to authenticated;
grant execute on function doctor.get_connector_secret(uuid) to service_role;
