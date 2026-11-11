begin;
\ir ../helpers/tenancy.psql
select plan(7);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'viewer');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Notas', 'sap', 'gcp', 'prd');
insert into doctor.executions (tenant_id, integration_id, status, first_event_at, last_event_at)
values
  ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', 'failed', '2026-11-02T14:05:00Z', '2026-11-02T14:05:00Z'),
  ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', 'success', '2026-11-02T14:35:00Z', '2026-11-02T14:35:00Z'),
  ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000001b1', 'failed', '2026-11-02T14:05:00Z', '2026-11-02T14:05:00Z');

select doctor.refresh_execution_stats();
select doctor.refresh_execution_stats();
select results_eq(
  $$select total, failed from doctor.execution_stats_hourly
    where integration_id = '00000000-0000-4000-8000-0000000001a1'$$,
  $$values (2, 1)$$,
  'recalcular de novo não conta duas vezes'
);

-- O primeiro Evento recua de hora (Importação tardia): as duas horas se acertam.
update doctor.executions set first_event_at = '2026-11-02T13:50:00Z', last_event_at = '2026-11-02T13:50:00Z'
where integration_id = '00000000-0000-4000-8000-0000000001a1' and status = 'failed';
select doctor.refresh_execution_stats();
select results_eq(
  $$select hour, total, failed from doctor.execution_stats_hourly
    where integration_id = '00000000-0000-4000-8000-0000000001a1' order by hour$$,
  $$values ('2026-11-02T13:00:00Z'::timestamptz, 1, 1), ('2026-11-02T14:00:00Z'::timestamptz, 1, 0)$$,
  'a hora antiga sai e a nova entra'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select is(
  (select count(*)::int from doctor.execution_stats_hourly
   where tenant_id <> '00000000-0000-4000-8000-00000000ac01'),
  0, 'outra Organização não lê o agregado'
);
select throws_ok(
  $$select doctor.refresh_execution_stats()$$,
  '42501', null, 'cliente não recalcula o agregado'
);
select throws_ok(
  $$insert into doctor.execution_stats_hourly (tenant_id, integration_id, hour)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', '2026-11-02T10:00:00Z')$$,
  '42501', null, 'cliente não escreve no agregado'
);
select throws_ok(
  $$delete from doctor.execution_stats_hourly$$,
  '42501', null, 'nem apaga'
);
select tests.clear_authentication();

select is(
  has_function_privilege('anon', 'doctor.refresh_execution_stats(integer)', 'execute'), false,
  'anon também não'
);

select * from finish();
rollback;
