-- Ticket #42: webhooks de saída assinados. Cada webhook da Organização recebe os eventos que
-- escolheu, com payload versionado (`webhook.v1`: ids e links, nunca Eventos brutos) e a
-- assinatura `X-AID-Signature: t=<ts>,v1=<hmac-sha256>`. O segredo de assinatura fica no Vault;
-- quem entrega é o worker `notifier` (ADR-0017), com novas tentativas por até 24 h.

create table doctor.webhooks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  url text not null check (url ~ '^https://' and char_length(url) <= 1000),
  events text[] not null check (
    cardinality(events) between 1 and 5
    and events <@ array['incident.opened', 'incident.updated', 'incident.resolved',
      'diagnosis.published', 'diagnosis.reviewed']
  ),
  secret_id uuid not null,
  enabled boolean not null default true,
  -- Falhas seguidas (zera no sucesso); com 50, o webhook desliga e os Admins são avisados.
  failure_count integer not null default 0 check (failure_count >= 0),
  last_status integer,
  last_delivery_at timestamptz,
  disabled_reason text check (char_length(disabled_reason) <= 200),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);
comment on table doctor.webhooks is 'Webhook de saída assinado da Organização.';

create trigger webhooks_set_updated_at
before update on doctor.webhooks
for each row execute function doctor.set_updated_at();

alter table doctor.webhooks enable row level security;
revoke all on doctor.webhooks from anon, authenticated;
grant select (id, tenant_id, name, url, events, enabled, failure_count, last_status,
  last_delivery_at, disabled_reason, created_by, created_at, updated_at) on doctor.webhooks to authenticated;
create policy webhooks_select on doctor.webhooks
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

-- Entregas: o corpo é montado pelo worker na primeira tentativa e reaproveitado nas seguintes
-- (o "Reenviar" cria outra entrega com o mesmo corpo).
create table doctor.webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  webhook_id uuid not null,
  event text not null,
  -- O que o evento trata, com o retrato da hora do evento (`incident`, `diagnosis`, `review`):
  -- o Incidente resolvido logo depois não faz o `incident.opened` chegar como resolvido.
  subject jsonb not null check (jsonb_typeof(subject) = 'object'),
  body jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'succeeded', 'failed', 'abandoned')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz default now(),
  response_status integer,
  latency_ms integer check (latency_ms >= 0),
  -- Até 1 KB da resposta, para o diagnóstico de quem recebe.
  response_excerpt text check (char_length(response_excerpt) <= 1024),
  error text check (char_length(error) <= 500),
  resent_from uuid,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, webhook_id) references doctor.webhooks (tenant_id, id) on delete cascade,
  foreign key (tenant_id, resent_from) references doctor.webhook_deliveries (tenant_id, id)
    on delete set null (resent_from)
);
comment on table doctor.webhook_deliveries is 'Entrega de um evento a um webhook, com as tentativas.';
create index webhook_deliveries_webhook_idx on doctor.webhook_deliveries (tenant_id, webhook_id, created_at desc);
create index webhook_deliveries_due_idx on doctor.webhook_deliveries (next_attempt_at)
  where status = 'pending';

create trigger webhook_deliveries_set_updated_at
before update on doctor.webhook_deliveries
for each row execute function doctor.set_updated_at();

alter table doctor.webhook_deliveries enable row level security;
revoke all on doctor.webhook_deliveries from anon, authenticated;
grant select on doctor.webhook_deliveries to authenticated;
create policy webhook_deliveries_select on doctor.webhook_deliveries
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

