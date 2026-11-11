begin;
\ir ../helpers/tenancy.psql
select plan(5);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
insert into doctor.raw_log_objects (id, tenant_id, storage_path, sha256, size_bytes, source, expires_at)
values
  ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-00000000ac01/api/lote.json', repeat('a', 64), 10, 'api', now() + interval '1 day'),
  ('00000000-0000-4000-8000-0000000002a2', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-00000000ac01/api/velho.json', repeat('b', 64), 10, 'api', now() - interval '1 day'),
  ('00000000-0000-4000-8000-0000000002b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-00000000be01/api/lote.json', repeat('c', 64), 10, 'api', now() + interval '1 day');

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select is(
  doctor.request_raw_log_download('00000000-0000-4000-8000-0000000002a1'),
  '00000000-0000-4000-8000-00000000ac01/api/lote.json',
  'Analyst recebe o caminho do Log bruto da própria Organização'
);
select throws_ok(
  $$select doctor.request_raw_log_download('00000000-0000-4000-8000-0000000002b1')$$,
  'P0002', null, 'Log bruto de outra Organização não existe para ela'
);
select throws_ok(
  $$select doctor.request_raw_log_download('00000000-0000-4000-8000-0000000002a2')$$,
  'P0002', null, 'Log bruto vencido pela retenção não é entregue'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.request_raw_log_download('00000000-0000-4000-8000-0000000002a1')$$,
  '42501', null, 'Viewer não baixa o Log bruto'
);
select tests.clear_authentication();

select is(
  has_function_privilege('anon', 'doctor.request_raw_log_download(uuid)', 'execute'), false,
  'anon não chama a função'
);

select * from finish();
rollback;
