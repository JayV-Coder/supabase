-- Ticket #40: correlação entre sistemas. Um Mapa de identificadores diz, por Integração, onde
-- cada sistema (Salesforce, middleware GCP, SAP) guarda a mesma chave de negócio e como
-- normalizá-la (prefixo, zeros à esquerda, caixa). O worker de correlação calcula as chaves de
-- cada Evento pendente e une, numa Execução, os Eventos que compartilham uma chave dentro da
-- janela do mapa, mesmo com ids fortes diferentes em cada sistema.

create table doctor.correlation_mappings (
  id uuid primary key default gen_random_uuid(),
  -- Sem grant de escrita na coluna: o tenant sai sempre da claim do JWT.
  tenant_id uuid not null default doctor.current_tenant_id() references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  -- [{system, field, transforms}], validado pela API (aid_api.correlation.mappings).
  keys jsonb not null check (jsonb_typeof(keys) = 'array' and jsonb_array_length(keys) between 1 and 6),
  window_minutes integer not null default 60 check (window_minutes between 1 and 1440),
  -- Divergência (INT-008): a chave vista na origem precisa aparecer no destino da Integração.
  reconcile boolean not null default false,
  -- Enriquecimento sob demanda (consulta de leitura no destino), validado pela API.
  lookup jsonb check (lookup is null or jsonb_typeof(lookup) = 'object'),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, integration_id, name),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id) on delete cascade
);
comment on table doctor.correlation_mappings is 'Mapa de identificadores entre sistemas de uma Integração.';

create trigger correlation_mappings_set_updated_at
before update on doctor.correlation_mappings
for each row execute function doctor.set_updated_at();

alter table doctor.correlation_mappings enable row level security;
revoke all on doctor.correlation_mappings from anon, authenticated;
grant select, delete on doctor.correlation_mappings to authenticated;
grant insert (integration_id, name, keys, window_minutes, reconcile, lookup)
  on doctor.correlation_mappings to authenticated;
grant update (name, keys, window_minutes, reconcile, lookup) on doctor.correlation_mappings to authenticated;

create policy correlation_mappings_select on doctor.correlation_mappings
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy correlation_mappings_insert on doctor.correlation_mappings
for insert to authenticated
with check (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

create policy correlation_mappings_update on doctor.correlation_mappings
for update to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()))
with check (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

create policy correlation_mappings_delete on doctor.correlation_mappings
for delete to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

-- Chaves entre sistemas de cada Evento: `<id do mapa>:<valor normalizado>`. O id do mapa é único
-- e da Organização, então o índice GIN (que não aceita `tenant_id` na frente sem extensão) não
-- mistura Organizações; a consulta filtra por `tenant_id` também.
alter table doctor.events add column cross_keys text[];
create index events_cross_keys_idx on doctor.events using gin (cross_keys)
  where cross_keys is not null;

alter table doctor.events drop constraint events_correlated_by_check;
alter table doctor.events
  add constraint events_correlated_by_check check (
    correlated_by in ('execution_id', 'trace_id', 'cross_system', 'business_reference', 'temporal_proximity')
  );
