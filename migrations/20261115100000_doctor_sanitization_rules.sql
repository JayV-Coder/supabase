-- Ticket #13: regras de Sanitização por Organização. O Sanitizer (`packages/security`) já aceita
-- padrões extras e a liberação dos IPs internos; aqui eles passam a ser configuráveis por
-- Organização, e o worker de ingestão os aplica antes de gravar o Evento.
--
-- Os padrões são conferidos na API (expressão válida, sem quantificador aninhado, não casa com
-- texto vazio) antes de chegar aqui; o banco garante a forma e os limites. O worker ignora um
-- padrão que não compile, para uma regra ruim não parar a ingestão.

create table doctor.sanitization_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  -- tipo → padrão; o tipo vira o marcador `[REMOVIDO:<tipo>]`.
  extra_patterns jsonb not null default '{}' check (jsonb_typeof(extra_patterns) = 'object'),
  detect_ips boolean not null default true,
  -- IPs de redes privadas (10/8, 172.16/12, 192.168/16, loopback) ficam no Evento.
  allow_private_ips boolean not null default false,
  updated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  -- Uma configuração por Organização.
  unique (tenant_id)
);
comment on table doctor.sanitization_rules is 'Padrões extras de Sanitização e tratamento de IPs da Organização (#13).';

create trigger sanitization_rules_set_updated_at
before update on doctor.sanitization_rules
for each row execute function doctor.set_updated_at();

alter table doctor.sanitization_rules enable row level security;
revoke all on doctor.sanitization_rules from anon, authenticated;
grant select (id, tenant_id, extra_patterns, detect_ips, allow_private_ips, updated_at)
  on doctor.sanitization_rules to authenticated;
create policy sanitization_rules_select on doctor.sanitization_rules
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create function doctor.set_sanitization_rules(patterns jsonb, detect_ips boolean, allow_private_ips boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid;
  previous jsonb;
  item record;
begin
  perform doctor.require_manager();
  tenant := doctor.current_tenant_id();
  if jsonb_typeof(patterns) is distinct from 'object' then
    raise exception 'padrões: objeto tipo → padrão' using errcode = '22023';
  end if;
  if (select count(*) from jsonb_object_keys(patterns)) > 20 then
    raise exception 'até 20 padrões' using errcode = '22023';
  end if;
  for item in select key, value from jsonb_each(patterns) loop
    if item.key !~ '^[a-z][a-z0-9_]{1,30}$' then
      raise exception 'tipo inválido: %', left(item.key, 40) using errcode = '22023';
    end if;
    if jsonb_typeof(item.value) <> 'string' or char_length(item.value #>> '{}') not between 1 and 200 then
      raise exception 'padrão de % com 1 a 200 caracteres', item.key using errcode = '22023';
    end if;
  end loop;

  select to_jsonb(r) - 'id' - 'tenant_id' - 'created_at' - 'updated_at' - 'updated_by' into previous
  from doctor.sanitization_rules r where r.tenant_id = tenant;
  insert into doctor.sanitization_rules (tenant_id, extra_patterns, detect_ips, allow_private_ips, updated_by)
  values (tenant, patterns, set_sanitization_rules.detect_ips, set_sanitization_rules.allow_private_ips, auth.uid())
  on conflict (tenant_id) do update
  set extra_patterns = excluded.extra_patterns, detect_ips = excluded.detect_ips,
    allow_private_ips = excluded.allow_private_ips, updated_by = excluded.updated_by;
  perform doctor.write_audit(tenant, 'org.sanitization_rules_changed', 'org', tenant::text, previous,
    jsonb_build_object('extra_patterns', patterns, 'detect_ips', set_sanitization_rules.detect_ips,
      'allow_private_ips', set_sanitization_rules.allow_private_ips));
end;
$$;

revoke all on function doctor.set_sanitization_rules(jsonb, boolean, boolean) from public, anon, service_role;
grant execute on function doctor.set_sanitization_rules(jsonb, boolean, boolean) to authenticated;
-- O worker de ingestão lê as regras como plataforma.
grant select on doctor.sanitization_rules to service_role;
