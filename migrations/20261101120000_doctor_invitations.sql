-- Ticket #6: Convites e gestão de Papéis.
-- Erros: DR001 último Owner · DR002 convite expirado ou usado · DR003 convite de outro e-mail ·
-- DR004 já tem Papel. A API os traduz em `code`.

-- Sem citext: a extensão não existe no projeto compartilhado.
create table doctor.invitations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  email text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+$'),
  role text not null check (role in ('owner', 'admin', 'analyst', 'viewer')),
  token_hash text not null unique,
  invited_by uuid references auth.users (id) on delete set null,
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table doctor.invitations is 'Convites: só o hash do token é guardado.';

create unique index invitations_one_pending_idx on doctor.invitations (tenant_id, email)
where accepted_at is null;

create trigger invitations_set_updated_at
before update on doctor.invitations
for each row execute function doctor.set_updated_at();

alter table doctor.invitations enable row level security;

-- Sem grant nem policy: tudo passa pelas funções abaixo, que leem o Papel da tabela.
revoke all on doctor.invitations from anon, authenticated;

-- O Papel vem do banco, não do JWT: a claim pode estar até 1 h atrasada, e aqui ela daria a quem foi
-- rebaixado ou removido o poder de mexer em Papéis. Só para as funções abaixo: sem grant.
create function doctor.require_manager()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_role text;
begin
  select m.role into actor_role
  from doctor.memberships m
  where m.tenant_id = doctor.current_tenant_id() and m.user_id = auth.uid();

  if actor_role is null or actor_role not in ('owner', 'admin') or doctor.current_aal() is distinct from 'aal2' then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  return actor_role;
end;
$$;

revoke all on function doctor.require_manager() from public, authenticated, service_role;

