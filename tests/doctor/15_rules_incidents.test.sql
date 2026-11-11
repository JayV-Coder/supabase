begin;
\ir ../helpers/tenancy.psql
select plan(10);

select is(
  (select bool_and(relrowsecurity) from pg_class where oid in (
    'doctor.rule_definitions'::regclass, 'doctor.rule_matches'::regclass,
    'doctor.incidents'::regclass, 'doctor.incident_executions'::regclass)),
  true, 'RLS ligado'
);
select is(
  (select count(*)::int from doctor.rule_definitions where version = '2026.10.1'), 8,
  'catálogo 2026.10.1 com INT-001 a INT-008'
);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'viewer');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Notas', 'sap', 'gcp', 'prd');
insert into doctor.executions (id, tenant_id, integration_id, first_event_at, last_event_at)
values
  ('00000000-0000-4000-8000-0000000004a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000001a1', '2026-11-02T14:00:00Z', '2026-11-02T14:00:30Z'),
  ('00000000-0000-4000-8000-0000000004b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000001b1', '2026-11-02T14:00:00Z', '2026-11-02T14:00:30Z');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code,
  rule_version, first_seen_at, last_seen_at, execution_count)
values
  ('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000001a1', 'Timeout · Pedidos', 'TIMEOUT', 'critical', 'INT-003',
   '2026.10.1', '2026-11-02T14:00:00Z', '2026-11-02T14:00:30Z', 1),
  ('00000000-0000-4000-8000-0000000005b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000001b1', 'Timeout · Notas', 'TIMEOUT', 'critical', 'INT-003',
   '2026.10.1', '2026-11-02T14:00:00Z', '2026-11-02T14:00:30Z', 1);
insert into doctor.incident_executions (tenant_id, incident_id, execution_id)
values
  ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-0000000004a1'),
  ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000005b1', '00000000-0000-4000-8000-0000000004b1');
insert into doctor.rule_matches (tenant_id, execution_id, rule_code, rule_version, matched_event_ids)
values
  ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000004a1', 'INT-003', '2026.10.1', array[gen_random_uuid()]),
  ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000004b1', 'INT-003', '2026.10.1', array[gen_random_uuid()]);

select throws_ok(
  $$insert into doctor.rule_matches (tenant_id, execution_id, rule_code, rule_version, matched_event_ids)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000004a1', 'INT-003', '1999.1.1', array[gen_random_uuid()])$$,
  '23503', null, 'match só aponta para versão registrada da Regra'
);
select throws_ok(
  $$delete from doctor.rule_definitions where code = 'INT-003' and version = '2026.10.1'$$,
  '23503', null, 'versão com match não some: o match antigo segue rastreável'
);
select throws_ok(
  $$insert into doctor.incident_executions (tenant_id, incident_id, execution_id)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-0000000004b1')$$,
  '23503', null, 'FK composta: Incidente não recebe Execução de outra Organização'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select results_eq(
  $$select id::text collate "default" from doctor.incidents$$,
  $$values ('00000000-0000-4000-8000-0000000005a1'::text)$$,
  'cada Organização vê só os próprios Incidentes'
);
select is((select count(*)::int from doctor.incident_executions), 1, 'e só as próprias ligações');
select is((select count(*)::int from doctor.rule_matches), 1, 'e só os próprios matches');
select is((select count(*)::int from doctor.rule_definitions where version = '2026.10.1'), 8, 'catálogo é de todos');
select throws_ok(
  $$update doctor.rule_definitions set active = false$$,
  '42501', null, 'cliente não mexe no catálogo'
);
select tests.clear_authentication();

select * from finish();
rollback;
