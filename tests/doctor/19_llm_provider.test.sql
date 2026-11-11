begin;
\ir ../helpers/tenancy.psql
select plan(2);

select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select is(
  (select llm_provider from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'),
  'anthropic', 'Organização nova usa o provedor padrão'
);
select throws_ok(
  $$update doctor.tenants set llm_provider = 'openai' where id = '00000000-0000-4000-8000-00000000ac01'$$,
  '23514', null, 'só provedores com implementação'
);

select * from finish();
rollback;
