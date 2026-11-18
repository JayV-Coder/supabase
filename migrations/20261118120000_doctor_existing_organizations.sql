-- Organização que já existe no jayv-coder: em vez de criar outra, o owner ativa o Doctor nela
-- (ADR-0025 do jayv-doctor, que revisa o ADR-0009). Os membros do jayv-coder entram com o Papel
-- equivalente: owner → owner, maintainer → admin, member → viewer. Quem entra no jayv-coder
-- depois ganha o Vínculo no próximo acesso ao Doctor (`join_organizations`), e quem o Doctor
-- removeu não volta sozinho (`membership_removals`).

create table doctor.membership_removals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  removed_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, user_id)
);
comment on table doctor.membership_removals is
  'Quem o Doctor removeu de uma Organização: o acesso automático pelo jayv-coder não o devolve.';

alter table doctor.membership_removals enable row level security;
revoke all on doctor.membership_removals from anon, authenticated;

-- O Papel do Doctor para cada Papel do jayv-coder.
create function doctor.role_from_coder(coder_role text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case coder_role when 'owner' then 'owner' when 'maintainer' then 'admin' else 'viewer' end
$$;

-- As Organizações do jayv-coder de quem pede, ainda sem o Doctor (sem linha em doctor.tenants).
create function doctor.available_organizations()
returns table (id uuid, name text, slug text, coder_role text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.id, o.name, o.slug, m.role
  from public.organization_members m
  join public.organizations o on o.id = m.org_id
  where m.user_id = auth.uid()
    and not exists (select 1 from doctor.tenants t where t.id = o.id)
  order by o.name
$$;

-- O owner do jayv-coder ativa o Doctor: grava o que é do Doctor, dá o Vínculo a cada membro e
-- deixa a Organização ativa para quem ativou.
create function doctor.enable_organization(org uuid, segment text, llm_provider text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null or not exists (
    select 1 from public.organization_members m
    where m.org_id = org and m.user_id = caller and m.role = 'owner'
  ) then
    raise insufficient_privilege using message = 'só o owner da Organização ativa o Doctor';
  end if;
  if exists (select 1 from doctor.tenants t where t.id = org) then
    raise unique_violation using message = 'o Doctor já está ativo nesta Organização';
  end if;

  insert into doctor.tenants (id, segment, llm_provider, dpa_accepted_at)
  values (org, segment, llm_provider, now());
  insert into doctor.memberships (tenant_id, user_id, role)
  select org, m.user_id, doctor.role_from_coder(m.role)
  from public.organization_members m
  where m.org_id = org;
  insert into doctor.user_active_tenant (user_id, tenant_id) values (caller, org)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;
  return org;
end;
$$;

-- Chamada a cada acesso ao Doctor (`/me`): dá o Vínculo que falta nas Organizações ativas no
-- Doctor em que quem pede é membro no jayv-coder, menos onde o Doctor o removeu.
create function doctor.join_organizations()
returns void
language sql
security definer
set search_path = ''
as $$
  insert into doctor.memberships (tenant_id, user_id, role)
  select m.org_id, m.user_id, doctor.role_from_coder(m.role)
  from public.organization_members m
  join doctor.tenants t on t.id = m.org_id and t.status = 'active'
  where m.user_id = auth.uid()
    and not exists (
      select 1 from doctor.membership_removals r where r.tenant_id = m.org_id and r.user_id = m.user_id
    )
  on conflict (tenant_id, user_id) do nothing
$$;

-- Remover pelo Doctor passa a deixar registro, para o acesso automático não devolver o Vínculo.
create or replace function doctor.remove_member(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text := doctor.require_manager();
  membership doctor.memberships := doctor.locked_target(target, actor_role);
begin
  perform doctor.require_other_owner(membership);
  delete from doctor.memberships m where m.id = target;
  insert into doctor.membership_removals (tenant_id, user_id)
  values (membership.tenant_id, membership.user_id)
  on conflict (tenant_id, user_id) do update set removed_at = now();
end;
$$;

revoke all on function doctor.role_from_coder(text) from public, anon, authenticated, service_role;
revoke all on function doctor.available_organizations() from public, anon, service_role;
revoke all on function doctor.enable_organization(uuid, text, text) from public, anon, service_role;
revoke all on function doctor.join_organizations() from public, anon, service_role;
grant execute on function doctor.available_organizations() to authenticated;
grant execute on function doctor.enable_organization(uuid, text, text) to authenticated;
grant execute on function doctor.join_organizations() to authenticated;
