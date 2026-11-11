-- Ticket #44: ServiceNow. A Organização registra um app OAuth na própria instância (client
-- credentials) e informa a instância, o client id e o secret; as credenciais vão para o Vault
-- e só o worker `notifier` as usa. O chamado é um `incident` da Table API, no mesmo modelo
-- `incident_tickets` do Jira (#43): um por Incidente e provedor. O grupo de atendimento sai do
-- Sistema responsável do Diagnóstico, por uma regra da Organização, com grupo padrão quando é
-- "Indeterminado". O status volta por uma Business Rule (ou Outbound REST) do cliente que chama
-- o nosso webhook, que só dispara a leitura pela Table API.

alter table doctor.itsm_connections drop constraint itsm_connections_provider_check;
alter table doctor.itsm_connections
  add constraint itsm_connections_provider_check check (provider in ('jira', 'servicenow'));
-- Só instâncias da ServiceNow: o endereço não aponta para a rede interna de ninguém.
alter table doctor.itsm_connections add column instance_url text
  check (instance_url ~ '^https://[a-z0-9][a-z0-9-]{0,62}\.service-now\.com$');
alter table doctor.itsm_connections add column client_id text
  check (char_length(client_id) between 1 and 200);
-- Severidade → impact e urgency do ServiceNow (1 alto, 3 baixo).
alter table doctor.itsm_connections add column impact_map jsonb not null default
  '{"critical": {"impact": 1, "urgency": 1}, "high": {"impact": 2, "urgency": 1},
    "medium": {"impact": 2, "urgency": 2}, "low": {"impact": 3, "urgency": 3}}'
  check (jsonb_typeof(impact_map) = 'object');
-- Sistema responsável → grupo de atendimento (nome ou sys_id): {"sap": "SAP Basis", ...}.
alter table doctor.itsm_connections add column assignment_groups jsonb not null default '{}'
  check (jsonb_typeof(assignment_groups) = 'object');
alter table doctor.itsm_connections add column default_group text
  check (char_length(btrim(default_group)) between 1 and 100);
grant select (instance_url, client_id, impact_map, assignment_groups, default_group)
  on doctor.itsm_connections to authenticated;
comment on table doctor.itsm_connections is 'Conexão da Organização com um ITSM (Jira Service Management ou ServiceNow).';

alter table doctor.incident_tickets drop constraint incident_tickets_provider_check;
alter table doctor.incident_tickets
  add constraint incident_tickets_provider_check check (provider in ('jira', 'servicenow'));
alter table doctor.incident_tickets drop constraint incident_tickets_external_key_check;
-- Chave do Jira (SUST-881) ou número do ServiceNow (INC0012345).
alter table doctor.incident_tickets add constraint incident_tickets_external_key_check
  check (external_key ~ '^[A-Z][A-Z0-9_]{1,19}-[0-9]{1,10}$' or external_key ~ '^[A-Z]{2,8}[0-9]{7,12}$');
-- Para onde o chamado foi (o grupo do ServiceNow), para a tela e o histórico.
alter table doctor.incident_tickets add column assignment_group text
  check (char_length(assignment_group) <= 100);
comment on table doctor.incident_tickets is 'Chamado de ITSM de um Incidente, com o status que vem do Jira ou do ServiceNow.';

-- O canal `servicenow` numa Regra de alerta abre o incident do Incidente.
alter table doctor.notification_channels drop constraint notification_channels_type_check;
alter table doctor.notification_channels add constraint notification_channels_type_check
  check (type in ('email', 'slack', 'teams', 'webpush', 'jira', 'servicenow'));

-- Reserva do chamado por provedor (o Jira continua o padrão de quem já chamava sem ele).
drop function doctor.request_ticket(uuid);
drop function doctor.queue_ticket(uuid, uuid, uuid, uuid);

create function doctor.queue_ticket(tenant uuid, incident uuid, requester uuid, rule uuid,
  provider text default 'jira')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
begin
  if not exists (select 1 from doctor.itsm_connections c
      where c.tenant_id = tenant and c.provider = queue_ticket.provider and c.status = 'active'
        and (c.project_key is not null or c.instance_url is not null)) then
    raise exception 'ITSM não configurado' using errcode = 'DR080';
  end if;
  insert into doctor.incident_tickets (tenant_id, incident_id, provider, requested_by, rule_id)
  values (tenant, incident, queue_ticket.provider, requester, rule)
  on conflict on constraint incident_tickets_tenant_id_incident_id_provider_key do nothing
  returning id into created;
  if created is null then
    -- Falhou antes: pedir de novo tenta outra vez.
    update doctor.incident_tickets t set status = 'creating', error = null, claimed_at = null
    where t.tenant_id = tenant and t.incident_id = incident and t.provider = queue_ticket.provider
      and t.status = 'failed'
    returning id into created;
  end if;
  if created is not null then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (tenant, 'itsm.ticket', jsonb_build_object('ticket_id', created));
  end if;
  return created;
