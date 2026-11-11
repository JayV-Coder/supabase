-- Ticket #48: SSO corporativo (SAML 2.0) por Organização. O provedor SAML é do Supabase Auth do
-- projeto (compartilhado com o jayv-coder, ADR-0009): quem o registra é a operação da plataforma,
-- pelo worker `notifier` com a Management API (ADR-0021). Aqui ficam a conexão da Organização, os
-- domínios verificados por TXT de DNS, o mapeamento grupo → Papel (JIT), os usuários do SCIM e a
-- regra "Exigir SSO", aplicada no hook de claims sem afetar o login de quem não é do Doctor.

create table doctor.sso_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  status text not null default 'pending_platform'
    check (status in ('pending_platform', 'active', 'error')),
  metadata_url text not null check (metadata_url ~ '^https://[^\s@]+$' and char_length(metadata_url) <= 500),
  -- Id do provedor SAML no Supabase Auth (vem no `amr` do JWT de quem entra pelo SSO).
  provider_id uuid unique,
  require_sso boolean not null default false,
  -- Papel de quem entra sem grupo mapeado; nulo: sem grupo mapeado, sem acesso.
  default_role text check (default_role in ('admin', 'analyst', 'viewer')),
  scim_token_hash text unique check (scim_token_hash ~ '^[0-9a-f]{64}$'),
  last_error text check (char_length(last_error) <= 500),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id)
);
comment on table doctor.sso_connections is 'Conexão SAML 2.0 da Organização com o IdP (Entra ID, Okta, Google Workspace).';

create table doctor.sso_domains (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  -- Um domínio é de uma Organização só.
  domain text not null unique
    check (domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' and char_length(domain) <= 253),
  -- Vai no TXT `_aid-sso.<domínio>` como `aid-sso=<token>`.
  token text not null default encode(gen_random_bytes(16), 'hex'),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table doctor.sso_domains is 'Domínio de e-mail da Organização no SSO, verificado por TXT de DNS.';

create table doctor.sso_group_roles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  group_name text not null check (char_length(btrim(group_name)) between 1 and 200),
  -- Owner não vem do IdP: é atribuído na tela, para nenhum grupo tomar a Organização.
  role text not null check (role in ('admin', 'analyst', 'viewer')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, group_name)
);
comment on table doctor.sso_group_roles is 'Mapeamento grupo do IdP (atributo groups) → Papel no JIT.';

-- Usuários que o IdP mandou pelo SCIM 2.0; `active = false` tira o Vínculo e as sessões.
create table doctor.sso_scim_users (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_name text not null check (user_name = lower(user_name) and char_length(user_name) between 3 and 320),
  external_id text check (char_length(external_id) <= 200),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, user_name)
);
comment on table doctor.sso_scim_users is 'Usuários provisionados pelo SCIM 2.0 do IdP (desprovisionamento automático).';

create trigger sso_connections_set_updated_at before update on doctor.sso_connections
for each row execute function doctor.set_updated_at();
create trigger sso_domains_set_updated_at before update on doctor.sso_domains
for each row execute function doctor.set_updated_at();
create trigger sso_group_roles_set_updated_at before update on doctor.sso_group_roles
for each row execute function doctor.set_updated_at();
create trigger sso_scim_users_set_updated_at before update on doctor.sso_scim_users
for each row execute function doctor.set_updated_at();

alter table doctor.sso_connections enable row level security;
alter table doctor.sso_domains enable row level security;
alter table doctor.sso_group_roles enable row level security;
alter table doctor.sso_scim_users enable row level security;
revoke all on doctor.sso_connections, doctor.sso_domains, doctor.sso_group_roles, doctor.sso_scim_users
  from anon, authenticated;
grant select (id, tenant_id, status, metadata_url, provider_id, require_sso, default_role, last_error,
  created_at, updated_at) on doctor.sso_connections to authenticated;
grant select on doctor.sso_domains, doctor.sso_group_roles to authenticated;
grant select (id, tenant_id, user_name, active, created_at, updated_at) on doctor.sso_scim_users to authenticated;
create policy sso_connections_select on doctor.sso_connections for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
create policy sso_domains_select on doctor.sso_domains for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
create policy sso_group_roles_select on doctor.sso_group_roles for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
create policy sso_scim_users_select on doctor.sso_scim_users for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- SSO é do Owner com MFA: ele decide quem entra na Organização.
create function doctor.require_sso_owner()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if doctor.require_manager() <> 'owner' then
    raise insufficient_privilege using message = 'exige o Owner com MFA';
  end if;
  return doctor.current_tenant_id();
