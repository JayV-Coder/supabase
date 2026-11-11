-- Explorador de Execuções (ticket #19): índices da lista e da busca, e o download auditado do
-- Log bruto.

-- Lista: as mais recentes da Organização, sem as fundidas, na ordem do cursor.
create index executions_list_idx on doctor.executions (tenant_id, first_event_at desc, id desc)
  where merged_into is null;
-- Busca por execution_id, trace_id ou Referência (HMAC) com `correlation_keys @> …`.
create index executions_keys_idx on doctor.executions using gin (correlation_keys jsonb_path_ops);

-- Trilha de auditoria, no formato do ticket #28 (que traz os triggers, a tela e a partição por
-- mês). Append-only: nenhum papel altera nem apaga (a retenção do #28 terá a sua exceção). Por
-- isso não segue a convenção de `updated_at`.
create table doctor.audit_logs (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  occurred_at timestamptz not null default now(),
  actor_type text not null check (actor_type in ('user', 'system', 'worker')),
  actor_id uuid,
  action text not null,
  resource_type text,
  resource_id text,
  before jsonb,
  after jsonb,
  request_id text,
  unique (tenant_id, id)
);
comment on table doctor.audit_logs is 'Trilha de auditoria (append-only).';
create index audit_logs_tenant_time_idx on doctor.audit_logs (tenant_id, occurred_at desc);
alter table doctor.audit_logs enable row level security;
revoke all on doctor.audit_logs from anon, authenticated;
revoke update, delete, truncate on doctor.audit_logs from service_role;

-- O stub do ticket #14 passa a gravar: quem chamou (o Usuário do JWT ou a plataforma) e o quê.
create or replace function doctor.record_audit(tenant uuid, action text, target text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into doctor.audit_logs (tenant_id, actor_type, actor_id, action, resource_type, resource_id)
  values (
    tenant,
    case when auth.uid() is null then 'system' else 'user' end,
    auth.uid(),
    record_audit.action,
    split_part(record_audit.action, '.', 1),
    target
  );
end;
$$;
revoke all on function doctor.record_audit(uuid, text, text) from public;

-- Download do Log bruto: Analyst ou acima (o Viewer não baixa), auditado. A URL assinada sai do
-- Storage com o JWT do próprio Usuário, e a política do bucket repete a regra do Papel.
create function doctor.request_raw_log_download(target uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  path text;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  select r.storage_path into path
  from doctor.raw_log_objects r
  where r.tenant_id = tenant and r.id = target and r.expires_at > now();
  if path is null then
    raise no_data_found using message = 'Log bruto não encontrado ou vencido';
  end if;
  perform doctor.record_audit(tenant, 'raw_log.downloaded', target::text);
  return path;
end;
$$;

revoke all on function doctor.request_raw_log_download(uuid) from public, service_role;
grant execute on function doctor.request_raw_log_download(uuid) to authenticated;