end;
$$;

create function doctor.request_ticket(target uuid, provider text default 'jira')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  -- Papel lido da tabela, não do JWT (a claim pode estar atrasada depois de um rebaixamento).
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  if not exists (select 1 from doctor.incidents i where i.id = target and i.tenant_id = tenant) then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  perform doctor.record_audit(tenant, 'itsm.ticket.request', target::text);
  return doctor.queue_ticket(tenant, target, auth.uid(), null, request_ticket.provider);
end;
$$;

-- Configuração do ServiceNow (Owner ou Admin com MFA). O secret só é exigido na primeira vez ou
-- quando a instância ou o client id mudam (o secret de uma instância não vai para outra). O
-- token do endereço do webhook é novo só quando a API o manda (primeira vez, instância nova ou
-- "gerar outro"): o banco guarda só o hash, e a API o mostra uma vez para a Business Rule.
-- `impact_map` nulo mantém o atual (a tela não o edita).
create function doctor.configure_servicenow(
  instance_url text, client_id text, client_secret text, impact_map jsonb,
  assignment_groups jsonb, default_group text, sync_status boolean, hook_token text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  found doctor.itsm_connections;
  secret jsonb;
begin
  perform doctor.require_manager();
  if exists (select 1 from jsonb_each(configure_servicenow.assignment_groups) g
      where g.key not in ('sap', 'salesforce', 'gcp', 'other') or jsonb_typeof(g.value) <> 'string'
        or char_length(btrim(g.value #>> '{}')) not between 1 and 100) then
    raise exception 'grupos: sap, salesforce, gcp ou other, com o nome do grupo' using errcode = 'DR083';
  end if;
  select * into found from doctor.itsm_connections c
  where c.tenant_id = tenant and c.provider = 'servicenow' for update;
  if configure_servicenow.client_secret is null and (found.id is null
      or found.instance_url is distinct from configure_servicenow.instance_url
      or found.client_id is distinct from configure_servicenow.client_id) then
    raise exception 'informe o client secret' using errcode = 'DR084';
  end if;
  -- A API manda o token quando vê a conexão nova ou a instância trocada; duas configurações ao
  -- mesmo tempo podem discordar disso, e a segunda tenta de novo.
  if configure_servicenow.hook_token is null and (found.id is null
      or found.instance_url is distinct from configure_servicenow.instance_url) then
    raise exception 'a configuração mudou ao mesmo tempo' using errcode = 'DR085';
  end if;
  -- Instância nova: os chamados abertos apontam para a antiga (sys_id, número e link). Viram
  -- `failed` com o motivo e podem ser abertos de novo na instância nova.
  if found.id is not null and found.instance_url is distinct from configure_servicenow.instance_url then
    update doctor.incident_tickets t set status = 'failed',
      error = 'A instância do ServiceNow mudou: abra o chamado de novo.'
    where t.tenant_id = tenant and t.provider = 'servicenow' and t.status in ('creating', 'open');
  end if;
  if found.id is null then
    insert into doctor.itsm_connections (tenant_id, provider, secret_id, created_by)
    values (tenant, 'servicenow', vault.create_secret('{}', 'doctor/itsm-servicenow/' || tenant,
      'Credenciais do ServiceNow do Doctor'), auth.uid())
    returning * into found;
  end if;
  if configure_servicenow.client_secret is not null then
    select coalesce(s.decrypted_secret, '{}')::jsonb into secret
    from vault.decrypted_secrets s where s.id = found.secret_id;
    perform vault.update_secret(found.secret_id, (coalesce(secret, '{}'::jsonb)
      || jsonb_build_object('client_secret', configure_servicenow.client_secret)
      - 'access_token' - 'expires_at')::text);
  end if;
  update doctor.itsm_connections c set instance_url = configure_servicenow.instance_url,
    client_id = configure_servicenow.client_id,
    impact_map = coalesce(configure_servicenow.impact_map, c.impact_map),
    assignment_groups = configure_servicenow.assignment_groups,
    default_group = nullif(btrim(configure_servicenow.default_group), ''),
    sync_status = configure_servicenow.sync_status,
    hook_token_hash = coalesce(encode(sha256(convert_to(configure_servicenow.hook_token, 'UTF8')), 'hex'),
      c.hook_token_hash),
    status = 'active', last_error = null
  where c.id = found.id;
  -- O `notifier` confere as credenciais pedindo um token (falhou: `needs_reauth` com o motivo).
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'itsm.sync',
    jsonb_build_object('connection_id', found.id, 'provider', 'servicenow', 'check', true));
  perform doctor.record_audit(tenant, 'itsm.configure', found.id::text);
  return found.id;
end;
$$;

create function doctor.disconnect_servicenow()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  -- As credenciais saem do Vault pelo trigger `itsm_connections_drop_secret`.
  delete from doctor.itsm_connections c where c.tenant_id = tenant and c.provider = 'servicenow';
  perform doctor.record_audit(tenant, 'itsm.disconnect', tenant::text);
end;
$$;

-- Webhook do ServiceNow (Business Rule do cliente, sem sessão, como `anon`): o token do
-- endereço identifica a conexão e o número do incident diz qual chamado reler.
create function doctor.servicenow_hook(token_hash text, number text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  found doctor.itsm_connections;
  wanted jsonb;
begin
  select * into found from doctor.itsm_connections c
  where c.hook_token_hash = servicenow_hook.token_hash and c.provider = 'servicenow'
    and c.status = 'active' and c.sync_status;
  if found.id is null then
    return false;
  end if;
  wanted := jsonb_build_object('connection_id', found.id, 'provider', 'servicenow',
    'issue_key', case when servicenow_hook.number ~ '^[A-Z]{2,8}[0-9]{7,12}$'
      then servicenow_hook.number end);
  if not exists (
    select 1 from doctor.outbox_messages o
    where o.published_at is null and o.tenant_id = found.tenant_id and o.topic = 'itsm.sync'
      and o.payload = wanted
  ) then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (found.tenant_id, 'itsm.sync', wanted);
  end if;
  return true;
end;
$$;

-- Os tokens dos dois webhooks dividem a coluna `hook_token_hash`: o do Jira só aceita o do Jira.
create or replace function doctor.jira_hook(token_hash text, issue_key text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  found doctor.itsm_connections;
  wanted jsonb;
begin
  select * into found from doctor.itsm_connections c
  where c.hook_token_hash = jira_hook.token_hash and c.provider = 'jira'
    and c.status = 'active' and c.sync_status;
  if found.id is null then
    return false;
  end if;
  wanted := jsonb_build_object('connection_id', found.id, 'provider', 'jira',
    'issue_key', case when jira_hook.issue_key ~ '^[A-Z][A-Z0-9_]{1,19}-[0-9]{1,10}$'
      then jira_hook.issue_key end);
  if not exists (
    select 1 from doctor.outbox_messages o
    where o.published_at is null and o.tenant_id = found.tenant_id and o.topic = 'itsm.sync'
      and o.payload = wanted
  ) then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (found.tenant_id, 'itsm.sync', wanted);
  end if;
  return true;
end;
$$;

-- `#jira` só vai para o chamado do Jira.
create or replace function doctor.queue_comment_to_jira()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.external_id is null and new.body_md ~* '^#jira\s' and exists (
      select 1 from doctor.incident_tickets t
      where t.tenant_id = new.tenant_id and t.incident_id = new.incident_id and t.provider = 'jira'
        and t.status in ('open', 'done')) then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (new.tenant_id, 'itsm.comment', jsonb_build_object('comment_id', new.id));
  end if;
  return new;
end;
$$;

revoke all on function doctor.queue_ticket(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function doctor.request_ticket(uuid, text) from public, anon, service_role;
revoke all on function doctor.configure_servicenow(text, text, text, jsonb, jsonb, text, boolean, text) from public, anon, service_role;
revoke all on function doctor.disconnect_servicenow() from public, anon, service_role;
revoke all on function doctor.servicenow_hook(text, text) from public, service_role;
grant execute on function doctor.queue_ticket(uuid, uuid, uuid, uuid, text) to service_role;
grant execute on function doctor.request_ticket(uuid, text) to authenticated;
grant execute on function doctor.configure_servicenow(text, text, text, jsonb, jsonb, text, boolean, text) to authenticated;
grant execute on function doctor.disconnect_servicenow() to authenticated;
grant execute on function doctor.servicenow_hook(text, text) to anon;
