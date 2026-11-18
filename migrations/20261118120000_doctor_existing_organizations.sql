-- Organização que já existe no jayv-coder: em vez de criar outra, o owner ativa o Doctor nela
-- (ADR-0025 do jayv-doctor, que revisa o ADR-0009). Os membros do jayv-coder entram com o Papel
-- equivalente: owner → owner, maintainer → admin, member → viewer. Quem entra no jayv-coder
-- depois ganha o Vínculo no próximo acesso ao Doctor (`join_organizations`). Quem saiu pelo
-- Doctor (remoção, SCIM, grupos do SSO) não volta sozinho (`membership_removals`), e nada disso
-- passa do limite de membros do plano.

create table doctor.membership_removals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  removed_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, user_id)
);
comment on table doctor.membership_removals is
  'Quem é do jayv-coder mas não entra sozinho no Doctor: saiu pelo Doctor ou já estava de fora quando o acesso automático chegou.';

alter table doctor.membership_removals enable row level security;
revoke all on doctor.membership_removals from anon, authenticated;

-- Organizações que já usavam o Doctor: quem é do jayv-coder e não tinha Vínculo (nunca
-- convidado ou já removido) continua de fora; só quem entrar no jayv-coder daqui em diante
-- entra sozinho.
insert into doctor.membership_removals (tenant_id, user_id)
select m.org_id, m.user_id
from public.organization_members m
join doctor.tenants t on t.id = m.org_id
where not exists (
  select 1 from doctor.memberships d where d.tenant_id = m.org_id and d.user_id = m.user_id
)
on conflict (tenant_id, user_id) do nothing;

-- Toda saída pelo Doctor fica registrada, venha de onde vier (remove_member, SCIM, grupos do
-- SSO). Saída pelo jayv-coder ou Organização apagada chega em cascata: o Vínculo do jayv-coder
-- ou o tenant já não existem, e não há o que registrar.
create function doctor.record_membership_removal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from doctor.tenants t where t.id = old.tenant_id)
     and exists (
       select 1 from public.organization_members m
       where m.org_id = old.tenant_id and m.user_id = old.user_id
     ) then
    insert into doctor.membership_removals (tenant_id, user_id)
    values (old.tenant_id, old.user_id)
    on conflict (tenant_id, user_id) do update set removed_at = now();
  end if;
  return old;
end;
$$;

-- Quem voltou por um caminho explícito (convite aceito, SSO) deixa de estar de fora.
create function doctor.clear_membership_removal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from doctor.membership_removals r
  where r.tenant_id = new.tenant_id and r.user_id = new.user_id;
  return new;
end;
$$;

create trigger memberships_record_removal
after delete on doctor.memberships
for each row execute function doctor.record_membership_removal();

create trigger memberships_clear_removal
after insert on doctor.memberships
for each row execute function doctor.clear_membership_removal();

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

-- O Vínculo de um membro do jayv-coder, se couber no plano: sem vaga, fica para quando houver.
create function doctor.join_if_room(tenant uuid, member uuid, coder_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into doctor.memberships (tenant_id, user_id, role)
  values (tenant, member, doctor.role_from_coder(coder_role))
  on conflict (tenant_id, user_id) do nothing;
exception when sqlstate 'DR051' then
  null;
end;
$$;

-- O owner do jayv-coder ativa o Doctor: grava o que é do Doctor, dá o Vínculo aos membros (quem
-- ativou primeiro, depois owners, maintainers e members, até o limite do plano) e deixa a
-- Organização ativa para quem ativou.
create function doctor.enable_organization(org uuid, segment text, llm_provider text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  caller_role text;
  member record;
begin
  select m.role into caller_role from public.organization_members m
  where m.org_id = org and m.user_id = caller;
  -- Quem não é da Organização recebe o mesmo que se ela não existisse (404 na API).
  if caller is null or caller_role is null then
    raise no_data_found using message = 'Organização não encontrada';
  end if;
  if caller_role <> 'owner' then
    raise insufficient_privilege using message = 'só o owner da Organização ativa o Doctor';
  end if;
  if exists (select 1 from doctor.tenants t where t.id = org) then
    raise unique_violation using message = 'o Doctor já está ativo nesta Organização';
  end if;

  insert into doctor.tenants (id, segment, llm_provider, dpa_accepted_at)
  values (org, segment, llm_provider, now());
  for member in
    select m.user_id, m.role from public.organization_members m
    where m.org_id = org
    order by m.user_id = caller desc,
      case m.role when 'owner' then 0 when 'maintainer' then 1 else 2 end, m.user_id
  loop
    perform doctor.join_if_room(org, member.user_id, member.role);
  end loop;
  insert into doctor.user_active_tenant (user_id, tenant_id) values (caller, org)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;
  return org;
end;
$$;

-- Chamada a cada acesso ao Doctor (`/me`): dá o Vínculo que falta nas Organizações ativas no
-- Doctor em que quem pede é membro no jayv-coder, menos onde está de fora. Não falha: sem vaga
-- no plano, tenta de novo no próximo acesso.
create function doctor.join_organizations()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  member record;
begin
  for member in
    select m.org_id, m.role
    from public.organization_members m
    join doctor.tenants t on t.id = m.org_id and t.status = 'active'
    where m.user_id = auth.uid()
      and not exists (
        select 1 from doctor.memberships d where d.tenant_id = m.org_id and d.user_id = m.user_id
      )
      and not exists (
        select 1 from doctor.membership_removals r
        where r.tenant_id = m.org_id and r.user_id = m.user_id
      )
  loop
    perform doctor.join_if_room(member.org_id, auth.uid(), member.role);
  end loop;
end;
$$;

revoke all on function doctor.record_membership_removal() from public, anon, authenticated, service_role;
revoke all on function doctor.clear_membership_removal() from public, anon, authenticated, service_role;
revoke all on function doctor.role_from_coder(text) from public, anon, authenticated, service_role;
revoke all on function doctor.join_if_room(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function doctor.available_organizations() from public, anon, service_role;
revoke all on function doctor.enable_organization(uuid, text, text) from public, anon, service_role;
revoke all on function doctor.join_organizations() from public, anon, service_role;
grant execute on function doctor.available_organizations() to authenticated;
grant execute on function doctor.enable_organization(uuid, text, text) to authenticated;
grant execute on function doctor.join_organizations() to authenticated;
