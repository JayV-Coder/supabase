begin;
\ir ../helpers/tenancy.psql
select plan(9);

select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0002', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000b0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000b0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Pedidos', 'salesforce', 'sap', 'prd');

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2');
select throws_ok(
  $$insert into doctor.correlation_mappings (integration_id, name, keys)
    values ('00000000-0000-4000-8000-0000000001a1', 'Pedido', '[{"system": "sap", "field": "execution_id"}]')$$,
  '42501', null, 'Analyst não cria Mapa'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal1');
select throws_ok(
  $$insert into doctor.correlation_mappings (integration_id, name, keys)
    values ('00000000-0000-4000-8000-0000000001a1', 'Pedido', '[{"system": "sap", "field": "execution_id"}]')$$,
  '42501', null, 'Admin sem MFA não cria'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select lives_ok(
  $$insert into doctor.correlation_mappings (integration_id, name, keys, reconcile)
    values ('00000000-0000-4000-8000-0000000001a1', 'Pedido',
      '[{"system": "salesforce", "field": "execution_id"}, {"system": "sap", "field": "attributes.bstkd"}]', true)$$,
  'Admin com MFA cria'
);
select throws_ok(
  $$insert into doctor.correlation_mappings (integration_id, name, keys)
    values ('00000000-0000-4000-8000-0000000001b1', 'Alheio', '[{"system": "sap", "field": "execution_id"}]')$$,
  '23503', null, 'não referencia Integração de outra Organização'
);
select throws_ok(
  $$insert into doctor.correlation_mappings (integration_id, name, keys)
    values ('00000000-0000-4000-8000-0000000001a1', 'Vazio', '[]')$$,
  '23514', null, 'Mapa sem chave não entra'
);
select is((select count(*)::int from doctor.correlation_mappings), 1, 'Admin vê o Mapa');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000b0003', '00000000-0000-4000-8000-00000000be01', 'admin', 'aal2');
select is((select count(*)::int from doctor.correlation_mappings), 0, 'outra Organização não vê');
select is_empty($$delete from doctor.correlation_mappings returning id$$, 'nem apaga');
select tests.clear_authentication();

select lives_ok(
  $$update doctor.events set correlated_by = 'cross_system' where false$$,
  'cross_system é uma estratégia aceita'
);

select * from finish();
rollback;
