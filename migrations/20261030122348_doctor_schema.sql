-- O Doctor divide o projeto Supabase com o jayv-coder (ADR-0009): tudo dele fica no schema `doctor`,
-- que não é exposto pelo PostgREST. O tenant vem só do JWT (ADR-0004).
create schema if not exists doctor;
comment on schema doctor is 'Integration AI Doctor: tabelas e helpers de tenancy. Não exposto pelo PostgREST.';
revoke all on schema doctor from public;
grant usage on schema doctor to authenticated, service_role;

-- Fora de `public` não valem os privilégios padrão do Supabase: jobs de plataforma precisam disto.
alter default privileges in schema doctor grant all on tables to service_role;

-- Migrações do Doctor aplicadas: o histórico do Supabase é do jayv-coder (ADR-0009).
create table doctor.schema_migrations (
  version text primary key,
  applied_at timestamptz not null default now()
);
alter table doctor.schema_migrations enable row level security;
revoke all on doctor.schema_migrations from anon, authenticated;

-- Organização ativa: claim `tenant_id` emitida pelo Custom Access Token Hook (ticket #5).
create function doctor.current_tenant_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'tenant_id', '')::uuid
$$;

-- Papel do Usuário na Organização ativa: owner, admin, analyst ou viewer.
create function doctor.current_tenant_role()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'tenant_role', '')
$$;

create function doctor.has_role(variadic roles text[])
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(doctor.current_tenant_role() = any (roles), false)
$$;

create function doctor.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on all functions in schema doctor from public;
grant execute on all functions in schema doctor to authenticated, service_role;

-- O que uma Organização tem no Doctor. Nome e slug ficam em public.organizations, do jayv-coder;
-- só as Organizações com linha aqui usam o Doctor. Plano e status mudam só pela plataforma.
-- `restrict`: apagar no jayv-coder não pode levar Diagnósticos e o aceite do DPA junto.
create table doctor.tenants (
  id uuid primary key references public.organizations (id) on delete restrict,
  plan text not null default 'pilot' check (plan in ('pilot', 'professional', 'enterprise')),
  llm_provider text not null default 'anthropic' check (llm_provider in ('anthropic', 'vertex')),
  status text not null default 'active' check (status in ('active', 'suspended', 'deleted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table doctor.tenants is 'Organizações habilitadas no Doctor: a unidade de isolamento de dados.';

create trigger tenants_set_updated_at
before update on doctor.tenants
for each row execute function doctor.set_updated_at();

alter table doctor.tenants enable row level security;

revoke all on doctor.tenants from anon, authenticated;
grant select on doctor.tenants to authenticated;

create policy tenants_select_own on doctor.tenants
for select to authenticated
using (id = (select doctor.current_tenant_id()));

create policy tenants_update_by_admin on doctor.tenants
for update to authenticated
using (id = (select doctor.current_tenant_id()) and (select doctor.has_role('owner', 'admin')))
with check (id = (select doctor.current_tenant_id()));
