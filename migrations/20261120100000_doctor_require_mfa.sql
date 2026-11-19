-- #49 (Políticas avançadas), MFA obrigatório para todos os Papéis. Com a política ligada na
-- Organização, sessão sem o segundo fator (aal1) não lê nem grava nada dela: a regra fica em
-- `doctor.current_tenant_id()`, o mesmo ponto do Vínculo (ADR-0026), e vale para a API, as
-- leituras diretas do site e o Realtime. Quem age sem Usuário (os workers) segue como antes.

alter table doctor.tenants add column require_mfa boolean not null default false;
comment on column doctor.tenants.require_mfa is
  'Exige o segundo fator (aal2) de todos os Papéis para ler e gravar na Organização (#49).';

-- Por que quem pede não acessa a Organização: nulo se acessa; `no_membership` sem Vínculo;
-- `mfa_required` se a Organização exige MFA e a sessão não o tem.
create function doctor.tenant_access(tenant uuid, member uuid, aal text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (
      select 1 from doctor.memberships m where m.tenant_id = tenant and m.user_id = member
    ) then 'no_membership'
    when aal is distinct from 'aal2' and exists (
      select 1 from doctor.tenants t where t.id = tenant and t.require_mfa
    ) then 'mfa_required'
  end
$$;

create or replace function doctor.current_tenant_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select case
    when claim.tenant is null then null
    when auth.uid() is null then claim.tenant
    when doctor.tenant_access(claim.tenant, auth.uid(), doctor.current_aal()) is null then claim.tenant
  end
  from (select nullif(auth.jwt() ->> 'tenant_id', '')::uuid as tenant) claim
$$;

-- O motivo para a Organização do JWT de quem pede (a API e o site o mostram).
create function doctor.access_problem()
returns text
language sql
stable
set search_path = ''
as $$
  select case when claim.tenant is not null and auth.uid() is not null
    then doctor.tenant_access(claim.tenant, auth.uid(), doctor.current_aal()) end
  from (select nullif(auth.jwt() ->> 'tenant_id', '')::uuid as tenant) claim
$$;

-- Liga ou desliga a política: Owner ou Admin com MFA (`require_manager`); o trigger de
-- auditoria de `tenants` registra a mudança.
create function doctor.set_require_mfa(enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  update doctor.tenants t set require_mfa = enabled where t.id = doctor.current_tenant_id();
end;
$$;

-- As leituras diretas dizem por que não leram: DR102 é "falta o MFA".
create or replace function doctor.read_tenant()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  if tenant is null then
    if doctor.access_problem() is not distinct from 'mfa_required' then
      raise exception 'a Organização exige verificação em duas etapas' using errcode = 'DR102';
    end if;
    raise exception 'sem Organização ativa' using errcode = 'DR100';
  end if;
  return tenant;
end;
$$;

create or replace function doctor_read.me()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  active uuid;
begin
  if auth.uid() is null then
    raise insufficient_privilege using message = 'sessão obrigatória';
  end if;
  begin
    perform doctor.join_organizations();
  exception when others then
    raise warning 'doctor_read.me: acesso automático falhou: %', sqlstate;
  end;
  active := doctor.current_tenant_id();
  return jsonb_build_object(
    'id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'aal', auth.jwt() ->> 'aal',
    'profile', (
      select jsonb_build_object('full_name', p.display_name, 'avatar_url', p.avatar_url, 'locale', 'pt-BR')
      from public.profiles p where p.user_id = auth.uid()
    ),
    'organizations', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug, 'role', o.role) order by o.name)
      from doctor.list_organizations() o
    ), '[]'::jsonb),
    'available_organizations', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'slug', a.slug, 'coder_role', a.coder_role) order by a.name)
      from doctor.available_organizations() a
    ), '[]'::jsonb),
    'active_tenant_id', active,
    'active_role', case when active is not null then auth.jwt() ->> 'tenant_role' end,
    -- A Organização do JWT exige MFA e esta sessão não o tem: o site manda configurar.
    'mfa_required', doctor.access_problem() is not distinct from 'mfa_required'
  );
end;
$$;

revoke all on function doctor.tenant_access(uuid, uuid, text) from public, anon;
grant execute on function doctor.tenant_access(uuid, uuid, text) to authenticated, service_role;
revoke all on function doctor.access_problem() from public, anon;
grant execute on function doctor.access_problem() to authenticated, service_role;
revoke all on function doctor.set_require_mfa(boolean) from public, anon, service_role;
grant execute on function doctor.set_require_mfa(boolean) to authenticated;
