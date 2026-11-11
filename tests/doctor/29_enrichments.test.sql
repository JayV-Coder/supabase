begin;
\ir ../helpers/tenancy.psql
select plan(6);

select tests.create_user('00000000-0000-4000-8000-0000000c0001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000c0003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000c0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000c0003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code, rule_version, first_seen_at, last_seen_at)
values ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now());
insert into doctor.diagnoses (id, tenant_id, incident_id, version, status, stage, requested_mode, mode, processing_key)
values ('00000000-0000-4000-8000-0000000003a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000002a1', 1, 'running', 'correlation', 'rules_only', 'rules_only', 'k-1');
insert into doctor.enrichments (id, tenant_id, diagnosis_id, reference, system, entity, field, outcome, record_status, checked_at)
values ('00000000-0000-4000-8000-0000000004a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000003a1', '801XX0001', 'sap', 'A_SalesOrder', 'PurchaseOrderByCustomer', 'found', 'C', now());

select lives_ok(
  $$insert into doctor.diagnosis_evidence (tenant_id, diagnosis_id, rank, kind, enrichment_id, label, finding)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000003a1', 1, 'enrichment',
      '00000000-0000-4000-8000-0000000004a1', 'Consulta SAP · A_SalesOrder', 'O pedido existe no SAP.')$$,
  'Evidência aponta para a consulta'
);
select throws_ok(
  $$insert into doctor.diagnosis_evidence (tenant_id, diagnosis_id, rank, kind, enrichment_id, rule_match_id, label, finding)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000003a1', 2, 'enrichment',
      '00000000-0000-4000-8000-0000000004a1', gen_random_uuid(), 'x', 'y')$$,
  '23514', null, 'uma referência só por Evidência'
);
select throws_ok(
  $$insert into doctor.enrichments (tenant_id, diagnosis_id, reference, system, entity, field, outcome)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000003a1', 'x', 'sap', 'A', 'B', 'found')$$,
  '23514', null, 'resultado final exige o instante da consulta'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000c0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select is((select record_status from doctor.enrichments), 'C', 'a Organização lê a consulta');
select throws_ok(
  $$insert into doctor.enrichments (tenant_id, diagnosis_id, reference, system, entity, field)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000003a1', 'x', 'sap', 'A', 'B')$$,
  '42501', null, 'só os workers gravam consultas'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000c0003', '00000000-0000-4000-8000-00000000be01', 'admin', 'aal2');
select is((select count(*)::int from doctor.enrichments), 0, 'outra Organização não vê');
select tests.clear_authentication();

select * from finish();
rollback;
