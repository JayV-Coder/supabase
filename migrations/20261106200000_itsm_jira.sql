-- Ticket #43: Jira Service Management. A Organização autoriza o app da plataforma no Atlassian
-- (OAuth 2.0 3LO); os tokens vão para o Vault e só o worker `notifier` os lê. Chamado aberto à
-- mão ("Abrir chamado no Jira") ou por Regra de alerta, uma vez por Incidente
-- (`incident_tickets`, único por Incidente e provedor). O status e os comentários com prefixo
-- voltam do Jira: o webhook do Jira só dispara a leitura pela API, com os tokens da Organização.

create table doctor.itsm_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  provider text not null default 'jira' check (provider = 'jira'),
  status text not null default 'pending' check (status in ('pending', 'active', 'needs_reauth')),
  -- Sites do Atlassian que a autorização alcança: [{id, name, url}].
  sites jsonb not null default '[]' check (jsonb_typeof(sites) = 'array'),
  cloud_id text check (char_length(cloud_id) <= 64),
  site_url text check (site_url ~ '^https://' and char_length(site_url) <= 200),
  project_key text check (project_key ~ '^[A-Z][A-Z0-9_]{1,19}$'),
  issue_type text check (char_length(btrim(issue_type)) between 1 and 60),
  -- Severidade → prioridade do Jira: {"critical": "Highest", ...}.
  priority_map jsonb not null default '{"critical": "Highest", "high": "High", "medium": "Medium", "low": "Low"}'
    check (jsonb_typeof(priority_map) = 'object'),
  -- Campos customizados com valor fixo: {"customfield_10010": "valor"}.
  custom_fields jsonb not null default '{}' check (jsonb_typeof(custom_fields) = 'object'),
  sync_status boolean not null default true,
  secret_id uuid,
  -- Webhook dinâmico do Jira (vence em 30 dias; a varredura renova) e o token do endereço.
  jira_webhook_id bigint,
  jira_webhook_expires_at timestamptz,
  hook_token_hash text check (hook_token_hash ~ '^[0-9a-f]{64}$'),
  last_error text check (char_length(last_error) <= 500),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, provider),
  unique (hook_token_hash)
);
comment on table doctor.itsm_connections is 'Conexão da Organização com um ITSM (Jira Service Management).';

create trigger itsm_connections_set_updated_at
before update on doctor.itsm_connections
for each row execute function doctor.set_updated_at();

alter table doctor.itsm_connections enable row level security;
revoke all on doctor.itsm_connections from anon, authenticated;
grant select (id, tenant_id, provider, status, sites, cloud_id, site_url, project_key, issue_type,
  priority_map, custom_fields, sync_status, jira_webhook_expires_at, last_error, created_at, updated_at)
  on doctor.itsm_connections to authenticated;
create policy itsm_connections_select on doctor.itsm_connections
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- `state` do OAuth: liga a volta do Atlassian à Organização e ao Usuário que pediu; uso único,
-- 10 minutos.
create table doctor.itsm_oauth_states (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  state_hash text not null unique check (state_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at timestamptz,
  created_at timestamptz not null default now(),
  unique (tenant_id, id)
);
alter table doctor.itsm_oauth_states enable row level security;
revoke all on doctor.itsm_oauth_states from anon, authenticated;

create table doctor.incident_tickets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  provider text not null default 'jira' check (provider = 'jira'),
  status text not null default 'creating' check (status in ('creating', 'open', 'done', 'failed')),
  external_key text check (external_key ~ '^[A-Z][A-Z0-9_]{1,19}-[0-9]{1,10}$'),
  external_id text check (char_length(external_id) <= 32),
  url text check (url ~ '^https://' and char_length(url) <= 300),
  external_status text check (char_length(external_status) <= 80),
  error text check (char_length(error) <= 500),
  requested_by uuid references auth.users (id) on delete set null,
  -- Regra de alerta que abriu (automático) ou nulo (à mão).
  rule_id uuid,
  -- Reserva da tentativa de criação (vence em 5 min: o worker pode cair no meio).
  claimed_at timestamptz,
  last_synced_at timestamptz,
  comments_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  -- Idempotência por Incidente: um chamado por provedor, à mão ou por Regra.
  unique (tenant_id, incident_id, provider),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade,
  foreign key (tenant_id, rule_id) references doctor.alert_rules (tenant_id, id) on delete set null (rule_id)
);
comment on table doctor.incident_tickets is 'Chamado de ITSM de um Incidente, com o status que vem do Jira.';
create index incident_tickets_open_idx on doctor.incident_tickets (tenant_id, last_synced_at)
  where status = 'open';

