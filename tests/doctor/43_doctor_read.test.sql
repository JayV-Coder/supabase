-- Leituras do site direto no Supabase (ADR-0026 do jayv-doctor): o schema `doctor_read`, exposto
-- na API de dados, e a Organização do JWT que só vale com Vínculo vivo.
begin;
\ir ../helpers/tenancy.psql
select plan(24);

select tests.create_user('00000000-0000-4000-8000-00000043a001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000043b001', 'bia@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000043c001', 'caio@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-0000004300a1', 'acme-43');
select tests.create_tenant('00000000-0000-4000-8000-0000004300b1', 'varejo-43');
select tests.add_member('00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-00000043a001', 'owner');
select tests.add_member('00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-00000043b001', 'viewer');
select tests.add_member('00000000-0000-4000-8000-0000004300b1', '00000000-0000-4000-8000-00000043c001', 'owner');

insert into doctor.integrations (id, tenant_id, name, environment, source_system, target_system) values
  ('00000000-0000-4000-8000-0000004301a1', '00000000-0000-4000-8000-0000004300a1', 'SAP → Salesforce', 'prd', 'sap', 'salesforce'),
  ('00000000-0000-4000-8000-0000004301b1', '00000000-0000-4000-8000-0000004300b1', 'Pedidos', 'prd', 'sap', 'gcp');
insert into doctor.execution_stats_hourly (tenant_id, integration_id, hour, total, failed, by_category) values
  ('00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-0000004301a1', date_trunc('hour', now()) - interval '2 hours', 10, 2, '{"auth": 2}'),
  ('00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-0000004301a1', date_trunc('hour', now()) - interval '30 hours', 5, 0, '{}'),
  ('00000000-0000-4000-8000-0000004300b1', '00000000-0000-4000-8000-0000004301b1', date_trunc('hour', now()) - interval '2 hours', 99, 99, '{"timeout": 99}');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, status, rule_code, rule_version,
  first_seen_at, last_seen_at, execution_count, resolved_at, resolution_note) values
  ('00000000-0000-4000-8000-0000004302a1', '00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-0000004301a1',
   'Token expirado', 'auth', 'critical', 'open', 'INT-001', '2026.10.1', now() - interval '3 hours', now() - interval '1 hour', 2, null, null),
  ('00000000-0000-4000-8000-0000004302a2', '00000000-0000-4000-8000-0000004300a1', '00000000-0000-4000-8000-0000004301a1',
   'Campo obrigatório', 'mapping', 'medium', 'resolved', 'INT-002', '2026.10.1', now() - interval '5 hours', now() - interval '4 hours', 1,
   now() - interval '4 hours', 'Mapeamento corrigido'),
  ('00000000-0000-4000-8000-0000004302b1', '00000000-0000-4000-8000-0000004300b1', '00000000-0000-4000-8000-0000004301b1',
   'Timeout do GCP', 'timeout', 'high', 'open', 'INT-002', '2026.10.1', now() - interval '2 hours', now() - interval '30 minutes', 9, null, null);

select has_schema('doctor_read', 'schema doctor_read existe');
select is(has_schema_privilege('anon', 'doctor_read', 'usage'), false, 'anon não usa doctor_read');
select is(has_schema_privilege('authenticated', 'doctor_read', 'usage'), true, 'authenticated usa doctor_read');

-- /me
select tests.authenticate_as('00000000-0000-4000-8000-00000043a001', '00000000-0000-4000-8000-0000004300a1', 'owner', 'aal2');
select is(doctor_read.me() ->> 'active_tenant_id', '00000000-0000-4000-8000-0000004300a1', 'me: Organização ativa do JWT');
select is(doctor_read.me() ->> 'active_role', 'owner', 'me: Papel ativo do JWT');
select is(jsonb_array_length(doctor_read.me() -> 'organizations'), 1, 'me: só as Organizações com Vínculo');
select is(doctor_read.me() -> 'organizations' -> 0 ->> 'role', 'owner', 'me: Papel de cada Organização');
select is(jsonb_typeof(doctor_read.me() -> 'available_organizations'), 'array', 'me: disponíveis do jayv-coder');

-- Painel
select is((doctor_read.dashboard('24h') -> 'executions' ->> 'value')::int, 10, 'painel: Execuções do período, só da Organização');
select is((doctor_read.dashboard('24h') -> 'executions' ->> 'previous')::int, 5, 'painel: período anterior');
select is((doctor_read.dashboard('24h') -> 'error_rate' ->> 'value')::numeric, 0.2, 'painel: taxa de erro');
select is((doctor_read.dashboard('24h') ->> 'open_incidents')::int, 1, 'painel: Incidentes abertos');
select is(doctor_read.dashboard('24h') -> 'critical_incident' ->> 'title', 'Token expirado', 'painel: Incidente crítico');
select is(doctor_read.dashboard('24h') -> 'failures_by_category' -> 0 ->> 'category', 'auth', 'painel: falhas por categoria');
select is(jsonb_array_length(doctor_read.dashboard('24h') -> 'failures'), 25, 'painel: série de 24 h com as horas vazias');
select throws_ok($$select doctor_read.dashboard('1y')$$, '22023', null, 'painel: período inválido é recusado');

-- Incidentes
select is(jsonb_array_length(doctor_read.incidents() -> 'items'), 2, 'incidentes: só os da Organização');
select is((doctor_read.incidents() -> 'counts' ->> 'open')::int, 1, 'incidentes: contagem por status');
select is(doctor_read.incidents(status => array['resolved']) -> 'items' -> 0 ->> 'title', 'Campo obrigatório', 'incidentes: filtro de status');
select ok(
  doctor_read.incidents(lim => 1) -> 'next_cursor' is not null
  and jsonb_array_length(doctor_read.incidents(
    lim => 1,
    cursor_at => (doctor_read.incidents(lim => 1) -> 'next_cursor' ->> 'at')::timestamptz,
    cursor_id => (doctor_read.incidents(lim => 1) -> 'next_cursor' ->> 'id')::uuid
  ) -> 'items') = 1,
  'incidentes: página seguinte pelo cursor'
);

-- Vínculo removido: o JWT ainda traz a Organização, mas nada é lido (nem pelo RLS, nem pelo Realtime).
select tests.clear_authentication();
delete from doctor.memberships where user_id = '00000000-0000-4000-8000-00000043b001';
select tests.authenticate_as('00000000-0000-4000-8000-00000043b001', '00000000-0000-4000-8000-0000004300a1', 'viewer', 'aal1');
select is(doctor.current_tenant_id(), null, 'sem Vínculo, a Organização do JWT não vale');
select is((select count(*) from doctor.incidents), 0::bigint, 'sem Vínculo, o RLS não devolve Incidentes');
select throws_ok($$select doctor_read.dashboard('24h')$$, '42501', null, 'sem Vínculo, o painel é recusado');

-- Worker (claim do tenant sem Usuário) continua lendo pela Organização.
select tests.clear_authentication();
select set_config('request.jwt.claims', '{"role": "authenticated", "tenant_id": "00000000-0000-4000-8000-0000004300a1"}', true);
set local role authenticated;
select is((select count(*) from doctor.incidents), 2::bigint, 'worker sem Usuário segue lendo a Organização');

select * from finish();
rollback;
