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

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000aa', 'analyst'
);
select is(doctor.current_tenant_id(), '00000000-0000-4000-8000-0000000000aa'::uuid, 'lê tenant_id do JWT');
select is(doctor.current_tenant_role(), 'analyst', 'lê tenant_role do JWT');
select is(doctor.has_role('owner', 'admin'), false, 'analyst não é owner/admin');
select is(doctor.has_role('analyst', 'viewer'), true, 'analyst está na lista');

select * from finish();
rollback;
