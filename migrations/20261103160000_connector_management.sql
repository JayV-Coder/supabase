-- Ticket #14 (parte 2): gestão de Conectores pela API. Escrita só por funções, com o Papel lido da
-- tabela (Owner ou Admin com MFA), como as demais ações administrativas.

-- Conector da Organização ativa, travado; P0002 se não existe ou é de outra Organização.
create function doctor.managed_connector(target uuid)
returns doctor.connectors
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_row doctor.connectors;
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  select * into target_row from doctor.connectors c
  where c.id = target and c.tenant_id = doctor.current_tenant_id() for update;
  if not found then
    raise no_data_found using message = 'Conector não encontrado';
  end if;
  return target_row;
end;
$$;
revoke all on function doctor.managed_connector(uuid) from public, anon, authenticated, service_role;

create function doctor.update_connector(target uuid, name text, config jsonb, sync_interval_seconds integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  connector_row doctor.connectors := doctor.managed_connector(target);
begin
  update doctor.connectors c
  set name = coalesce(update_connector.name, c.name),
      config = coalesce(update_connector.config, c.config),
      sync_interval_seconds = coalesce(update_connector.sync_interval_seconds, c.sync_interval_seconds),
      -- Config nova: a próxima coleta recomeça do zero (a deduplicação cobre o que repetir).
      checkpoint = case when update_connector.config is null then c.checkpoint end,
      config_version = c.config_version + case when update_connector.config is null then 0 else 1 end
  where c.id = connector_row.id;
  perform doctor.record_audit(connector_row.tenant_id, 'connector.update', target::text);
end;
$$;

create function doctor.pause_connector(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  connector_row doctor.connectors := doctor.managed_connector(target);
begin
  if connector_row.status = 'disabled' then
    raise exception 'Conector desativado' using errcode = 'DR008';
  end if;
  update doctor.connectors set status = 'paused', paused_reason = 'manual' where id = connector_row.id;
  perform doctor.record_audit(connector_row.tenant_id, 'connector.pause', target::text);
end;
$$;

create function doctor.resume_connector(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  connector_row doctor.connectors := doctor.managed_connector(target);
begin
  if connector_row.status = 'disabled' then
    raise exception 'Conector desativado' using errcode = 'DR008';
  end if;
  update doctor.connectors
  set status = 'active', paused_reason = null, consecutive_failures = 0, next_run_at = now()
  where id = connector_row.id;
  perform doctor.record_audit(connector_row.tenant_id, 'connector.resume', target::text);
end;
$$;

-- Sincronização agora: vai direto para a outbox; o worker garante uma por vez.
create function doctor.request_connector_sync(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  connector_row doctor.connectors := doctor.managed_connector(target);
begin
  if connector_row.status in ('paused', 'disabled') then
    raise exception 'Conector pausado ou desativado' using errcode = 'DR007';
  end if;
  -- Com uma Sincronização em curso, o worker descartaria o pedido: melhor dizer agora.
  if exists (
    select 1 from doctor.connector_syncs s
    where s.tenant_id = connector_row.tenant_id and s.connector_id = connector_row.id
      and s.status = 'running' and s.started_at > now() - interval '10 minutes'
  ) then
    raise exception 'Sincronização em andamento' using errcode = 'DR009';
  end if;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (connector_row.tenant_id, 'connector.sync', jsonb_build_object('connector_id', connector_row.id));
end;
$$;

revoke all on function doctor.update_connector(uuid, text, jsonb, integer) from public, anon, service_role;
revoke all on function doctor.pause_connector(uuid) from public, anon, service_role;
revoke all on function doctor.resume_connector(uuid) from public, anon, service_role;
revoke all on function doctor.request_connector_sync(uuid) from public, anon, service_role;
grant execute on function doctor.update_connector(uuid, text, jsonb, integer) to authenticated;
grant execute on function doctor.pause_connector(uuid) to authenticated;
grant execute on function doctor.resume_connector(uuid) to authenticated;
grant execute on function doctor.request_connector_sync(uuid) to authenticated;

-- Motivo da pausa: credencial nova só reativa a pausa por erro de autenticação, nunca a manual.
alter table doctor.connectors
  add column paused_reason text check (paused_reason in ('auth', 'manual'));
-- Versão da config: a Sincronização que começou antes de uma config nova não grava Checkpoint
-- por cima do recomeço.
alter table doctor.connectors add column config_version integer not null default 0;

create or replace function doctor.put_connector_secret(target uuid, secret text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  connector_row doctor.connectors := doctor.managed_connector(target);
begin
  if connector_row.secret_id is null then
    update doctor.connectors
    set secret_id = vault.create_secret(secret, 'doctor/connector/' || target, 'Credencial de Conector do Doctor')
    where id = target;
  else
    perform vault.update_secret(connector_row.secret_id, secret);
  end if;
  update doctor.connectors
  set consecutive_failures = 0, last_error = null, next_run_at = now(),
      status = case when status = 'paused' and paused_reason = 'auth' then 'active' else status end,
      paused_reason = case when status = 'paused' and paused_reason = 'auth' then null else paused_reason end
  where id = target;
  perform doctor.record_audit(connector_row.tenant_id, 'connector.secret.update', target::text);
end;
$$;
