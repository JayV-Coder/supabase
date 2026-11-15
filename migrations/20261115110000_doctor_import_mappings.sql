-- Ticket #11: mapeamento de colunas da Importação, salvo por Integração. A detecção pelo nome da
-- coluna (`timestamp`, `data_hora`, `msgty`…) continua valendo para o que não estiver mapeado; o
-- mapeamento resolve exportações com nomes próprios (`Data/Hora`, `Texto da mensagem`).

create table doctor.import_mappings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  -- campo do Contrato de evento → nome da coluna no arquivo
  columns jsonb not null default '{}' check (jsonb_typeof(columns) = 'object'),
  updated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, integration_id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id) on delete cascade
);
comment on table doctor.import_mappings is 'Coluna do arquivo para cada campo do Contrato de evento, por Integração (#11).';

create trigger import_mappings_set_updated_at
before update on doctor.import_mappings
for each row execute function doctor.set_updated_at();

alter table doctor.import_mappings enable row level security;
revoke all on doctor.import_mappings from anon, authenticated;
grant select (id, tenant_id, integration_id, columns, updated_at) on doctor.import_mappings to authenticated;
create policy import_mappings_select on doctor.import_mappings
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create function doctor.set_import_mapping(integration uuid, columns jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  item record;
begin
  -- Quem importa (o Papel lido da tabela, não do JWT).
  if tenant is null or not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'Papel não importa logs';
  end if;
  if not exists (
      select 1 from doctor.integrations i
      where i.id = integration and i.tenant_id = tenant and i.archived_at is null) then
    raise no_data_found using message = 'Integração não encontrada';
  end if;
  if jsonb_typeof(columns) is distinct from 'object' then
    raise exception 'mapeamento: objeto campo → coluna' using errcode = '22023';
  end if;
  for item in select key, value from jsonb_each(columns) loop
    if item.key not in ('timestamp', 'severity', 'operation', 'execution_id', 'trace_id', 'message',
        'http_status', 'error_code') then
      raise exception 'campo fora do Contrato de evento: %', left(item.key, 40) using errcode = '22023';
    end if;
    if jsonb_typeof(item.value) <> 'string' or char_length(btrim(item.value #>> '{}')) not between 1 and 200 then
      raise exception 'coluna de % com 1 a 200 caracteres', item.key using errcode = '22023';
    end if;
  end loop;
  insert into doctor.import_mappings (tenant_id, integration_id, columns, updated_by)
  values (tenant, integration, columns, auth.uid())
  on conflict (tenant_id, integration_id) do update
  set columns = excluded.columns, updated_by = excluded.updated_by;
end;
$$;

revoke all on function doctor.set_import_mapping(uuid, jsonb) from public, anon, service_role;
grant execute on function doctor.set_import_mapping(uuid, jsonb) to authenticated;
-- O worker de ingestão lê o mapeamento como plataforma.
grant select on doctor.import_mappings to service_role;