end;
$$;

create function doctor.configure_sso(metadata_url text, require_sso boolean, default_role text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
  connection uuid;
begin
  if configure_sso.require_sso and not exists (
      select 1 from doctor.sso_domains d where d.tenant_id = tenant and d.verified_at is not null) then
    raise exception 'exigir SSO pede um domínio verificado' using errcode = 'DR101';
  end if;
  insert into doctor.sso_connections (tenant_id, metadata_url, require_sso, default_role, created_by)
  values (tenant, configure_sso.metadata_url, configure_sso.require_sso, configure_sso.default_role, auth.uid())
  on conflict on constraint sso_connections_tenant_id_key do update
  set metadata_url = excluded.metadata_url, require_sso = excluded.require_sso,
    default_role = excluded.default_role,
    -- Metadados novos voltam para a plataforma registrar; o resto vale na hora.
    status = case when doctor.sso_connections.metadata_url is distinct from excluded.metadata_url
      then 'pending_platform' else doctor.sso_connections.status end
  returning id into connection;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'sso.sync', jsonb_build_object('connection_id', connection));
  perform doctor.record_audit(tenant, 'sso.configure', connection::text);
  return connection;
end;
$$;

create function doctor.disable_sso()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
  provider uuid;
begin
  delete from doctor.sso_connections c where c.tenant_id = tenant returning c.provider_id into provider;
  if provider is not null then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (tenant, 'sso.sync', jsonb_build_object('remove_provider', provider));
  end if;
  perform doctor.record_audit(tenant, 'sso.disable', tenant::text);
end;
$$;