-- Gestão: Owner ou Admin com MFA. O segredo vem da API (gerado lá, mostrado uma vez) e vai
-- direto para o Vault.
create function doctor.create_webhook(name text, url text, events text[], secret text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  new_id uuid := gen_random_uuid();
begin
  perform doctor.require_manager();
  insert into doctor.webhooks (id, tenant_id, name, url, events, secret_id, created_by)
  values (new_id, tenant, btrim(create_webhook.name), create_webhook.url, create_webhook.events,
    vault.create_secret(create_webhook.secret, 'doctor/webhook/' || new_id, 'Segredo de webhook do Doctor'),
    auth.uid());
  perform doctor.record_audit(tenant, 'webhook.create', new_id::text);
  return new_id;
end;
$$;

create function doctor.update_webhook(target uuid, url text, events text[], enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  update doctor.webhooks w set
    url = coalesce(update_webhook.url, w.url),
    events = coalesce(update_webhook.events, w.events),
    enabled = coalesce(update_webhook.enabled, w.enabled),
    -- Religar zera as falhas e o motivo do desligamento.
    failure_count = case when update_webhook.enabled then 0 else w.failure_count end,
    disabled_reason = case when update_webhook.enabled then null else w.disabled_reason end
  where w.id = target and w.tenant_id = tenant;
  if not found then
    raise no_data_found using message = 'Webhook não encontrado';
  end if;
  perform doctor.record_audit(tenant, 'webhook.update', target::text);
end;
$$;

create function doctor.rotate_webhook_secret(target uuid, secret text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current_secret uuid;
begin
  perform doctor.require_manager();
  select w.secret_id into current_secret from doctor.webhooks w
  where w.id = target and w.tenant_id = tenant for update;
  if not found then
    raise no_data_found using message = 'Webhook não encontrado';
  end if;
  perform vault.update_secret(current_secret, secret);
  perform doctor.record_audit(tenant, 'webhook.secret.rotate', target::text);
end;
$$;

create function doctor.delete_webhook(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  -- O segredo sai do Vault pelo trigger `webhooks_drop_secret`, como no cascade da exclusão.
  delete from doctor.webhooks w where w.id = target and w.tenant_id = tenant;
  if not found then
    raise no_data_found using message = 'Webhook não encontrado';
  end if;
  perform doctor.record_audit(tenant, 'webhook.delete', target::text);
end;
$$;

-- "Reenviar": outra entrega com o mesmo corpo, já na fila.
create function doctor.resend_webhook_delivery(target uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  original doctor.webhook_deliveries;
  new_id uuid;
begin
  perform doctor.require_manager();
  select * into original from doctor.webhook_deliveries d where d.id = target and d.tenant_id = tenant;
  if original.id is null then
    raise no_data_found using message = 'Entrega não encontrada';
  end if;
  insert into doctor.webhook_deliveries (tenant_id, webhook_id, event, subject, body, resent_from)
  values (tenant, original.webhook_id, original.event, original.subject, original.body, original.id)
  returning id into new_id;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'webhook.deliver', jsonb_build_object('delivery_id', new_id));
  perform doctor.record_audit(tenant, 'webhook.resend', new_id::text);
  return new_id;
end;
$$;

-- Só o `notifier` lê o segredo.
create function doctor.get_webhook_secret(target uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  value text;
begin
  select s.decrypted_secret into value
  from doctor.webhooks w join vault.decrypted_secrets s on s.id = w.secret_id
  where w.id = target;
  if value is null then
    raise no_data_found using message = 'Webhook sem segredo';
  end if;
  return value;
end;
$$;

-- Eventos: uma entrega por webhook ligado e inscrito, e a mensagem para a primeira tentativa.
create function doctor.queue_webhooks(tenant uuid, event text, subject jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with created as (
    insert into doctor.webhook_deliveries (tenant_id, webhook_id, event, subject)
    select w.tenant_id, w.id, queue_webhooks.event, queue_webhooks.subject
    from doctor.webhooks w
    where w.tenant_id = queue_webhooks.tenant and w.enabled and queue_webhooks.event = any(w.events)
    returning id
  )
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  select queue_webhooks.tenant, 'webhook.deliver', jsonb_build_object('delivery_id', created.id)
  from created;
end;
$$;

create function doctor.incident_snapshot(incident doctor.incidents)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', incident.id, 'number', incident.number, 'title', incident.title,
    'severity', incident.severity, 'status', incident.status, 'category', incident.category,
    'environment', g.environment, 'integration', jsonb_build_object('id', g.id, 'name', g.name))
  from doctor.integrations g where g.tenant_id = incident.tenant_id and g.id = incident.integration_id
$$;

create function doctor.diagnosis_snapshot(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', d.id, 'incident_id', d.incident_id, 'version', d.version, 'status', d.status,
    'classification', d.classification, 'confidence_heuristic', d.confidence,
    'requires_human_review', d.requires_human_review)
  from doctor.diagnoses d where d.id = target
$$;

-- Incidente: aberto, resolvido e atualizado em status, severidade, responsável ou título. A
-- contagem de Execuções muda a cada Execução nova e não conta: 37 Execuções não viram 37 POSTs.
create function doctor.webhook_from_incident()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  subject jsonb := jsonb_build_object('incident_id', new.id, 'incident', doctor.incident_snapshot(new));
begin
  if tg_op = 'INSERT' then
    perform doctor.queue_webhooks(new.tenant_id, 'incident.opened', subject);
  elsif new.status = 'resolved' and old.status is distinct from 'resolved' then
    perform doctor.queue_webhooks(new.tenant_id, 'incident.resolved', subject);
  elsif (new.status, new.severity, new.assignee_id, new.title)
      is distinct from (old.status, old.severity, old.assignee_id, old.title) then
    perform doctor.queue_webhooks(new.tenant_id, 'incident.updated', subject);
  end if;
  return new;
end;
$$;
create trigger incidents_queue_webhooks
after insert or update on doctor.incidents
for each row execute function doctor.webhook_from_incident();

create function doctor.webhook_from_diagnosis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('published', 'inconclusive', 'failed_llm')
      and old.status is distinct from new.status then
    perform doctor.queue_webhooks(new.tenant_id, 'diagnosis.published',
      jsonb_build_object('diagnosis_id', new.id, 'incident_id', new.incident_id,
        'diagnosis', doctor.diagnosis_snapshot(new.id)));
  end if;
  return new;
end;
$$;
create trigger diagnoses_queue_webhooks
after update of status on doctor.diagnoses
for each row execute function doctor.webhook_from_diagnosis();

create function doctor.webhook_from_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform doctor.queue_webhooks(new.tenant_id, 'diagnosis.reviewed',
    jsonb_build_object('diagnosis_id', new.diagnosis_id, 'feedback_id', new.id,
      'diagnosis', doctor.diagnosis_snapshot(new.diagnosis_id),
      'review', jsonb_build_object('verdict', new.verdict)));
  return new;
end;
$$;
create trigger diagnosis_feedback_queue_webhooks
after insert on doctor.diagnosis_feedback
for each row execute function doctor.webhook_from_review();

revoke all on function doctor.create_webhook(text, text, text[], text) from public, anon, service_role;
revoke all on function doctor.update_webhook(uuid, text, text[], boolean) from public, anon, service_role;
revoke all on function doctor.rotate_webhook_secret(uuid, text) from public, anon, service_role;
revoke all on function doctor.delete_webhook(uuid) from public, anon, service_role;
revoke all on function doctor.resend_webhook_delivery(uuid) from public, anon, service_role;
revoke all on function doctor.get_webhook_secret(uuid) from public, anon, authenticated;
revoke all on function doctor.queue_webhooks(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function doctor.incident_snapshot(doctor.incidents) from public, anon, authenticated;
revoke all on function doctor.diagnosis_snapshot(uuid) from public, anon, authenticated;
revoke all on function doctor.webhook_from_incident() from public, anon, authenticated;
revoke all on function doctor.webhook_from_diagnosis() from public, anon, authenticated;
revoke all on function doctor.webhook_from_review() from public, anon, authenticated;
grant execute on function doctor.create_webhook(text, text, text[], text) to authenticated;
grant execute on function doctor.update_webhook(uuid, text, text[], boolean) to authenticated;
grant execute on function doctor.rotate_webhook_secret(uuid, text) to authenticated;
grant execute on function doctor.delete_webhook(uuid) to authenticated;
grant execute on function doctor.resend_webhook_delivery(uuid) to authenticated;
grant execute on function doctor.get_webhook_secret(uuid) to service_role;

-- Exclusão total (LGPD): o segredo de cada webhook sai do Vault antes do cascade.
create function doctor.drop_webhook_secret()
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
revoke all on function doctor.drop_webhook_secret() from public, anon, authenticated;
create trigger webhooks_drop_secret
after delete on doctor.webhooks
for each row execute function doctor.drop_webhook_secret();
