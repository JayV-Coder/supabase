-- Ticket #5: Papel no Doctor, Organização ativa e claims de tenant no JWT.
-- O Vínculo é o de public.organization_members (ADR-0009): lá o Papel é do jayv-coder, com outra
-- lista. Este arquivo não altera nada em `public`.

alter table doctor.tenants
  add column segment text check (char_length(segment) between 2 and 80),
  add column dpa_accepted_at timestamptz;

grant update (segment) on doctor.tenants to authenticated;

-- A FK composta leva a remoção do Vínculo em public para cá. Só quem tem linha aqui usa o Doctor.
create table doctor.memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('owner', 'admin', 'analyst', 'viewer')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, user_id),
  foreign key (tenant_id, user_id) references public.organization_members (org_id, user_id) on delete cascade
);
comment on table doctor.memberships is 'Papel do Usuário no Doctor, sobre o Vínculo de public.organization_members.';

create index memberships_user_id_idx on doctor.memberships (user_id);

create trigger memberships_set_updated_at
before update on doctor.memberships
for each row execute function doctor.set_updated_at();

-- A FK composta garante que só há Organização ativa com Papel; remover o Vínculo a apaga.
create table doctor.user_active_tenant (
  user_id uuid primary key references auth.users (id) on delete cascade,
  tenant_id uuid not null,
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, user_id) references doctor.memberships (tenant_id, user_id) on delete cascade
);
comment on table doctor.user_active_tenant is 'Organização ativa de cada Usuário: origem das claims do JWT.';

create index user_active_tenant_tenant_id_idx on doctor.user_active_tenant (tenant_id, user_id);

create trigger user_active_tenant_set_updated_at
before update on doctor.user_active_tenant
for each row execute function doctor.set_updated_at();

alter table doctor.memberships enable row level security;
alter table doctor.user_active_tenant enable row level security;

-- Escrita só pelas funções abaixo: ninguém se vincula nem troca de tenant por escrita direta.
revoke all on doctor.memberships from anon, authenticated;
revoke all on doctor.user_active_tenant from anon, authenticated;
grant select on doctor.memberships to authenticated;
grant select on doctor.user_active_tenant to authenticated;

create policy memberships_select on doctor.memberships
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy user_active_tenant_select_own on doctor.user_active_tenant
for select to authenticated
using (user_id = (select auth.uid()));

-- security definer: supabase_auth_admin não lê estas tabelas, por causa do RLS. Só adiciona claims
-- de tenant, sempre preservando as demais: é o hook do projeto inteiro, incluindo o jayv-coder.
create function doctor.custom_access_token_hook(event jsonb)
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
begin
  select m.tenant_id, m.role into active_tenant, active_role
  from doctor.user_active_tenant a
  join doctor.memberships m on m.tenant_id = a.tenant_id and m.user_id = a.user_id
  join doctor.tenants t on t.id = m.tenant_id
  where a.user_id = (event ->> 'user_id')::uuid and t.status = 'active';

  if active_tenant is not null then
    claims := claims || jsonb_build_object('tenant_id', active_tenant, 'tenant_role', active_role);
  end if;
  return jsonb_set(event, '{claims}', claims);
exception when query_canceled or others then
  -- O hook vale para o projeto todo: um erro aqui derrubaria o login do jayv-coder. Sem as claims,
  -- o RLS do Doctor nega tudo, então falhar assim é seguro. `others` não cobre query_canceled.
  raise warning 'doctor.custom_access_token_hook: %', sqlstate;
  return event #- '{claims,tenant_id}' #- '{claims,tenant_role}';
end;
$$;

revoke all on function doctor.custom_access_token_hook(jsonb) from public, authenticated, service_role;
grant usage on schema doctor to supabase_auth_admin;
grant execute on function doctor.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- security definer: criar a Organização, o Vínculo Owner, o Papel e a Organização ativa é uma coisa
-- só. A criação em `public` é a do jayv-coder, que mantém as regras dele. Quem cria aceita o DPA.
create function doctor.create_organization(name text, slug text, segment text, llm_provider text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  user_id uuid := auth.uid();
  new_tenant uuid;
begin
  if user_id is null then
    raise insufficient_privilege using message = 'sessão obrigatória';
  end if;
  begin
    new_tenant := public.create_organization(name, slug);
  exception when raise_exception then
    if sqlerrm = 'org.slugTaken' then
      raise unique_violation using message = 'identificador em uso';
    end if;
    raise;
  end;
  insert into doctor.tenants (id, segment, llm_provider, dpa_accepted_at)
  values (new_tenant, segment, llm_provider, now());
  insert into doctor.memberships (tenant_id, user_id, role) values (new_tenant, user_id, 'owner');
  insert into doctor.user_active_tenant (user_id, tenant_id) values (user_id, new_tenant)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;
  return new_tenant;
end;
$$;

-- security definer: o `authenticated` não escreve em user_active_tenant.
create function doctor.switch_organization(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  user_id uuid := auth.uid();
begin
  if not exists (
    select 1 from doctor.memberships m
    join doctor.tenants t on t.id = m.tenant_id
    where m.tenant_id = target and m.user_id = auth.uid() and t.status = 'active'
  ) then
    raise insufficient_privilege using message = 'sem Vínculo com a Organização';
  end if;
  insert into doctor.user_active_tenant (user_id, tenant_id) values (user_id, target)
  on conflict on constraint user_active_tenant_pkey do update set tenant_id = excluded.tenant_id;
end;
$$;

-- security definer: o RLS mostra só a Organização ativa, e o seletor precisa das outras. Expõe
-- apenas o necessário para escolher, e só das Organizações do próprio Usuário.
create function doctor.list_organizations()
returns table (id uuid, name text, slug text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, o.name, o.slug, m.role
  from doctor.memberships m
  join doctor.tenants t on t.id = m.tenant_id
  join public.organizations o on o.id = t.id
  where m.user_id = auth.uid() and t.status = 'active'
$$;

revoke all on function doctor.list_organizations() from public, service_role;
grant execute on function doctor.list_organizations() to authenticated;

revoke all on function doctor.create_organization(text, text, text, text) from public, service_role;
revoke all on function doctor.switch_organization(uuid) from public, service_role;
grant execute on function doctor.create_organization(text, text, text, text) to authenticated;
grant execute on function doctor.switch_organization(uuid) to authenticated;
