begin;
\ir ../helpers/tenancy.psql
select plan(18);

select has_table('doctor', 'events', 'tabela doctor.events existe');
select is(
  (select relkind::text from pg_class where oid = 'doctor.events'::regclass), 'p', 'events é particionada'
);
select has_table('doctor', 'import_rejections', 'tabela doctor.import_rejections existe');
select is(
  (select bool_and(relrowsecurity) from pg_class
   where oid in ('doctor.events'::regclass, 'doctor.import_rejections'::regclass)),
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

-- Partições mensais criadas sob demanda pela plataforma, idempotente.
select lives_ok($$select doctor.ensure_event_partition('2026-11-17')$$, 'cria a partição do mês');
select lives_ok($$select doctor.ensure_event_partition('2026-11-02')$$, 'de novo, sem erro');
select is(
  (select count(*)::int from pg_inherits i join pg_class c on c.oid = i.inhrelid
   where i.inhparent = 'doctor.events'::regclass and c.relname = 'events_2026_11'),
  1, 'uma partição só para o mês'
);
select is(
  (select relrowsecurity from pg_class where relname = 'events_2026_11' and relnamespace = 'doctor'::regnamespace),
  true, 'a partição também tem RLS'
);
select is(
  has_function_privilege('authenticated', 'doctor.ensure_event_partition(date)', 'execute'), false,
  'cliente não cria partição'
);

create function tests.event(tenant uuid, integration uuid, dedup text) returns void language sql as $$
  insert into doctor.events (id, tenant_id, integration_id, timestamp, schema_version, source, operation, severity, dedup_key)
  values (gen_random_uuid(), tenant, integration, '2026-11-02T14:05:00Z', '1.0',
    '{"provider": "manual", "service": "importacao"}', 'BAPI', 'ERROR', dedup)
$$;
select tests.event('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', 'd1');
insert into doctor.raw_log_objects (id, tenant_id, storage_path, sha256, size_bytes, source)
values ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-00000000ac01/imports/x/upload.csv', repeat('a', 64), 10, 'import');
insert into doctor.imports (id, tenant_id, integration_id, raw_log_object_id, filename, size_bytes, sha256, format, status)
values ('00000000-0000-4000-8000-0000000003a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-0000000002a1', 'f.csv', 10, repeat('a', 64), 'csv', 'done');
insert into doctor.import_rejections (tenant_id, import_id, line_number, reason)
values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000003a1', 3, 'JSON inválido');
select tests.event('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000001b1', 'd1');

select throws_ok(
  $$select tests.event('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', 'd1')$$,
  '23505', null, 'mesmo dedup_key no mesmo tenant não entra duas vezes'
);
select throws_ok(
  $$select tests.event('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000001a1', 'd2')$$,
  '23503', null, 'Evento não aponta para a Integração de outro tenant'
);
select throws_ok(
  $$insert into doctor.events (id, tenant_id, integration_id, timestamp, schema_version, source, operation, severity, dedup_key)
    values (gen_random_uuid(), '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
      '2031-01-01T00:00:00Z', '1.0', '{}', 'x', 'INFO', 'd3')$$,
  '23514', null, 'sem partição para o mês, o insert falha em vez de cair num lugar errado'
);

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer'
);
select results_eq(
  $$select tenant_id::text from doctor.events$$,
  $$values ('00000000-0000-4000-8000-00000000ac01'::text)$$,
  'cada Organização lê só os próprios Eventos'
);
select throws_ok(
  $$select 1 from doctor.events_2026_11$$, '42501', null, 'a partição não é lida direto, só pela tabela-mãe'
);
select throws_ok(
  $$select tests.event('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', 'd9')$$,
  '42501', null, 'cliente não grava Evento'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'viewer'
);
select is((select count(*)::int from doctor.events), 1, 'a outra Organização vê só o seu');
select is_empty($$select 1 from doctor.import_rejections$$, 'nem as rejeições de Importação da outra');
select tests.clear_authentication();
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer'
);
select is((select count(*)::int from doctor.import_rejections), 1, 'cada Organização lê as próprias rejeições');
select tests.clear_authentication();

select * from finish();
rollback;
