begin;
\ir ../helpers/tenancy.psql
select plan(7);

select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');

-- O traceparent da sessão vai para a mensagem da outbox.
select set_config('doctor.traceparent', '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01', true);
insert into doctor.outbox_messages (tenant_id, topic, payload)
values ('00000000-0000-4000-8000-00000000ac01', 'ingestion.raw', '{}');
select is(
  (select traceparent from doctor.outbox_messages order by id desc limit 1),
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
  'a mensagem leva o traceparent de quem a gravou'
);
-- Valor que não é traceparent não entra (a sessão não injeta texto qualquer).
select set_config('doctor.traceparent', 'qualquer coisa', true);
insert into doctor.outbox_messages (tenant_id, topic, payload)
values ('00000000-0000-4000-8000-00000000ac01', 'ingestion.raw', '{}');
select is((select traceparent from doctor.outbox_messages order by id desc limit 1), null,
  'valor inválido fica de fora');
select set_config('doctor.traceparent', '', true);
insert into doctor.outbox_messages (tenant_id, topic, payload)
values ('00000000-0000-4000-8000-00000000ac01', 'ingestion.raw', '{}');
select is((select traceparent from doctor.outbox_messages order by id desc limit 1), null,
  'fora de um trace, sem traceparent');

-- Medidas da plataforma: só números, sem tenant.
select ok((select (doctor.platform_health() ->> 'outbox_pending')::int >= 3), 'conta a outbox pendente');
select ok((select (doctor.platform_health() ->> 'outbox_lag_seconds')::float >= 0), 'e a idade da mais antiga');
select ok(
  (select bool_and(jsonb_typeof(value) = 'number') from jsonb_each(doctor.platform_health())),
  'tudo número: nada de tenant_id nem texto do cliente'
);
select tests.authenticate_as_anon();
select throws_ok($$select doctor.platform_health()$$, '42501', null, 'só a plataforma lê as medidas');
select tests.clear_authentication();

select * from finish();
rollback;
