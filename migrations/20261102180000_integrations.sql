-- Ticket #10: Integrações (fluxos de negócio monitorados) com Ambiente.

-- Para políticas de escrita: Owner ou Admin com MFA, com o Papel lido da tabela, como em
-- `require_manager`. A claim pode estar atrasada em até uma hora depois de um rebaixamento.
-- security definer: lê o Vínculo sem depender do RLS de memberships.
create function doctor.is_manager()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select doctor.current_aal() = 'aal2' and exists (
    select 1 from doctor.memberships m
    where m.tenant_id = doctor.current_tenant_id()
      and m.user_id = auth.uid()
      and m.role in ('owner', 'admin')
  )
$$;

revoke all on function doctor.is_manager() from public, service_role;
grant execute on function doctor.is_manager() to authenticated;

create table doctor.integrations (
  id uuid primary key default gen_random_uuid(),
  -- Sem grant de escrita na coluna: o tenant sai sempre da claim do JWT.
  tenant_id uuid not null default doctor.current_tenant_id() references doctor.tenants (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  description text check (char_length(description) <= 500),
  source_system text not null check (source_system in ('sap', 'salesforce', 'gcp', 'other')),
  target_system text not null check (target_system in ('sap', 'salesforce', 'gcp', 'other')),
  owner_team text check (char_length(btrim(owner_team)) between 1 and 80),
  environment text not null check (environment in ('dev', 'hml', 'prd')),
  -- Sem exclusão física: Execuções e Incidentes vão apontar para a Integração.
  archived_at timestamptz,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table doctor.integrations is 'Integração: fluxo de negócio monitorado entre origem e destino, em um Ambiente.';

-- Nome único por Ambiente entre as ativas: arquivar libera o nome para um novo cadastro, já que a
-- arquivada não volta. Também atende à lista padrão (ativas, por nome).
create unique index integrations_active_name_key
  on doctor.integrations (tenant_id, name, environment) where archived_at is null;

create trigger integrations_set_updated_at
before update on doctor.integrations
for each row execute function doctor.set_updated_at();

alter table doctor.integrations enable row level security;

revoke all on doctor.integrations from anon, authenticated;
grant select on doctor.integrations to authenticated;
grant insert (name, description, source_system, target_system, owner_team, environment)
  on doctor.integrations to authenticated;
grant update (name, description, source_system, target_system, owner_team, environment, archived_at)
  on doctor.integrations to authenticated;

create policy integrations_select on doctor.integrations
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy integrations_insert on doctor.integrations
for insert to authenticated
with check (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

-- Arquivada fica congelada: o `using` só alcança as ativas.
create policy integrations_update on doctor.integrations
for update to authenticated
using (
  tenant_id = (select doctor.current_tenant_id()) and archived_at is null and (select doctor.is_manager())
)
with check (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));
