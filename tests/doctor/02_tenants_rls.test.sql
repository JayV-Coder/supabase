begin;
\ir ../helpers/tenancy.psql
select plan(15);

-- Acme e Varejo são Organizações distintas; Ana pertence à Acme.
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');

select policies_are('doctor', 'tenants', array['tenants_select_own', 'tenants_update_by_admin']);
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.tenants'::regclass), true, 'RLS ligado em tenants'
);

-- Analyst da Acme: vê só a própria Organização e não a altera.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select results_eq(
  'select id from doctor.tenants',
  $$values ('00000000-0000-4000-8000-00000000ac01'::uuid)$$,
  'analyst vê só a Organização ativa'
);
update doctor.tenants set segment = 'Hackeado' where id = '00000000-0000-4000-8000-00000000ac01';
select tests.clear_authentication();
select is(
  (select segment from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'), null,
  'analyst não altera a Organização'
);

-- Admin sem MFA verificado (aal1) não executa ação administrativa.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin');
update doctor.tenants set segment = 'Sem MFA' where id = '00000000-0000-4000-8000-00000000ac01';
select tests.clear_authentication();
select is(
  (select segment from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'), null,
  'admin em aal1 não altera a Organização (MFA obrigatório)'
);
select has_function('doctor', 'current_aal', array[]::text[]);

-- Admin com MFA (aal2): altera a própria, não a dos outros.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
update doctor.tenants set segment = 'Consultoria' where id = '00000000-0000-4000-8000-00000000ac01';
update doctor.tenants set segment = 'Invadida' where id = '00000000-0000-4000-8000-00000000be01';
select tests.clear_authentication();
select is(
  (select segment from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'), 'Consultoria',
  'admin altera a própria Organização'
);
select is(
  (select segment from doctor.tenants where id = '00000000-0000-4000-8000-00000000be01'), null,
  'admin não altera outra Organização'
);

-- Mesmo um admin com MFA não muda plano, não cria nem apaga Organização direto.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select throws_ok(
  $$update doctor.tenants set plan = 'enterprise' where id = '00000000-0000-4000-8000-00000000ac01'$$,
  '42501', null, 'plano não é editável pelo cliente'
);
select throws_ok(
  $$insert into doctor.tenants (id) values ('00000000-0000-4000-8000-00000000be01')$$,
  '42501', null, 'cliente não cria Organização direto (passa pela API)'
);
select throws_ok(
  $$delete from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'$$,
  '42501', null, 'cliente não apaga Organização'
);

-- Sem Organização ativa, nada é visível; anon não tem acesso algum.
select tests.authenticate_without_tenant('00000000-0000-4000-8000-0000000a0001');
select is_empty('select 1 from doctor.tenants', 'sem tenant_id no JWT nada é visível');
select tests.authenticate_as_anon();
select throws_ok('select 1 from doctor.tenants', '42501', null, 'anon não lê tenants');

-- updated_at é do servidor: o trigger ignora o valor enviado.
select tests.clear_authentication();
update doctor.tenants set updated_at = '2000-01-01', segment = 'Varejo'
where id = '00000000-0000-4000-8000-00000000ac01';
select is(
  (select updated_at from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'), now(),
  'trigger define updated_at'
);
select has_trigger('doctor', 'tenants', 'tenants_set_updated_at', 'trigger de updated_at em tenants');

select * from finish();
rollback;
