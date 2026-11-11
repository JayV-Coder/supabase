begin;
\ir ../helpers/tenancy.psql
select plan(17);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'caio@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0003', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'analyst');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code,
  rule_version, first_seen_at, last_seen_at, execution_count)
values ('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1);
insert into doctor.diagnoses (id, tenant_id, incident_id, version, status, stage, requested_mode, mode,
  processing_key, probable_cause, classification, published_at)
values
  ('00000000-0000-4000-8000-0000000009a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000005a1', 1, 'published', 'done', 'hybrid', 'hybrid', 'k1',
   'Gateway lento.', 'UPSTREAM_TIMEOUT', now() - interval '2 minutes'),
  ('00000000-0000-4000-8000-0000000009a2', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000005a1', 2, 'running', 'llm', 'hybrid', 'hybrid', 'k2',
   null, null, null);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'accepted', null, null, null, null)$$,
  '42501', null, 'Viewer não revisa'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'analyst');
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'accepted', null, null, null, null)$$,
  'P0002', null, 'Diagnóstico de outra Organização não existe para quem revisa'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a2', 'accepted', null, null, null, null)$$,
  'DR021', null, 'versão em andamento não é revisada'
);
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'corrected', null, null, null, 'só comentário')$$,
  'DR025', null, 'corrigir exige a categoria ou a causa certa'
);
select throws_ok(
  $$select doctor.promote_incident_to_knowledge('00000000-0000-4000-8000-0000000005a1')$$,
  'DR022', null, 'Incidente aberto não é promovido'
);
select lives_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'corrected',
    'SAP_LOCK', 'Lock na tabela VBAK durante o job noturno.', 'sap', 'Confirmado com o time SAP.')$$,
  'Analyst corrige'
);
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'accepted', null, null, null, null)$$,
  'DR026', null, 'um feedback por revisor por versão'
);
select tests.clear_authentication();

select results_eq(
  $$select verdict, time_to_review_s >= 100, correct_category from doctor.diagnosis_feedback
    where diagnosis_id = '00000000-0000-4000-8000-0000000009a1'$$,
  $$values ('corrected'::text, true, 'SAP_LOCK'::text)$$,
  'feedback com o tempo desde a publicação'
);
select is(
  (select requires_human_review from doctor.diagnoses where id = '00000000-0000-4000-8000-0000000009a1'),
  false, 'correção tira o "Requer revisão"'
);
select results_eq(
  $$select actor_id, after ->> 'verdict', (after ->> 'version')::int from doctor.audit_logs
    where action = 'diagnosis.reviewed' and resource_id = '00000000-0000-4000-8000-0000000009a1'$$,
  $$values ('00000000-0000-4000-8000-0000000a0001'::uuid, 'corrected'::text, 1)$$,
  'a auditoria registra quem revisou, o veredito e a versão'
);
select throws_ok(
  $$update doctor.diagnoses set requires_human_review = true where id = '00000000-0000-4000-8000-0000000009a1'$$,
  'DR020', null, 'publicado não volta a "Requer revisão"'
);

update doctor.diagnoses set status = 'failed', stage = 'done' where id = '00000000-0000-4000-8000-0000000009a2';
update doctor.incidents set status = 'resolved', resolution_note = 'Job noturno remarcado.'
where id = '00000000-0000-4000-8000-0000000005a1';

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000ac01', 'analyst');
create temporary table promoted as
select doctor.promote_incident_to_knowledge('00000000-0000-4000-8000-0000000005a1') as id;
select throws_ok(
  $$select doctor.promote_incident_to_knowledge('00000000-0000-4000-8000-0000000005a1')$$,
  '23505', null, 'um documento por Incidente'
);
select tests.clear_authentication();

select results_eq(
  $$select source, status, body like '%SAP_LOCK%' and body like '%Lock na tabela VBAK%'
      and body like '%Job noturno remarcado.%'
    from doctor.knowledge_documents where id = (select id from promoted)$$,
  $$values ('incident'::text, 'indexing'::text, true)$$,
  'o documento traz a correção e a resolução'
);
select is(
  (select count(*)::int from doctor.outbox_messages
   where topic = 'knowledge.index' and payload ->> 'document_id' = (select id::text from promoted)),
  1, 'e vai para a indexação'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select body from doctor.knowledge_documents$$, '42501', null,
  'o texto bruto do documento promovido não é legível pelos membros'
);
select tests.clear_authentication();

-- Uma versão nova publicada supera a anterior: a antiga não recebe mais revisão.
insert into doctor.diagnoses (tenant_id, incident_id, version, status, stage, requested_mode, mode,
  processing_key, published_at)
values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000005a1', 3, 'published',
  'done', 'rules_only', 'rules_only', 'k3', now());
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select throws_ok(
  $$select doctor.submit_diagnosis_feedback('00000000-0000-4000-8000-0000000009a1', 'accepted', null, null, null, null)$$,
  'DR024', null, 'versão superada não é revisada'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'analyst');
select is((select count(*)::int from doctor.diagnosis_feedback), 0, 'outra Organização não lê o feedback');
select tests.clear_authentication();

select * from finish();
rollback;
