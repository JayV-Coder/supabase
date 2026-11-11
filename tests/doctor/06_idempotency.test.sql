begin;
\ir ../helpers/tenancy.psql
select plan(10);

select has_table('doctor', 'idempotency_keys', 'tabela doctor.idempotency_keys existe');
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.idempotency_keys'::regclass), true, 'RLS ligado'
);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
insert into doctor.idempotency_keys (tenant_id, user_id, key, request_hash, response_status, response_body)
values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'k1', 'h', 201, '{}');

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'analyst');
select is_empty($$select 1 from doctor.idempotency_keys$$, 'outra Organização não lê a chave');
select lives_ok(
  $$update doctor.idempotency_keys set response_status = 500 where key = 'k1'$$, 'update alheio não encontra linha'
);
select lives_ok($$delete from doctor.idempotency_keys where key = 'k1'$$, 'delete alheio não encontra linha');
select throws_ok(
  $$insert into doctor.idempotency_keys (tenant_id, key, request_hash)
    values ('00000000-0000-4000-8000-00000000ac01', 'k2', 'h')$$,
  '42501', null, 'não grava chave em outra Organização'
);
select tests.clear_authentication();
select is(
  (select response_status from doctor.idempotency_keys where key = 'k1'), 201, 'a chave da Acme continua intacta'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select is((select count(*)::int from doctor.idempotency_keys), 1, 'quem gravou lê a chave');
select tests.clear_authentication();
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'carla@acme.test');
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'owner');
select is_empty($$select 1 from doctor.idempotency_keys$$, 'outra pessoa da mesma Organização não lê');
select lives_ok($$delete from doctor.idempotency_keys where key = 'k1'$$, 'nem apaga');

select * from finish();
rollback;
