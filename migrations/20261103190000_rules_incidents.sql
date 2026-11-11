-- Regras determinísticas e abertura de Incidentes (ticket #18). As Regras são código
-- (packages/diagnosis-engine); aqui fica o registro de cada versão, os matches e os Incidentes.

-- Catálogo global (sem tenant): o mesmo para todas as Organizações, só leitura para o cliente.
create table doctor.rule_definitions (
  code text not null,
  version text not null,
  category text not null,
  severity_hint text not null check (severity_hint in ('low', 'medium', 'high', 'critical')),
  description text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (code, version)
);
comment on table doctor.rule_definitions is 'Versões das Regras determinísticas (catálogo global, só leitura).';

-- Mantida em sincronia com aid_diagnosis_engine.rules.catalog (o teste do worker confere).
insert into doctor.rule_definitions (code, version, category, severity_hint, description) values
  ('INT-001', '2026.10.1', 'AUTH', 'high', 'O destino recusou a autenticação ou a autorização (HTTP 401/403).'),
  ('INT-002', '2026.10.1', 'RATE_LIMIT', 'medium', 'O destino limitou as chamadas (HTTP 429).'),
  ('INT-003', '2026.10.1', 'TIMEOUT', 'high', 'Tempo esgotado (HTTP 504 ou timeout): o resultado no destino é indeterminado.'),
  ('INT-004', '2026.10.1', 'VALIDATION', 'medium', 'O payload foi recusado na validação (HTTP 400/422).'),
  ('INT-005', '2026.10.1', 'BUSINESS_REJECTION', 'high', 'O SAP rejeitou por regra de negócio (BAPIRET2 tipo E/A, mensagens V1/VL).'),
  ('INT-006', '2026.10.1', 'DUPLICATE', 'low', 'O identificador já existe no destino (duplicidade).'),
  ('INT-007', '2026.10.1', 'PENDING_CONFIRMATION', 'medium', 'Enviado, sem confirmação do destino dentro do prazo.'),
  ('INT-008', '2026.10.1', 'DIVERGENCE', 'high', 'Origem e destino divergem em contagem ou status.');

create table doctor.rule_matches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  execution_id uuid not null,
  rule_code text not null,
  rule_version text not null,
  matched_event_ids uuid[] not null check (cardinality(matched_event_ids) > 0),
  details jsonb not null default '{}' check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  -- Reavaliar a mesma Execução com a mesma versão não duplica o match.
  unique (tenant_id, execution_id, rule_code, rule_version),
  foreign key (tenant_id, execution_id) references doctor.executions (tenant_id, id) on delete cascade,
  -- A versão da Regra nunca some: o match antigo continua rastreável.
  foreign key (rule_code, rule_version) references doctor.rule_definitions (code, version)
);
comment on table doctor.rule_matches is 'Regra que disparou numa Execução, com a versão e os Eventos que provam o sintoma.';

-- Exceção à convenção (sem tenant_id na frente): serve à FK vinda do catálogo global, que confere
-- se alguma Organização usa a versão antes de deixar apagá-la.
create index rule_matches_rule_idx on doctor.rule_matches (rule_code, rule_version);

create trigger rule_matches_set_updated_at
before update on doctor.rule_matches
for each row execute function doctor.set_updated_at();

create table doctor.incidents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  title text not null check (char_length(title) between 1 and 200),
  category text not null,
  severity text not null check (severity in ('low', 'medium', 'high', 'critical')),
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'dismissed')),
  -- Regra que abriu o Incidente (a versão, para rastrear).
  rule_code text not null,
  rule_version text not null,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  execution_count integer not null default 0 check (execution_count >= 0),
  assignee_id uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  foreign key (rule_code, rule_version) references doctor.rule_definitions (code, version),
  check (last_seen_at >= first_seen_at)
);
comment on table doctor.incidents is 'Incidente: falha ou anomalia agrupada por Integração, categoria e janela de 30 min.';

create index incidents_tenant_seen_idx on doctor.incidents (tenant_id, last_seen_at desc);
-- Achar o Incidente aberto da mesma Integração e categoria.
create index incidents_open_idx on doctor.incidents (tenant_id, integration_id, category, last_seen_at desc)
  where status in ('open', 'investigating');

create trigger incidents_set_updated_at
before update on doctor.incidents
for each row execute function doctor.set_updated_at();

create table doctor.incident_executions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  execution_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, incident_id, execution_id),
  -- Uma Execução entra em um Incidente só (o do match mais severo).
  unique (tenant_id, execution_id),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade,
  foreign key (tenant_id, execution_id) references doctor.executions (tenant_id, id) on delete cascade
);
comment on table doctor.incident_executions is 'Execuções agrupadas em cada Incidente.';

create trigger incident_executions_set_updated_at
before update on doctor.incident_executions
for each row execute function doctor.set_updated_at();

alter table doctor.rule_definitions enable row level security;
alter table doctor.rule_matches enable row level security;
alter table doctor.incidents enable row level security;
alter table doctor.incident_executions enable row level security;
revoke all on doctor.rule_definitions, doctor.rule_matches, doctor.incidents, doctor.incident_executions
  from anon, authenticated;
grant select on doctor.rule_definitions, doctor.rule_matches, doctor.incidents, doctor.incident_executions
  to authenticated;

create policy rule_definitions_select on doctor.rule_definitions
for select to authenticated
using (true);

create policy rule_matches_select on doctor.rule_matches
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy incidents_select on doctor.incidents
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy incident_executions_select on doctor.incident_executions
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));
