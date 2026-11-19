-- Leituras diretas do site (ADR-0026 do jayv-doctor), segundo bloco: Integrações, Execuções e
-- Conectores, as listas que mais páginas do Doctor pedem.
begin;
\ir ../helpers/tenancy.psql
select plan(21);

select tests.create_user('00000000-0000-4000-8000-00000044a001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000044c001', 'caio@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-0000004400a1', 'acme-44');
select tests.create_tenant('00000000-0000-4000-8000-0000004400b1', 'varejo-44');
select tests.add_member('00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-00000044a001', 'viewer');
select tests.add_member('00000000-0000-4000-8000-0000004400b1', '00000000-0000-4000-8000-00000044c001', 'owner');

insert into doctor.integrations (id, tenant_id, name, environment, source_system, target_system, archived_at) values
  ('00000000-0000-4000-8000-0000004401a1', '00000000-0000-4000-8000-0000004400a1', 'Pedidos', 'prd', 'sap', 'salesforce', null),
  ('00000000-0000-4000-8000-0000004401a2', '00000000-0000-4000-8000-0000004400a1', 'Antiga', 'hml', 'sap', 'gcp', now()),
  ('00000000-0000-4000-8000-0000004401b1', '00000000-0000-4000-8000-0000004400b1', 'Notas', 'prd', 'sap', 'gcp', null);
insert into doctor.execution_stats_hourly (tenant_id, integration_id, hour, total, failed) values
  ('00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', date_trunc('hour', now()) - interval '1 hour', 4, 1);
insert into doctor.executions (id, tenant_id, integration_id, status, first_event_at, last_event_at, correlation_keys, merged_into) values
  ('00000000-0000-4000-8000-0000004402a1', '00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', 'failed', now() - interval '3 hours', now() - interval '3 hours', '{"execution_id": ["e1"]}', null),
  ('00000000-0000-4000-8000-0000004402a2', '00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', 'success', now() - interval '2 hours', now() - interval '2 hours', '{}', null),
  ('00000000-0000-4000-8000-0000004402a3', '00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', 'success', now() - interval '1 hour', now() - interval '1 hour', '{}', '00000000-0000-4000-8000-0000004402a2'),
  ('00000000-0000-4000-8000-0000004402b1', '00000000-0000-4000-8000-0000004400b1', '00000000-0000-4000-8000-0000004401b1', 'failed', now() - interval '1 hour', now() - interval '1 hour', '{}', null);
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, status, rule_code, rule_version, first_seen_at, last_seen_at, execution_count) values
  ('00000000-0000-4000-8000-0000004403a1', '00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', 'Token expirado', 'AUTH', 'high', 'open', 'INT-001', '2026.10.1', now() - interval '3 hours', now() - interval '3 hours', 1);
insert into doctor.incident_executions (tenant_id, incident_id, execution_id) values
  ('00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004403a1', '00000000-0000-4000-8000-0000004402a1');
insert into doctor.connectors (id, tenant_id, integration_id, provider, name) values
  ('00000000-0000-4000-8000-0000004404a1', '00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004401a1', 'gcp', 'Logs do GCP'),
  ('00000000-0000-4000-8000-0000004404b1', '00000000-0000-4000-8000-0000004400b1', '00000000-0000-4000-8000-0000004401b1', 'gcp', 'Outro');
insert into doctor.connector_syncs (tenant_id, connector_id, started_at, finished_at, status, records) values
  ('00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004404a1', now() - interval '2 hours', now() - interval '2 hours', 'succeeded', 7),
  ('00000000-0000-4000-8000-0000004400a1', '00000000-0000-4000-8000-0000004404a1', now() - interval '1 hour', now() - interval '1 hour', 'succeeded', 12);

select tests.authenticate_as('00000000-0000-4000-8000-00000044a001', '00000000-0000-4000-8000-0000004400a1', 'viewer');

-- Integrações
select is(jsonb_array_length(doctor_read.integrations()), 1, 'integrações: sem as arquivadas, só da Organização');
select is(jsonb_array_length(doctor_read.integrations(include_archived => true)), 2, 'integrações: com as arquivadas, se pedido');
select is((doctor_read.integrations() -> 0 ->> 'error_rate_24h')::numeric, 0.25, 'integrações: taxa de erro das últimas 24 h');
select is(doctor_read.integrations(include_archived => true) -> 0 ->> 'name', 'Antiga', 'integrações: por nome');