create trigger incident_tickets_set_updated_at
before update on doctor.incident_tickets
for each row execute function doctor.set_updated_at();

alter table doctor.incident_tickets enable row level security;
revoke all on doctor.incident_tickets from anon, authenticated;
grant select on doctor.incident_tickets to authenticated;
create policy incident_tickets_select on doctor.incident_tickets
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

-- Comentários que vieram do Jira: o autor é do Jira, não um Usuário do Doctor.
alter table doctor.incident_comments add column external_author text
  check (char_length(external_author) <= 120);
alter table doctor.incident_comments add column external_id text check (char_length(external_id) <= 64);
create unique index incident_comments_external_idx on doctor.incident_comments (tenant_id, incident_id, external_id)
  where external_id is not null;

-- O canal `jira` numa Regra de alerta abre o chamado do Incidente (#41).
alter table doctor.notification_channels drop constraint notification_channels_type_check;
alter table doctor.notification_channels
  add constraint notification_channels_type_check check (type in ('email', 'slack', 'teams', 'webpush', 'jira'));

-- Reserva do chamado: na segunda vez (à mão ou por Regra), nada muda e não sai outra mensagem.
create function doctor.queue_ticket(tenant uuid, incident uuid, requester uuid, rule uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
begin
  if not exists (select 1 from doctor.itsm_connections c
      where c.tenant_id = tenant and c.status = 'active' and c.project_key is not null) then
    raise exception 'Jira não configurado' using errcode = 'DR080';
  end if;
  insert into doctor.incident_tickets (tenant_id, incident_id, requested_by, rule_id)
  values (tenant, incident, requester, rule)
  on conflict (tenant_id, incident_id, provider) do nothing
  returning id into created;
  if created is null then
    -- Falhou antes: pedir de novo tenta outra vez.
    update doctor.incident_tickets t set status = 'creating', error = null
    where t.tenant_id = tenant and t.incident_id = incident and t.status = 'failed'
    returning id into created;
  end if;
  if created is not null then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (tenant, 'itsm.ticket', jsonb_build_object('ticket_id', created));
  end if;
  return created;
end;
$$;

-- "Abrir chamado no Jira": Analyst ou acima, no Incidente desta Organização.
create function doctor.request_ticket(target uuid)
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
  return doctor.queue_ticket(tenant, target, auth.uid(), null);
end;
$$;

-- Conexão: o `state` é emitido pela API (Owner ou Admin com MFA) e consumido na volta.
create function doctor.start_itsm_oauth(state_hash text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform doctor.require_manager();
  insert into doctor.itsm_oauth_states (tenant_id, user_id, state_hash)
  values (doctor.current_tenant_id(), auth.uid(), start_itsm_oauth.state_hash);
end;
$$;

create function doctor.finish_itsm_oauth(state_hash text, tokens text, sites jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current_secret uuid;
  connection uuid;
begin
  perform doctor.require_manager();
  update doctor.itsm_oauth_states s set used_at = now()
  where s.state_hash = finish_itsm_oauth.state_hash and s.tenant_id = tenant
    and s.user_id = auth.uid() and s.used_at is null and s.expires_at > now();
  if not found then
    raise exception 'autorização inválida ou vencida' using errcode = 'DR081';
  end if;
  select c.id, c.secret_id into connection, current_secret
  from doctor.itsm_connections c where c.tenant_id = tenant and c.provider = 'jira' for update;
  if connection is null then
    insert into doctor.itsm_connections (tenant_id, sites, secret_id, created_by, status)
    values (tenant, sites, vault.create_secret(tokens, 'doctor/itsm/' || tenant, 'Tokens do Jira do Doctor'),
      auth.uid(), 'pending')
    returning id into connection;
  else
    perform vault.update_secret(current_secret, tokens);
    update doctor.itsm_connections c set sites = finish_itsm_oauth.sites, last_error = null,
      status = case when c.project_key is null then 'pending' else 'active' end
    where c.id = connection;
  end if;
  perform doctor.record_audit(tenant, 'itsm.connect', connection::text);
  return connection;
end;
$$;

-- Configuração do Jira (Owner ou Admin com MFA). Com site e projeto, a conexão fica ativa e o
-- `notifier` registra o webhook do Jira. O token do endereço do webhook só dispara a leitura pela
-- API (nada do corpo é confiado): o banco guarda o hash para conferir, e o token em si vai para
-- o Vault, junto dos tokens do Atlassian, de onde o `notifier` o lê para registrar o endereço.
create function doctor.configure_jira(
  cloud_id text, project_key text, issue_type text, priority_map jsonb, custom_fields jsonb,
  sync_status boolean, hook_token text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  site jsonb;
  connection uuid;
begin
  perform doctor.require_manager();
  select c.id, (select s from jsonb_array_elements(c.sites) s where s ->> 'id' = configure_jira.cloud_id)
  into connection, site
  from doctor.itsm_connections c where c.tenant_id = tenant and c.provider = 'jira' for update;
  if connection is null then
    raise no_data_found using message = 'Jira não conectado';
  end if;
  if site is null then
    raise exception 'site fora da autorização' using errcode = 'DR082';
  end if;
  perform vault.update_secret(c.secret_id,
    (coalesce(s.decrypted_secret, '{}')::jsonb || jsonb_build_object('hook_token', configure_jira.hook_token))::text)
  from doctor.itsm_connections c left join vault.decrypted_secrets s on s.id = c.secret_id
  where c.id = connection;
  update doctor.itsm_connections c set cloud_id = configure_jira.cloud_id, site_url = site ->> 'url',
    project_key = configure_jira.project_key, issue_type = configure_jira.issue_type,
    priority_map = configure_jira.priority_map, custom_fields = configure_jira.custom_fields,
    sync_status = configure_jira.sync_status,
    hook_token_hash = encode(sha256(convert_to(configure_jira.hook_token, 'UTF8')), 'hex'),
    status = 'active', last_error = null
  where c.id = connection;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'itsm.sync', jsonb_build_object('connection_id', connection, 'register', true));
  perform doctor.record_audit(tenant, 'itsm.configure', connection::text);
end;
$$;

create function doctor.disconnect_jira()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  -- Os tokens saem do Vault pelo trigger `itsm_connections_drop_secret`.
  delete from doctor.itsm_connections c where c.tenant_id = tenant and c.provider = 'jira';
  perform doctor.record_audit(tenant, 'itsm.disconnect', tenant::text);
end;
$$;

-- Webhook do Jira (sem sessão, como `anon`): o token do endereço só identifica a conexão e
-- pede a sincronização; nada do corpo é confiado.
create function doctor.jira_hook(token_hash text, issue_key text)
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
  where c.hook_token_hash = jira_hook.token_hash and c.status = 'active' and c.sync_status;
  if found.id is null then
    return false;
  end if;
  -- A chave da issue (do corpo, não confiável) só diz qual chamado reler, e só se for desta
  -- Organização: o `notifier` relê o status pela API do Jira.
  wanted := jsonb_build_object('connection_id', found.id,
    'issue_key', case when jira_hook.issue_key ~ '^[A-Z][A-Z0-9_]{1,19}-[0-9]{1,10}$'
      then jira_hook.issue_key end);
  -- Rajada de eventos da mesma issue vira uma leitura só enquanto a anterior não saiu.
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

-- Tokens: só a plataforma lê e renova (o refresh token do Atlassian gira a cada uso).
create function doctor.get_itsm_tokens(target uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.decrypted_secret from doctor.itsm_connections c
  join vault.decrypted_secrets s on s.id = c.secret_id where c.id = target
$$;

create function doctor.put_itsm_tokens(target uuid, tokens text)
returns void
language sql
security definer
set search_path = ''
as $$
  select vault.update_secret(c.secret_id, tokens) from doctor.itsm_connections c where c.id = target
$$;

-- Comentário com o prefixo `#jira` num Incidente com chamado vai para o Jira.
create function doctor.queue_comment_to_jira()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.external_id is null and new.body_md ~* '^#jira\s' and exists (
      select 1 from doctor.incident_tickets t
      where t.tenant_id = new.tenant_id and t.incident_id = new.incident_id and t.status in ('open', 'done')) then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (new.tenant_id, 'itsm.comment', jsonb_build_object('comment_id', new.id));
  end if;
  return new;
end;
$$;
create trigger incident_comments_to_jira
after insert on doctor.incident_comments
for each row execute function doctor.queue_comment_to_jira();

-- Exclusão total (LGPD): os tokens saem do Vault junto com a conexão.
create function doctor.drop_itsm_secret()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from vault.secrets s where s.id = old.secret_id;
  return old;
end;
$$;
create trigger itsm_connections_drop_secret
after delete on doctor.itsm_connections
for each row execute function doctor.drop_itsm_secret();

revoke all on function doctor.queue_ticket(uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function doctor.request_ticket(uuid) from public, anon, service_role;
revoke all on function doctor.start_itsm_oauth(text) from public, anon, service_role;
revoke all on function doctor.finish_itsm_oauth(text, text, jsonb) from public, anon, service_role;
revoke all on function doctor.configure_jira(text, text, text, jsonb, jsonb, boolean, text) from public, anon, service_role;
revoke all on function doctor.disconnect_jira() from public, anon, service_role;
revoke all on function doctor.jira_hook(text, text) from public, service_role;
revoke all on function doctor.get_itsm_tokens(uuid) from public, anon, authenticated;
revoke all on function doctor.put_itsm_tokens(uuid, text) from public, anon, authenticated;
revoke all on function doctor.queue_comment_to_jira() from public, anon, authenticated;
revoke all on function doctor.drop_itsm_secret() from public, anon, authenticated;
grant execute on function doctor.request_ticket(uuid) to authenticated;
grant execute on function doctor.start_itsm_oauth(text) to authenticated;
grant execute on function doctor.finish_itsm_oauth(text, text, jsonb) to authenticated;
grant execute on function doctor.configure_jira(text, text, text, jsonb, jsonb, boolean, text) to authenticated;
grant execute on function doctor.disconnect_jira() to authenticated;
grant execute on function doctor.jira_hook(text, text) to anon;
grant execute on function doctor.queue_ticket(uuid, uuid, uuid, uuid) to service_role;
grant execute on function doctor.get_itsm_tokens(uuid) to service_role;
grant execute on function doctor.put_itsm_tokens(uuid, text) to service_role;

-- Nome de quem comentou, para o comentário que vai ao Jira (só a plataforma chama).
create function doctor.comment_author_name(target uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(u.raw_user_meta_data ->> 'full_name', split_part(u.email::text, '@', 1), 'Doctor')
  from doctor.incident_comments c left join auth.users u on u.id = c.author_id
  where c.id = target
$$;
revoke all on function doctor.comment_author_name(uuid) from public, anon, authenticated;
grant execute on function doctor.comment_author_name(uuid) to service_role;
