-- #49, MFA obrigatório para todos os Papéis: com a política ligada, sessão sem o segundo fator
-- (aal1) não lê nada da Organização (RLS, doctor_read e Realtime), e o motivo é dado.
begin;
\ir ../helpers/tenancy.psql
select plan(16);

select tests.create_user('00000000-0000-4000-8000-00000045a001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000045b001', 'bia@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-0000004500a1', 'acme-45');
select tests.add_member('00000000-0000-4000-8000-0000004500a1', '00000000-0000-4000-8000-00000045a001', 'admin');
select tests.add_member('00000000-0000-4000-8000-0000004500a1', '00000000-0000-4000-8000-00000045b001', 'viewer');
insert into doctor.integrations (tenant_id, name, environment, source_system, target_system)
values ('00000000-0000-4000-8000-0000004500a1', 'Pedidos', 'prd', 'sap', 'salesforce');

select has_column('doctor', 'tenants', 'require_mfa', 'tenants.require_mfa existe');
select col_default_is('doctor', 'tenants', 'require_mfa', 'false', 'desligada por padrão');

-- Quem liga e desliga: Owner ou Admin, com MFA.
select tests.authenticate_as('00000000-0000-4000-8000-00000045b001', '00000000-0000-4000-8000-0000004500a1', 'viewer', 'aal2');
select throws_ok($$select doctor.set_require_mfa(true)$$, '42501', null, 'viewer não liga');
select tests.authenticate_as('00000000-0000-4000-8000-00000045a001', '00000000-0000-4000-8000-0000004500a1', 'admin', 'aal1');
select throws_ok($$select doctor.set_require_mfa(true)$$, '42501', null, 'admin sem MFA não liga');
select tests.authenticate_as('00000000-0000-4000-8000-00000045a001', '00000000-0000-4000-8000-0000004500a1', 'admin', 'aal2');
select lives_ok($$select doctor.set_require_mfa(true)$$, 'admin com MFA liga');
select is((select require_mfa from doctor.tenants where id = '00000000-0000-4000-8000-0000004500a1'), true, 'ficou ligada');
select is(doctor.access_problem(), null, 'com MFA, nenhum problema de acesso');
select is((select count(*) from doctor.integrations), 1::bigint, 'com MFA, lê');

-- Sessão sem o segundo fator.
select tests.authenticate_as('00000000-0000-4000-8000-00000045b001', '00000000-0000-4000-8000-0000004500a1', 'viewer', 'aal1');
select is(doctor.current_tenant_id(), null, 'sem MFA, a Organização não vale');
select is(doctor.access_problem(), 'mfa_required', 'sem MFA, o motivo é o MFA');
select is((select count(*) from doctor.integrations), 0::bigint, 'sem MFA, o RLS não devolve nada');
select throws_ok($$select doctor_read.integrations()$$, 'DR112', null, 'sem MFA, a leitura direta pede o MFA');
select is((doctor_read.me() ->> 'mfa_required')::boolean, true, 'me: avisa que falta o MFA');

-- Desligada, aal1 volta a ler; worker sem Usuário nunca é afetado.
select tests.authenticate_as('00000000-0000-4000-8000-00000045a001', '00000000-0000-4000-8000-0000004500a1', 'admin', 'aal2');
select doctor.set_require_mfa(false);
select tests.authenticate_as('00000000-0000-4000-8000-00000045b001', '00000000-0000-4000-8000-0000004500a1', 'viewer', 'aal1');
select is((select count(*) from doctor.integrations), 1::bigint, 'desligada, aal1 lê');
select tests.clear_authentication();
update doctor.tenants set require_mfa = true where id = '00000000-0000-4000-8000-0000004500a1';
select set_config('request.jwt.claims', '{"role": "authenticated", "tenant_id": "00000000-0000-4000-8000-0000004500a1"}', true);
set local role authenticated;
select is((select count(*) from doctor.integrations), 1::bigint, 'worker sem Usuário segue lendo');
reset role;
select tests.clear_authentication();
select is(has_function_privilege('anon', 'doctor.set_require_mfa(boolean)', 'execute'), false, 'anon não muda a política');

select * from finish();
rollback;