create function doctor.invite_member(email text, role text, token_hash text)
returns table (id uuid, organization text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text := doctor.require_manager();
  tenant uuid := doctor.current_tenant_id();
  normalized text := lower(btrim(invite_member.email));
  new_id uuid;
begin
  if invite_member.role = 'owner' and actor_role <> 'owner' then
    raise insufficient_privilege using message = 'só Owner convida Owner';
  end if;
  if exists (
    select 1 from doctor.memberships m join auth.users u on u.id = m.user_id
    where m.tenant_id = tenant and lower(u.email) = normalized
  ) then
    raise exception 'já tem Papel' using errcode = 'DR004';
  end if;

  -- Convite vencido não bloqueia um novo.
  delete from doctor.invitations i
  where i.tenant_id = tenant and i.email = normalized and i.accepted_at is null and i.expires_at < now();

  insert into doctor.invitations (tenant_id, email, role, token_hash, invited_by)
  values (tenant, normalized, invite_member.role, invite_member.token_hash, auth.uid())
  returning invitations.id into new_id;

  return query
    select new_id, o.name from public.organizations o where o.id = tenant;
end;
$$;

create function doctor.resend_invitation(target uuid, token_hash text)
returns table (email text, organization text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text := doctor.require_manager();
  tenant uuid := doctor.current_tenant_id();
begin
  update doctor.invitations i
  set token_hash = resend_invitation.token_hash, expires_at = now() + interval '7 days'
  where i.id = target and i.tenant_id = tenant and i.accepted_at is null
    and (i.role <> 'owner' or actor_role = 'owner');
  if not found then
    raise no_data_found using message = 'convite não encontrado';
  end if;

  return query
    select i.email, o.name
    from doctor.invitations i join public.organizations o on o.id = i.tenant_id
    where i.id = target;
end;
$$;

create function doctor.revoke_invitation(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text := doctor.require_manager();
begin
  delete from doctor.invitations i
  where i.id = target and i.tenant_id = doctor.current_tenant_id() and i.accepted_at is null
    and (i.role <> 'owner' or actor_role = 'owner');
  if not found then
    raise no_data_found using message = 'convite não encontrado';
  end if;
end;
$$;

-- O e-mail vem de auth.users e precisa estar confirmado: sem isso, quem se cadastrasse com o e-mail
-- de outra pessoa ficaria com o convite dela. O Vínculo em `public` entra como `member`; quem já é
-- da Organização no jayv-coder mantém o que tem lá.
create function doctor.accept_invitation(token_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  user_id uuid := auth.uid();
  invitation doctor.invitations;
  confirmed_email text;
begin
  if user_id is null then
    raise insufficient_privilege using message = 'sessão obrigatória';
  end if;

  select * into invitation from doctor.invitations i
  where i.token_hash = accept_invitation.token_hash
  for update;
  if not found then
    raise no_data_found using message = 'convite não encontrado';
  end if;
  if invitation.accepted_at is not null or invitation.expires_at < now() or not exists (
    select 1 from doctor.tenants t where t.id = invitation.tenant_id and t.status = 'active'
  ) then
    raise exception 'convite expirado ou usado' using errcode = 'DR002';
  end if;

  select lower(u.email) into confirmed_email
  from auth.users u
  where u.id = user_id and u.email_confirmed_at is not null;
  if confirmed_email is distinct from invitation.email then
    raise exception 'convite de outro e-mail' using errcode = 'DR003';
  end if;

  insert into public.organization_members (org_id, user_id, role)
  values (invitation.tenant_id, user_id, 'member')
  on conflict do nothing;
  insert into doctor.memberships (tenant_id, user_id, role)
  values (invitation.tenant_id, user_id, invitation.role)
  on conflict on constraint memberships_tenant_id_user_id_key do nothing;
  -- Convite não muda Papel: aqui ele contornaria as regras de Owner.
  if not found then
    raise exception 'já tem Papel' using errcode = 'DR004';
  end if;
  insert into doctor.user_active_tenant (user_id, tenant_id)
  values (user_id, invitation.tenant_id)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;

  update doctor.invitations i set accepted_at = now() where i.id = invitation.id;
  return invitation.tenant_id;
end;
$$;

create function doctor.list_invitations()
returns table (id uuid, email text, role text, expires_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  return query
    select i.id, i.email, i.role, i.expires_at
    from doctor.invitations i
    where i.tenant_id = doctor.current_tenant_id() and i.accepted_at is null
    order by i.created_at;
end;
$$;

create function doctor.list_members()
returns table (id uuid, display_name text, email text, role text, mfa_enabled boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  return query
    select m.id, p.display_name, u.email::text, m.role, exists (
      select 1 from auth.mfa_factors f where f.user_id = m.user_id and f.status::text = 'verified'
    )
    from doctor.memberships m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.user_id = m.user_id
    where m.tenant_id = doctor.current_tenant_id()
    order by coalesce(p.display_name, u.email::text);
end;
$$;

-- Trava a linha do tenant: duas remoções simultâneas não podem deixar a Organização sem Owner.
-- A regra fica aqui, e não num trigger, para não barrar a remoção em cascata vinda do jayv-coder.
create function doctor.locked_target(target uuid, actor_role text)
returns doctor.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  membership doctor.memberships;
begin
  perform 1 from doctor.tenants t where t.id = tenant for update;
  select * into membership from doctor.memberships m where m.id = target and m.tenant_id = tenant;
  if not found then
    raise no_data_found using message = 'membro não encontrado';
  end if;
  if membership.role = 'owner' and actor_role <> 'owner' then
    raise insufficient_privilege using message = 'só Owner altera Owner';
  end if;
  return membership;
end;
$$;

revoke all on function doctor.locked_target(uuid, text) from public, authenticated, service_role;

create function doctor.require_other_owner(membership doctor.memberships)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if membership.role = 'owner' and not exists (
    select 1 from doctor.memberships m
    where m.tenant_id = membership.tenant_id and m.role = 'owner' and m.id <> membership.id
  ) then
    raise exception 'último Owner' using errcode = 'DR001';
  end if;
end;
$$;

revoke all on function doctor.require_other_owner(doctor.memberships) from public, authenticated, service_role;

create function doctor.update_member_role(target uuid, role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text := doctor.require_manager();
  membership doctor.memberships := doctor.locked_target(target, actor_role);
begin
  if update_member_role.role = 'owner' and actor_role <> 'owner' then
    raise insufficient_privilege using message = 'só Owner promove a Owner';
  end if;
  if update_member_role.role <> 'owner' then
    perform doctor.require_other_owner(membership);
  end if;
  update doctor.memberships m set role = update_member_role.role where m.id = target;
end;
$$;

-- Tira só o Papel: a pessoa pode seguir na Organização pelo jayv-coder.
create function doctor.remove_member(target uuid)
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
end;
$$;

revoke all on function doctor.invite_member(text, text, text) from public, service_role;
revoke all on function doctor.resend_invitation(uuid, text) from public, service_role;
revoke all on function doctor.revoke_invitation(uuid) from public, service_role;
revoke all on function doctor.accept_invitation(text) from public, service_role;
revoke all on function doctor.list_members() from public, service_role;
revoke all on function doctor.list_invitations() from public, service_role;
revoke all on function doctor.update_member_role(uuid, text) from public, service_role;
revoke all on function doctor.remove_member(uuid) from public, service_role;
grant execute on function doctor.invite_member(text, text, text) to authenticated;
grant execute on function doctor.resend_invitation(uuid, text) to authenticated;
grant execute on function doctor.revoke_invitation(uuid) to authenticated;
grant execute on function doctor.accept_invitation(text) to authenticated;
grant execute on function doctor.list_members() to authenticated;
grant execute on function doctor.list_invitations() to authenticated;
grant execute on function doctor.update_member_role(uuid, text) to authenticated;
grant execute on function doctor.remove_member(uuid) to authenticated;
