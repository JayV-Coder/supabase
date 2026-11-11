-- Trilha de auditoria completa (ticket #28). A tabela do #19 vira particionada por mês, ganha IP,
-- user agent e request id (o que a API passa em `doctor.request`), e é append-only de verdade:
-- update nunca, delete só pela retenção (#29). Triggers genéricos registram as mudanças das
-- tabelas sensíveis com `before` e `after` sem segredo nem dado pessoal.

alter table doctor.audit_logs rename to audit_logs_legacy;
alter index doctor.audit_logs_tenant_time_idx rename to audit_logs_legacy_tenant_time_idx;

create sequence doctor.audit_log_ids;
create table doctor.audit_logs (
  id bigint not null default nextval('doctor.audit_log_ids'),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  occurred_at timestamptz not null default now(),
  actor_type text not null check (actor_type in ('user', 'system', 'worker')),
  actor_id uuid,
  action text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  resource_type text,
  resource_id text,
  before jsonb,
  after jsonb,
  ip inet,
  user_agent text check (char_length(user_agent) <= 500),
  request_id text check (char_length(request_id) <= 200),
  -- Particionada: a chave inclui a partição (inventário do #27, exceção `keyless`).
  primary key (tenant_id, id, occurred_at)
) partition by range (occurred_at);
alter sequence doctor.audit_log_ids owned by doctor.audit_logs.id;
comment on table doctor.audit_logs is 'Trilha de auditoria (append-only, particionada por mês, retida por 365 dias).';
create index audit_logs_tenant_time_idx on doctor.audit_logs (tenant_id, occurred_at desc, id desc);
create index audit_logs_tenant_action_idx on doctor.audit_logs (tenant_id, action, occurred_at desc);
-- Importação dos eventos do Supabase Auth: o mesmo evento não entra duas vezes por Organização.
create unique index audit_logs_auth_event_idx on doctor.audit_logs (tenant_id, request_id, occurred_at)
  where action like 'auth.%';

-- Partições de 2026-10 a 2027-12 e a padrão (nada se perde se o mês ainda não existir); o job
-- diário cria as seguintes, numa transação curta, e a retenção (#29) apaga as vencidas. Como nas
-- de `events`, a partição nasce com RLS e sem privilégio nenhum (nem do service_role, que o
-- default privileges do schema daria): só se chega a ela pela tabela-mãe, append-only.
create function doctor.ensure_audit_partition(day date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  first_day date := date_trunc('month', day)::date;
  partition_name text := 'audit_logs_' || to_char(first_day, 'YYYY_MM');
begin
  if to_regclass(format('doctor.%I', partition_name)) is not null then
    return partition_name;
  end if;
  begin
    execute format(
      'create table doctor.%I partition of doctor.audit_logs for values from (%L) to (%L)',
      partition_name, first_day::text || ' 00:00:00+00',
      (first_day + interval '1 month')::date::text || ' 00:00:00+00'
    );
  exception
    when duplicate_table then
      return partition_name;
    -- O mês já tem registros na partição padrão (o job atrasou): eles ficam lá, e a criação é
    -- tentada de novo no mês seguinte, sem travar o resto do job.
    when check_violation then
      raise warning 'audit_logs: % já tem registros na partição padrão', partition_name;
      return null;
  end;
  perform doctor.lock_audit_partition(partition_name);
  return partition_name;
end;
$$;

create function doctor.lock_audit_partition(partition_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  execute format('alter table doctor.%I enable row level security', partition_name);
  execute format('revoke all on doctor.%I from public, anon, authenticated, service_role', partition_name);
end;
$$;
revoke all on function doctor.lock_audit_partition(text) from public, anon, authenticated, service_role;
revoke all on function doctor.ensure_audit_partition(date) from public, anon, authenticated;
grant execute on function doctor.ensure_audit_partition(date) to service_role;

create table doctor.audit_logs_default partition of doctor.audit_logs default;
select doctor.lock_audit_partition('audit_logs_default');
select doctor.ensure_audit_partition(month::date)
from generate_series('2026-10-01'::date, '2027-12-01'::date, interval '1 month') month;
-- Ponto de partida do job do Auth: o último evento importado, sem varrer a trilha inteira.
create index audit_logs_auth_time_idx on doctor.audit_logs (occurred_at desc) where action like 'auth.%';

insert into doctor.audit_logs (id, tenant_id, occurred_at, actor_type, actor_id, action,
  resource_type, resource_id, before, after, request_id)
select id, tenant_id, occurred_at, actor_type, actor_id, action, resource_type, resource_id,
  before, after, request_id
from doctor.audit_logs_legacy;
select setval('doctor.audit_log_ids', greatest((select max(id) from doctor.audit_logs), 1));
drop table doctor.audit_logs_legacy;

-- Append-only: update nunca; delete só com a retenção ligada na transação (`doctor.retention`)
-- ou pelo cascade da exclusão da própria Organização (LGPD, #29).
create function doctor.guard_audit_log()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and (
    current_setting('doctor.retention', true) = 'on'
    or not exists (select 1 from doctor.tenants t where t.id = old.tenant_id)
  ) then
    return old;
  end if;
  raise exception 'audit_logs é append-only' using errcode = 'DR030';
end;
$$;
revoke all on function doctor.guard_audit_log() from public;

create trigger audit_logs_append_only
before update or delete on doctor.audit_logs
for each row execute function doctor.guard_audit_log();

alter table doctor.audit_logs enable row level security;
revoke all on doctor.audit_logs from anon, authenticated;
revoke all on doctor.audit_logs from service_role;
-- Os workers gravam e leem (o job do Auth parte do último evento importado); nunca alteram.
grant select, insert on doctor.audit_logs to service_role;
grant usage on sequence doctor.audit_log_ids to service_role;
grant select on doctor.audit_logs to authenticated;
-- Owner e Admin, com MFA, da Organização ativa.
create policy audit_logs_select on doctor.audit_logs
for select to authenticated
using (
  tenant_id = (select doctor.current_tenant_id())
  and (select doctor.has_member_role('owner', 'admin'))
  and (select doctor.current_aal()) = 'aal2'
);

-- IP, user agent e request id vêm do que a API põe em `doctor.request` na transação; vale para
-- toda inserção (inclusive as funções que gravam direto na tabela).
create function doctor.fill_audit_request()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  meta jsonb;
begin
  if new.ip is not null or new.user_agent is not null or new.request_id is not null then
    return new;
  end if;
  begin
    meta := nullif(current_setting('doctor.request', true), '')::jsonb;
    new.ip := (meta ->> 'ip')::inet;
  exception when others then
    new.ip := null;
  end;
  new.user_agent := left(meta ->> 'user_agent', 500);
  new.request_id := left(meta ->> 'request_id', 200);
  return new;
end;
$$;
revoke all on function doctor.fill_audit_request() from public;

create trigger audit_logs_request
before insert on doctor.audit_logs
for each row execute function doctor.fill_audit_request();

-- Gravação única: o ator sai do JWT (Usuário), do papel da sessão (worker, como service_role) ou
-- é a plataforma.
create function doctor.write_audit(
  tenant uuid, action text, resource_type text, resource_id text, before jsonb, after jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into doctor.audit_logs (tenant_id, actor_type, actor_id, action, resource_type, resource_id,
    before, after)
  values (
    tenant,
    case
      when auth.uid() is not null then 'user'
      when current_setting('role', true) = 'service_role' then 'worker'
      else 'system'
    end,
    auth.uid(), action, resource_type, resource_id, before, after
  )
$$;
revoke all on function doctor.write_audit(uuid, text, text, text, jsonb, jsonb) from public;

-- As funções dos Conectores registravam criação, alteração, pausa e retomada à mão; o trigger
-- passou a registrar essas mesmas mudanças, com before e after, e as chamadas antigas não
-- duplicam mais o registro.
create or replace function doctor.record_audit(tenant uuid, action text, target text)
returns void
language sql
security definer
set search_path = ''
as $$
  select doctor.write_audit(tenant, action, split_part(action, '.', 1), target, null, null)
  where action not in ('connector.create', 'connector.update', 'connector.pause', 'connector.resume')
$$;
revoke all on function doctor.record_audit(uuid, text, text) from public;

-- Mudanças nas tabelas sensíveis. Argumentos do trigger: a entidade (`membership`) e as colunas
-- que não entram (segredo e dado pessoal de terceiros). No update, só o que mudou.
create function doctor.audit_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  entity text := tg_argv[0];
  hidden text[] := array['updated_at', 'created_at'] || coalesce(tg_argv[1:], '{}');
  old_row jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) - hidden end;
  new_row jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) - hidden end;
  source jsonb := coalesce(new_row, old_row);
  tenant uuid := coalesce(source ->> 'tenant_id', source ->> 'id')::uuid;
  changed_before jsonb;
  changed_after jsonb;
  verb text := case tg_op when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end;
begin
  -- Organização sendo apagada (cascade): não há onde gravar.
  if not exists (select 1 from doctor.tenants t where t.id = tenant) then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(key, old_row -> key), jsonb_object_agg(key, new_row -> key)
    into changed_before, changed_after
    from jsonb_object_keys(new_row) key
    where old_row -> key is distinct from new_row -> key;
    if changed_after is null then
      return null;
    end if;
    if entity = 'membership' and changed_after ? 'role' then
      verb := 'role_changed';
    elsif entity = 'connector' and changed_after ->> 'status' = 'paused' then
      verb := 'paused';
    elsif entity = 'connector' and changed_before ->> 'status' = 'paused' then
      verb := 'resumed';
    end if;
  else
    changed_before := old_row;
    changed_after := new_row;
  end if;
  perform doctor.write_audit(tenant, entity || '.' || verb, entity, source ->> 'id',
    changed_before, changed_after);
  return null;
end;
$$;
revoke all on function doctor.audit_change() from public;

create trigger memberships_audit after insert or update or delete on doctor.memberships
for each row execute function doctor.audit_change('membership');
create trigger invitations_audit after insert or update or delete on doctor.invitations
for each row execute function doctor.audit_change('invitation', 'email', 'token_hash');
-- Do Conector, só o que a pessoa muda: o que o worker atualiza a cada Sincronização (checkpoint,
-- próxima rodada, falhas seguidas, último erro) não é auditado, nem a referência da credencial.
create trigger connectors_audit after insert or update or delete on doctor.connectors
for each row execute function doctor.audit_change('connector', 'secret_id', 'checkpoint',
  'next_run_at', 'last_sync_at', 'consecutive_failures', 'last_error');
create trigger integrations_audit after insert or update or delete on doctor.integrations
for each row execute function doctor.audit_change('integration');
-- O Diagnóstico automático já tem o próprio registro (`diagnosis.auto_changed`).
create trigger tenants_audit after update on doctor.tenants
for each row execute function doctor.audit_change('org', 'auto_diagnose_critical');

-- Troca de Organização ativa: auditada na Organização de destino.
create or replace function doctor.switch_organization(target uuid)
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
  perform doctor.write_audit(target, 'org.switched', 'org', target::text, null, null);
end;
$$;

-- Leitura da credencial pelo worker (Vault): `vault.secret_read`, com o worker como ator.
create or replace function doctor.get_connector_secret(target uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid;
  value text;
begin
  select c.tenant_id, s.decrypted_secret into tenant, value
  from doctor.connectors c join vault.decrypted_secrets s on s.id = c.secret_id
  where c.id = target;
  if tenant is null then
    raise no_data_found using message = 'Conector sem credencial';
  end if;
  perform doctor.write_audit(tenant, 'vault.secret_read', 'connector', target::text, null, null);
  return value;
end;
$$;

-- Login, logout e MFA do Supabase Auth, copiados para cada Organização do Usuário (job diário do
-- worker de correlação). Só o que é do Doctor: o projeto é compartilhado com o jayv-coder.
create function doctor.import_auth_events(since timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  imported integer;
begin
  insert into doctor.audit_logs (tenant_id, occurred_at, actor_type, actor_id, action, resource_type,
    resource_id, ip, request_id)
  select m.tenant_id, e.created_at, 'user', (e.payload ->> 'actor_id')::uuid,
    case e.payload ->> 'action'
      when 'login' then 'auth.login'
      when 'logout' then 'auth.logout'
      when 'user_recovery_requested' then 'auth.recovery_requested'
      when 'user_updated_password' then 'auth.password_changed'
      when 'factor_in_progress' then 'auth.mfa_enrolling'
      when 'factor_verified' then 'auth.mfa_enrolled'
      when 'factor_unenrolled' then 'auth.mfa_removed'
      when 'mfa_code_login' then 'auth.mfa_verified'
    end,
    'auth', e.payload ->> 'actor_id',
    case when e.ip_address ~ '^[0-9a-fA-F.:]+$' then e.ip_address::inet end,
    e.id::text
  from auth.audit_log_entries e
  join doctor.memberships m on m.user_id = (e.payload ->> 'actor_id')::uuid
  where e.created_at > since
    and e.payload ->> 'action' in ('login', 'logout', 'user_recovery_requested',
      'user_updated_password', 'factor_in_progress', 'factor_verified', 'factor_unenrolled',
      'mfa_code_login')
    and (e.payload ->> 'actor_id') ~ '^[0-9a-f-]{36}$'
  on conflict (tenant_id, request_id, occurred_at) where action like 'auth.%' do nothing;
  get diagnostics imported = row_count;
  return imported;
end;
$$;
revoke all on function doctor.import_auth_events(timestamptz) from public, anon, authenticated;
grant execute on function doctor.import_auth_events(timestamptz) to service_role;

-- Rótulo dos atores na Tela 18: o e-mail de cada Usuário da Organização ativa, resolvido na
-- leitura (o registro guarda só o id). Owner ou Admin com MFA, como a própria trilha.
create function doctor.list_audit_actors()
returns table (user_id uuid, email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  return query
    select m.user_id, u.email::text
    from doctor.memberships m
    join auth.users u on u.id = m.user_id
    where m.tenant_id = doctor.current_tenant_id();
end;
$$;
revoke all on function doctor.list_audit_actors() from public, anon, service_role;
grant execute on function doctor.list_audit_actors() to authenticated;

-- A exportação da trilha também é auditada, com os filtros (sem o termo de busca, que pode ser um
-- e-mail).
create function doctor.record_audit_export(filters jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  perform doctor.write_audit(doctor.current_tenant_id(), 'audit.exported', 'audit', null, null, filters);
end;
$$;
revoke all on function doctor.record_audit_export(jsonb) from public, anon, service_role;
grant execute on function doctor.record_audit_export(jsonb) to authenticated;
