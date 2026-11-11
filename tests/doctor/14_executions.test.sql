begin;
\ir ../helpers/tenancy.psql
select plan(10);

select has_table('doctor', 'executions', 'tabela doctor.executions existe');
select has_table('doctor', 'execution_merges', 'tabela doctor.execution_merges existe');
select is(
  (select bool_and(relrowsecurity) from pg_class
   where oid in ('doctor.executions'::regclass, 'doctor.execution_merges'::regclass)),
  true, 'RLS ligado'
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
   '00000000-0000-4000-8000-0000000001a1', '2026-11-02T14:02:01Z', '2026-11-02T14:02:31Z'),
  ('00000000-0000-4000-8000-0000000004b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000001b1', '2026-11-02T14:02:01Z', '2026-11-02T14:02:31Z');
select doctor.ensure_event_partition('2026-11-02');

create function tests.event(tenant uuid, integration uuid, execution uuid) returns void language sql as $$
  insert into doctor.events (id, tenant_id, integration_id, timestamp, schema_version, source, operation,
    severity, dedup_key, execution_ref, correlated_by)
  values (gen_random_uuid(), tenant, integration, '2026-11-02T14:05:00Z', '1.0',
    '{"provider": "manual", "service": "importacao"}', 'BAPI', 'ERROR', gen_random_uuid()::text,
    execution, 'execution_id')
$$;

select lives_ok(
  $$select tests.event('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
    '00000000-0000-4000-8000-0000000004a1')$$,
  'Evento aponta para a Execução da mesma Organização'
);
select throws_ok(
  $$select tests.event('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
    '00000000-0000-4000-8000-0000000004b1')$$,
  '23503', null, 'FK composta: Evento nunca aponta para a Execução de outra Organização'
);
select throws_ok(
  $$insert into doctor.execution_merges (tenant_id, survivor_id, merged_id)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000004b1', gen_random_uuid())$$,
  '23503', null, 'fusão só dentro da Organização'
);

insert into doctor.executions (id, tenant_id, integration_id, first_event_at, last_event_at, merged_into)
values ('00000000-0000-4000-8000-0000000004b2', '00000000-0000-4000-8000-00000000be01',
  '00000000-0000-4000-8000-0000000001b1', '2026-11-02T14:02:01Z', '2026-11-02T14:02:31Z',
  '00000000-0000-4000-8000-0000000004b1');
insert into doctor.execution_merges (tenant_id, survivor_id, merged_id)
values ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000004b1',
  '00000000-0000-4000-8000-0000000004b2');

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select is(
  (select count(*)::int from doctor.execution_merges), 0,
  'outra Organização não lê o histórico de fusões'
);
select results_eq(
  $$select id::text collate "default" from doctor.executions$$,
  $$values ('00000000-0000-4000-8000-0000000004a1'::text)$$,
  'cada Organização vê só as próprias Execuções'
);
select throws_ok(
  $$update doctor.executions set status = 'success'$$,
  '42501', null, 'cliente não escreve Execuções'
);
select tests.clear_authentication();

delete from doctor.executions where id = '00000000-0000-4000-8000-0000000004a1';
select is(
  (select count(*)::int from doctor.events
   where tenant_id = '00000000-0000-4000-8000-00000000ac01' and execution_ref is null
     and dedup_key <> ''),
  1, 'Execução apagada deixa o Evento, sem a referência'
);

select * from finish();
rollback;
