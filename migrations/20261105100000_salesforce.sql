-- Ticket #37: o limite diário de API do provedor (Salesforce a 80%) adia a próxima rodada para
-- depois da janela (`next_run_at`), sem mudar o status nem contar falha. `api_limit` em
-- `paused_reason` só explica na tela por que o Conector está esperando.
alter table doctor.connectors drop constraint connectors_paused_reason_check;
alter table doctor.connectors
  add constraint connectors_paused_reason_check
  check (paused_reason in ('auth', 'manual', 'api_limit'));

-- Credencial nova reativa a pausa por autenticação já, mas não encurta a janela do limite de API:
-- rodar antes dela gastaria a cota que a pausa protege.
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
  set consecutive_failures = 0, last_error = null,
      next_run_at = case when paused_reason = 'api_limit' then next_run_at else now() end,
      status = case when status = 'paused' and paused_reason = 'auth' then 'active' else status end,
      paused_reason = case when status = 'paused' and paused_reason = 'auth' then null else paused_reason end
  where id = target;
  perform doctor.record_audit(connector_row.tenant_id, 'connector.secret.update', target::text);
end;
$$;