-- Execuções
select is(jsonb_array_length(doctor_read.executions() -> 'items'), 2, 'execuções: sem as fundidas, só da Organização');
select is(doctor_read.executions() -> 'items' -> 1 -> 'incident' ->> 'title', 'Token expirado', 'execuções: o Incidente ligado');
select is(doctor_read.executions() -> 'items' -> 0 -> 'incident', 'null'::jsonb, 'execuções: sem Incidente, nulo');
select is(doctor_read.executions(status => 'failed') -> 'items' -> 0 ->> 'id', '00000000-0000-4000-8000-0000004402a1', 'execuções: filtro de status');
select is(jsonb_array_length(doctor_read.executions(environment => 'hml') -> 'items'), 0, 'execuções: filtro de Ambiente');
select is(jsonb_array_length(doctor_read.executions(integration => '00000000-0000-4000-8000-0000004401a2') -> 'items'), 0, 'execuções: filtro de Integração');
select is(jsonb_array_length(doctor_read.executions(since => now() - interval '150 minutes') -> 'items'), 1, 'execuções: desde (pela última atividade)');
select is(jsonb_array_length(doctor_read.executions(until => now() - interval '150 minutes') -> 'items'), 1, 'execuções: até (pelo primeiro evento)');
select throws_ok(
  $$select doctor_read.executions(cursor_at => now())$$, 'DR111', null, 'execuções: cursor pela metade é recusado'
);
select ok(
  doctor_read.executions(lim => 1) -> 'next_cursor' is not null
  and doctor_read.executions(
    lim => 1,
    cursor_at => (doctor_read.executions(lim => 1) -> 'next_cursor' ->> 'at')::timestamptz,
    cursor_id => (doctor_read.executions(lim => 1) -> 'next_cursor' ->> 'id')::uuid
  ) -> 'items' -> 0 ->> 'id' = '00000000-0000-4000-8000-0000004402a1',
  'execuções: página seguinte pelo cursor'
);

-- Empate no instante: o id desempata, e a página seguinte não repete nem pula.
select tests.clear_authentication();
update doctor.executions set first_event_at = '2026-11-01T10:00:00Z', last_event_at = '2026-11-01T10:00:00Z'
where id in ('00000000-0000-4000-8000-0000004402a1', '00000000-0000-4000-8000-0000004402a2');
select tests.authenticate_as('00000000-0000-4000-8000-00000044a001', '00000000-0000-4000-8000-0000004400a1', 'viewer');
select results_eq(
  $$select array[
      doctor_read.executions(lim => 1) -> 'items' -> 0 ->> 'id',
      doctor_read.executions(lim => 1, cursor_at => '2026-11-01T10:00:00Z',
        cursor_id => (doctor_read.executions(lim => 1) -> 'next_cursor' ->> 'id')::uuid) -> 'items' -> 0 ->> 'id']$$,
  $$values (array['00000000-0000-4000-8000-0000004402a2', '00000000-0000-4000-8000-0000004402a1'])$$,
  'execuções: empate no instante, sem repetir nem pular'
);

-- Conectores
select is(jsonb_array_length(doctor_read.connectors()), 1, 'conectores: só da Organização');
select is((doctor_read.connectors() -> 0 ->> 'last_sync_records')::int, 12, 'conectores: registros da última coleta');
select is(doctor_read.connectors() -> 0 ->> 'name', 'Logs do GCP', 'conectores: os campos do Conector');
select ok(not (doctor_read.connectors() -> 0 ? 'secret_id'), 'conectores: sem a referência da credencial');

-- Sem Vínculo, nada.
select tests.clear_authentication();
delete from doctor.memberships where user_id = '00000000-0000-4000-8000-00000044a001';
select tests.authenticate_as('00000000-0000-4000-8000-00000044a001', '00000000-0000-4000-8000-0000004400a1', 'viewer');
select throws_ok($$select doctor_read.integrations()$$, 'DR110', null, 'sem Vínculo, a lista é recusada');
select tests.clear_authentication();
select is(has_function_privilege('anon', 'doctor_read.executions(text, uuid, text, timestamptz, timestamptz, timestamptz, uuid, integer)', 'execute'), false, 'anon não lê');

select * from finish();
rollback;
