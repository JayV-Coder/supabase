-- Ticket #4: MFA obrigatório em ações administrativas. O perfil é o de public.profiles (ADR-0009).

-- Nível de garantia da sessão: aal1 (senha, link, OAuth) ou aal2 (MFA verificado).
create function doctor.current_aal()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'aal', '')
$$;

revoke all on function doctor.current_aal() from public;
grant execute on function doctor.current_aal() to authenticated, service_role;

-- Owner e Admin só administram com MFA verificado.
alter policy tenants_update_by_admin on doctor.tenants
using (
  id = (select doctor.current_tenant_id())
  and (select doctor.has_role('owner', 'admin'))
  and (select doctor.current_aal()) = 'aal2'
);
