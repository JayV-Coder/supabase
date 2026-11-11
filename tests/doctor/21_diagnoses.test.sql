begin;
\ir ../helpers/tenancy.psql
select plan(19);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'owner');
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
insert into doctor.rule_matches (id, tenant_id, execution_id, rule_code, rule_version, matched_event_ids)
values
  ('00000000-0000-4000-8000-0000000006a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000004a1', 'INT-003', '2026.10.1', array[gen_random_uuid()]),
  ('00000000-0000-4000-8000-0000000006b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000004b1', 'INT-003', '2026.10.1', array[gen_random_uuid()]);
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code,
  rule_version, first_seen_at, last_seen_at, execution_count)
values
  ('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1),
  ('00000000-0000-4000-8000-0000000005b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000001b1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
create temporary table first_request as
select * from doctor.request_diagnosis('00000000-0000-4000-8000-0000000005a1', 'hybrid', true, 'req-1');
select results_eq(
  $$select status, version, created from first_request$$,
  $$values ('queued'::text, 1, true)$$,
  'pedido cria a versão 1 na fila'
);
select results_eq(
  $$select id, created from doctor.request_diagnosis('00000000-0000-4000-8000-0000000005a1', 'hybrid', true, 'req-1')$$,
  $$select id, false from first_request$$,
  'a mesma chave devolve o mesmo Diagnóstico'
);
select is(
  (select version from doctor.request_diagnosis('00000000-0000-4000-8000-0000000005a1', 'rules_only', false, 'req-2')),
  2, 'nova análise é a versão N+1'
);
select throws_ok(
  $$select doctor.request_diagnosis('00000000-0000-4000-8000-0000000005b1', 'hybrid', true, 'req-3')$$,
  'P0002', null, 'Incidente de outra Organização não existe para quem pede'
);
select throws_ok(
  $$select doctor.request_diagnosis('00000000-0000-4000-8000-0000000005a1', 'automatico', true, 'req-4')$$,
  '22023', null, 'modo inválido'
);
select throws_ok(
  $$select doctor.set_auto_diagnosis(true)$$, '42501', null, 'Analyst não liga o automático'
);
select tests.clear_authentication();

select is(
  (select count(*)::int from doctor.outbox_messages
   where topic = 'diagnosis.requested' and payload ->> 'diagnosis_id' = (select id::text from first_request)),
  1, 'o pedido sai uma vez pela outbox'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.request_diagnosis('00000000-0000-4000-8000-0000000005a1', 'hybrid', true, 'req-5')$$,
  '42501', null, 'Viewer não pede Diagnóstico'
);
select is((select count(*)::int from doctor.diagnoses), 2, 'Viewer lê os Diagnósticos da Organização');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner');
select is((select count(*)::int from doctor.diagnoses), 0, 'outra Organização não lê os Diagnósticos');
select tests.clear_authentication();

-- Worker (service_role): roda, grava as filhas e publica.
update doctor.diagnoses set status = 'running', stage = 'verification' where id = (select id from first_request);
select throws_ok(
  $$insert into doctor.diagnosis_evidence (tenant_id, diagnosis_id, rank, kind, label, finding)
    select '00000000-0000-4000-8000-00000000ac01', id, 1, 'event', 'x', 'y' from first_request$$,
  '23514', null, 'Evidência sem referência'
);
select throws_ok(
  $$insert into doctor.diagnosis_evidence (tenant_id, diagnosis_id, rank, kind, rule_match_id, label, finding)
    select '00000000-0000-4000-8000-00000000ac01', id, 1, 'rule_match', '00000000-0000-4000-8000-0000000006b1', 'x', 'y'
    from first_request$$,
  '23503', null, 'Evidência nunca aponta para registro de outra Organização'
);
insert into doctor.diagnosis_evidence (tenant_id, diagnosis_id, rank, kind, rule_match_id, label, finding)
select '00000000-0000-4000-8000-00000000ac01', id, 1, 'rule_match', '00000000-0000-4000-8000-0000000006a1',
  'INT-003', 'Timeout HTTP 504' from first_request;
update doctor.diagnoses set status = 'published', stage = 'done', published_at = now()
where id = (select id from first_request);

select throws_ok(
  $$update doctor.diagnoses set probable_cause = 'outra' where id = (select id from first_request)$$,
  'DR020', null, 'Diagnóstico publicado não muda'
);
select throws_ok(
  $$update doctor.diagnosis_evidence set finding = 'outra' where diagnosis_id = (select id from first_request)$$,
  'DR020', null, 'nem as Evidências'
);
select throws_ok(
  $$insert into doctor.diagnosis_recommendations (tenant_id, diagnosis_id, rank, text, kind)
    select '00000000-0000-4000-8000-00000000ac01', id, 1, 'x', 'verify' from first_request$$,
  'DR020', null, 'nem ganham filhas novas'
);
-- Retenção apaga o registro apontado: a referência zera, o rótulo fica.
delete from doctor.rule_matches where id = '00000000-0000-4000-8000-0000000006a1';
select results_eq(
  $$select rule_match_id, label from doctor.diagnosis_evidence where diagnosis_id = (select id from first_request)$$,
  $$values (null::uuid, 'INT-003'::text)$$,
  'retenção zera a referência sem quebrar a imutabilidade'
);

delete from auth.users where id = '00000000-0000-4000-8000-0000000a0001';
select results_eq(
  $$select requested_by, status from doctor.diagnoses where id = (select id from first_request)$$,
  $$values (null::uuid, 'published'::text)$$,
  'excluir o Usuário zera quem pediu sem quebrar a imutabilidade'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner');
select throws_ok(
  $$select doctor.set_auto_diagnosis(true)$$, '42501', null, 'Owner sem MFA não liga o automático'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2');
select doctor.set_auto_diagnosis(true);
select tests.clear_authentication();
select is(
  (select auto_diagnose_critical from doctor.tenants where id = '00000000-0000-4000-8000-00000000be01'),
  true, 'Owner liga o Diagnóstico automático'
);

select * from finish();
rollback;