create function doctor.add_sso_domain(domain text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
  created uuid;
begin
  insert into doctor.sso_domains (tenant_id, domain) values (tenant, lower(btrim(add_sso_domain.domain)))
  on conflict on constraint sso_domains_domain_key do nothing
  returning id into created;
  if created is null then
    raise exception 'domínio já cadastrado' using errcode = 'DR100';
  end if;
  perform doctor.record_audit(tenant, 'sso.domain_added', created::text);
  return created;
end;
$$;

create function doctor.verify_sso_domain(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
begin
  if not exists (select 1 from doctor.sso_domains d where d.id = target and d.tenant_id = tenant) then
    raise no_data_found using message = 'domínio não encontrado';
  end if;
  -- A consulta ao DNS é da plataforma (worker): a Organização não marca o próprio domínio.
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'sso.domain', jsonb_build_object('domain_id', target));
end;
$$;

create function doctor.remove_sso_domain(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
begin
  delete from doctor.sso_domains d where d.id = target and d.tenant_id = tenant;
  if not found then
    raise no_data_found using message = 'domínio não encontrado';
  end if;
  -- Sem domínio verificado, "Exigir SSO" não tem a quem valer.
  update doctor.sso_connections c set require_sso = false
  where c.tenant_id = tenant and not exists (
    select 1 from doctor.sso_domains d where d.tenant_id = tenant and d.verified_at is not null);
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  select tenant, 'sso.sync', jsonb_build_object('connection_id', c.id)
  from doctor.sso_connections c where c.tenant_id = tenant;
  perform doctor.record_audit(tenant, 'sso.domain_removed', target::text);
end;
$$;

-- Mapeamento grupo → Papel inteiro de uma vez: {"AID-Admins": "admin", ...}.
create function doctor.set_sso_groups(mapping jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
begin
  if jsonb_typeof(mapping) <> 'object' then
    raise exception 'mapeamento inválido' using errcode = '22023';
  end if;
  delete from doctor.sso_group_roles g where g.tenant_id = tenant;
  insert into doctor.sso_group_roles (tenant_id, group_name, role)
  select tenant, btrim(m.key), m.value #>> '{}' from jsonb_each(mapping) m;
  perform doctor.record_audit(tenant, 'sso.groups_changed', tenant::text);
end;
$$;

-- Token do SCIM: a API gera e mostra uma vez; o banco guarda o hash.
create function doctor.set_scim_token(token_hash text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.require_sso_owner();
begin
  update doctor.sso_connections c set scim_token_hash = set_scim_token.token_hash where c.tenant_id = tenant;
  if not found then
    raise exception 'configure o SSO antes' using errcode = 'DR102';
  end if;
  perform doctor.record_audit(tenant, 'sso.scim_token_rotated', tenant::text);
end;
$$;

-- Plataforma (worker): domínio conferido no DNS e o provedor registrado no Supabase Auth.
create function doctor.mark_sso_domain(target uuid, verified boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update doctor.sso_domains d set verified_at = case when verified then coalesce(d.verified_at, now()) end
  where d.id = target
$$;

create function doctor.set_sso_provider(connection uuid, provider uuid, status text, error text)
returns void
language sql
security definer
set search_path = ''
as $$
  update doctor.sso_connections c
  set provider_id = coalesce(set_sso_provider.provider, c.provider_id), status = set_sso_provider.status,
    last_error = left(set_sso_provider.error, 500)
  where c.id = connection
$$;

-- Login: o e-mail é de um domínio com SSO? (anon, antes de entrar).
create function doctor.sso_discover(email text)
returns table (domain text, required boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select d.domain, c.require_sso
  from doctor.sso_domains d
  join doctor.sso_connections c on c.tenant_id = d.tenant_id and c.status = 'active'
  where d.verified_at is not null and d.domain = lower(split_part(sso_discover.email, '@', 2))
$$;

-- O maior Papel entre os grupos do usuário.
create function doctor.sso_rank(role text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case role when 'admin' then 3 when 'analyst' then 2 when 'viewer' then 1 else 0 end
$$;

-- JIT: quem entrou pelo SSO ganha (ou atualiza) o Vínculo pelo mapeamento dos grupos. Chamado
-- pelo app logo depois do login SAML, com o JWT do próprio usuário.
create function doctor.sso_provision()
returns table (tenant_id uuid, role text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  idp uuid;
  found_connection doctor.sso_connections;
  email text;
  groups jsonb;
  chosen text;
begin
  select (a ->> 'provider')::uuid into idp
  from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]')) a
  where a ->> 'method' like 'sso%' and a ->> 'provider' is not null
  limit 1;
  if me is null or idp is null then
    raise exception 'entre pelo SSO antes' using errcode = 'DR103';
  end if;
  select * into found_connection from doctor.sso_connections c
  where c.provider_id = idp and c.status = 'active';
  if found_connection.id is null then
    raise exception 'SSO não ativo' using errcode = 'DR103';
  end if;
  select lower(u.email) into email from auth.users u where u.id = me;
  if exists (select 1 from doctor.sso_scim_users s
      where s.tenant_id = found_connection.tenant_id and s.user_name = email and not s.active) then
    raise exception 'desativado no IdP' using errcode = 'DR104';
  end if;
  select coalesce(
      (select i.identity_data -> 'custom_claims' -> 'groups' from auth.identities i
        where i.user_id = me and i.provider = 'sso:' || idp::text limit 1),
      (select u.raw_user_meta_data -> 'custom_claims' -> 'groups' from auth.users u where u.id = me),
      '[]'::jsonb)
  into groups;
  if jsonb_typeof(groups) = 'string' then
    groups := jsonb_build_array(groups);
  end if;
  select g.role into chosen
  from doctor.sso_group_roles g
  where g.tenant_id = found_connection.tenant_id
    and jsonb_typeof(groups) = 'array' and groups ? g.group_name
  order by doctor.sso_rank(g.role) desc limit 1;
  chosen := coalesce(chosen, found_connection.default_role);
  if chosen is null then
    -- Saiu dos grupos mapeados: perde o Vínculo (o Owner, atribuído na tela, fica).
    delete from doctor.memberships m
    where m.tenant_id = found_connection.tenant_id and m.user_id = me and m.role <> 'owner';
    raise exception 'sem grupo mapeado' using errcode = 'DR105';
  end if;
  insert into public.organization_members (org_id, user_id, role)
  values (found_connection.tenant_id, me, 'member') on conflict do nothing;
  insert into doctor.memberships (tenant_id, user_id, role)
  values (found_connection.tenant_id, me, chosen)
  on conflict on constraint memberships_tenant_id_user_id_key do update
  set role = case when doctor.memberships.role = 'owner' then 'owner' else excluded.role end;
  insert into doctor.user_active_tenant (user_id, tenant_id)
  values (me, found_connection.tenant_id)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;
  return query
  select m.tenant_id, m.role from doctor.memberships m
  where m.tenant_id = found_connection.tenant_id and m.user_id = me;
end;
$$;

-- SCIM 2.0 (anon, pelo hash do token da Organização).
create function doctor.scim_connection(token_hash text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.tenant_id from doctor.sso_connections c where c.scim_token_hash = scim_connection.token_hash
$$;

create function doctor.scim_upsert_user(token_hash text, user_name text, external_id text, active boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.scim_connection(token_hash);
  found_id uuid;
begin
  if tenant is null then
    raise exception 'token SCIM inválido' using errcode = 'DR106';
  end if;
  insert into doctor.sso_scim_users (tenant_id, user_name, external_id, active)
  values (tenant, lower(btrim(scim_upsert_user.user_name)), scim_upsert_user.external_id, scim_upsert_user.active)
  on conflict on constraint sso_scim_users_tenant_id_user_name_key do update
  set external_id = coalesce(excluded.external_id, doctor.sso_scim_users.external_id), active = excluded.active
  returning id into found_id;
  if not scim_upsert_user.active then
    perform doctor.scim_revoke(tenant, lower(btrim(scim_upsert_user.user_name)));
  end if;
  return found_id;
end;
$$;

-- Desprovisionar: tira o Vínculo (menos o Owner) e encerra as sessões do usuário no Auth (o
-- refresh token morre; a API confere o Vínculo a cada pedido, então o acesso cai na hora).
create function doctor.scim_revoke(tenant uuid, user_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  select u.id into target from auth.users u where lower(u.email) = scim_revoke.user_name;
  if target is null then
    return;
  end if;
  delete from doctor.memberships m where m.tenant_id = tenant and m.user_id = target and m.role <> 'owner';
  delete from public.organization_members o
  where o.org_id = tenant and o.user_id = target
    and not exists (select 1 from doctor.memberships m where m.tenant_id = tenant and m.user_id = target);
  begin
    delete from auth.sessions s where s.user_id = target;
  exception when insufficient_privilege then
    raise warning 'doctor.scim_revoke: sem permissão em auth.sessions';
  end;
  perform doctor.write_audit(tenant, 'sso.scim_deprovisioned', 'membership', target::text, null, null);
end;
$$;

create function doctor.scim_set_active(token_hash text, target uuid, active boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.scim_connection(token_hash);
  name text;
begin
  if tenant is null then
    raise exception 'token SCIM inválido' using errcode = 'DR106';
  end if;
  update doctor.sso_scim_users s set active = scim_set_active.active
  where s.id = target and s.tenant_id = tenant returning s.user_name into name;
  if name is null then
    return false;
  end if;
  if not scim_set_active.active then
    perform doctor.scim_revoke(tenant, name);
  end if;
  return true;
end;
$$;

create function doctor.scim_delete_user(token_hash text, target uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.scim_connection(token_hash);
  name text;
begin
  if tenant is null then
    raise exception 'token SCIM inválido' using errcode = 'DR106';
  end if;
  delete from doctor.sso_scim_users s where s.id = target and s.tenant_id = tenant returning s.user_name into name;
  if name is null then
    return false;
  end if;
  perform doctor.scim_revoke(tenant, name);
  return true;
end;
$$;

create function doctor.scim_users(token_hash text, filter_name text, target uuid)
returns table (id uuid, user_name text, external_id text, active boolean, created_at timestamptz, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.scim_connection(token_hash);
begin
  if tenant is null then
    raise exception 'token SCIM inválido' using errcode = 'DR106';
  end if;
  return query
  select s.id, s.user_name, s.external_id, s.active, s.created_at, s.updated_at
  from doctor.sso_scim_users s
  where s.tenant_id = tenant
    and (scim_users.filter_name is null or s.user_name = lower(scim_users.filter_name))
    and (scim_users.target is null or s.id = scim_users.target)
  order by s.created_at limit 200;
end;
$$;

-- "Exigir SSO": o hook não dá as claims do Doctor a quem é de um domínio exigido e não entrou
-- pelo SSO. O login em si segue (o hook vale para o projeto todo, inclusive o jayv-coder).
create or replace function doctor.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set lock_timeout = '500ms'
as $$
declare
  claims jsonb := coalesce(event -> 'claims', '{}') - 'tenant_id' - 'tenant_role';
  active_tenant uuid;
  active_role text;
  user_email text;
begin
  select m.tenant_id, m.role into active_tenant, active_role
  from doctor.user_active_tenant a
  join doctor.memberships m on m.tenant_id = a.tenant_id and m.user_id = a.user_id
  join doctor.tenants t on t.id = m.tenant_id
  where a.user_id = (event ->> 'user_id')::uuid and t.status = 'active';

  if active_tenant is not null and exists (
      select 1 from doctor.sso_connections c where c.tenant_id = active_tenant and c.require_sso) then
    select lower(u.email) into user_email from auth.users u where u.id = (event ->> 'user_id')::uuid;
    if exists (
        select 1 from doctor.sso_domains d
        where d.tenant_id = active_tenant and d.verified_at is not null
          and d.domain = split_part(user_email, '@', 2))
      and not exists (
        select 1 from jsonb_array_elements(coalesce(claims -> 'amr', '[]')) a
        where a ->> 'method' like 'sso%') then
      active_tenant := null;
    end if;
  end if;

  if active_tenant is not null then
    claims := claims || jsonb_build_object('tenant_id', active_tenant, 'tenant_role', active_role);
  end if;
  return jsonb_set(event, '{claims}', claims);
exception when query_canceled or others then
  raise warning 'doctor.custom_access_token_hook: %', sqlstate;
  return event #- '{claims,tenant_id}' #- '{claims,tenant_role}';
end;
$$;
grant select on doctor.sso_connections, doctor.sso_domains to supabase_auth_admin;

revoke all on function doctor.require_sso_owner() from public, anon, service_role;
revoke all on function doctor.configure_sso(text, boolean, text) from public, anon, service_role;
revoke all on function doctor.disable_sso() from public, anon, service_role;
revoke all on function doctor.add_sso_domain(text) from public, anon, service_role;
revoke all on function doctor.verify_sso_domain(uuid) from public, anon, service_role;
revoke all on function doctor.remove_sso_domain(uuid) from public, anon, service_role;
revoke all on function doctor.set_sso_groups(jsonb) from public, anon, service_role;
revoke all on function doctor.set_scim_token(text) from public, anon, service_role;
revoke all on function doctor.mark_sso_domain(uuid, boolean) from public, anon, authenticated;
revoke all on function doctor.set_sso_provider(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function doctor.sso_discover(text) from public, service_role;
revoke all on function doctor.sso_rank(text) from public, anon, authenticated;
grant execute on function doctor.sso_rank(text) to service_role;
revoke all on function doctor.sso_provision() from public, anon, service_role;
revoke all on function doctor.scim_connection(text) from public, anon, authenticated, service_role;
revoke all on function doctor.scim_upsert_user(text, text, text, boolean) from public, authenticated, service_role;
revoke all on function doctor.scim_revoke(uuid, text) from public, anon, authenticated, service_role;
revoke all on function doctor.scim_set_active(text, uuid, boolean) from public, authenticated, service_role;
revoke all on function doctor.scim_delete_user(text, uuid) from public, authenticated, service_role;
revoke all on function doctor.scim_users(text, text, uuid) from public, authenticated, service_role;
grant execute on function doctor.configure_sso(text, boolean, text) to authenticated;
grant execute on function doctor.disable_sso() to authenticated;
grant execute on function doctor.add_sso_domain(text) to authenticated;
grant execute on function doctor.verify_sso_domain(uuid) to authenticated;
grant execute on function doctor.remove_sso_domain(uuid) to authenticated;
grant execute on function doctor.set_sso_groups(jsonb) to authenticated;
grant execute on function doctor.set_scim_token(text) to authenticated;
grant execute on function doctor.sso_provision() to authenticated;
grant execute on function doctor.mark_sso_domain(uuid, boolean) to service_role;
grant execute on function doctor.set_sso_provider(uuid, uuid, text, text) to service_role;
grant execute on function doctor.sso_discover(text) to anon, authenticated;
grant execute on function doctor.scim_upsert_user(text, text, text, boolean) to anon;
grant execute on function doctor.scim_set_active(text, uuid, boolean) to anon;
grant execute on function doctor.scim_delete_user(text, uuid) to anon;
grant execute on function doctor.scim_users(text, text, uuid) to anon;
