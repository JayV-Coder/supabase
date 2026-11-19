begin;
\ir ../helpers/tenancy.psql
select plan(11);

select has_schema('doctor');
select has_function('doctor', 'current_tenant_id', array[]::text[]);
select has_function('doctor', 'current_tenant_role', array[]::text[]);
select has_function('doctor', 'has_role', array['text[]']);
select has_function('doctor', 'set_updated_at', array[]::text[]);

select tests.clear_authentication();
select is(doctor.current_tenant_id(), null, 'sem JWT não há Organização ativa');
select is(doctor.has_role('owner', 'admin', 'analyst', 'viewer'), false, 'sem JWT nenhum Papel vale');

-- A Organização do JWT só vale com Vínculo (ADR-0026 do jayv-doctor).
select tests.create_user('00000000-0000-4000-8000-0000000000a1', 'ana@schema.test');
select tests.create_tenant('00000000-0000-4000-8000-0000000000aa', 'schema-01');
select tests.add_member('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a1', 'analyst');
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000aa', 'analyst'
);
select is(doctor.current_tenant_id(), '00000000-0000-4000-8000-0000000000aa'::uuid, 'lê tenant_id do JWT');
select is(doctor.current_tenant_role(), 'analyst', 'lê tenant_role do JWT');
select is(doctor.has_role('owner', 'admin'), false, 'analyst não é owner/admin');
select is(doctor.has_role('analyst', 'viewer'), true, 'analyst está na lista');

select * from finish();
rollback;
