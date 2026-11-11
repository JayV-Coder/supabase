begin;
\ir ../helpers/tenancy.psql
select plan(12);

select tests.create_user('00000000-0000-4000-8000-0000000e0001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000e0002', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000e0003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000e0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000e0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000e0003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');

select tests.authenticate_as('00000000-0000-4000-8000-0000000e0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2');
select throws_ok(
  $$select doctor.create_webhook('ITSM', 'https://hooks.acme.test/aid', array['incident.opened'], 'whsec_x')$$,
  '42501', null, 'Analyst não cria webhook'
);
select is((select count(*)::int from doctor.webhooks), 0, 'nem vê os webhooks');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000e0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select ok(
  doctor.create_webhook('ITSM', 'https://hooks.acme.test/aid', array['incident.opened', 'incident.resolved'], 'whsec_x') is not null,
  'Admin cria webhook'
);
select throws_ok(
  $$select doctor.create_webhook('Velho', 'http://hooks.acme.test/aid', array['incident.opened'], 'whsec_y')$$,
  '23514', null, 'só HTTPS'
);
select throws_ok(
  $$select doctor.create_webhook('Evento', 'https://hooks.acme.test/x', array['incident.deleted'], 'whsec_y')$$,
  '23514', null, 'só os eventos da lista'
);
select throws_ok($$select secret_id from doctor.webhooks$$, '42501', null, 'o id do segredo não é legível');
select tests.clear_authentication();

-- Eventos: Incidente aberto, resolvido, e a contagem de Execuções não dispara.
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code, rule_version, first_seen_at, last_seen_at)
values ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now());
update doctor.incidents set execution_count = execution_count + 1 where id = '00000000-0000-4000-8000-0000000002a1';
update doctor.incidents set severity = 'critical' where id = '00000000-0000-4000-8000-0000000002a1';
update doctor.incidents set status = 'resolved', resolved_at = now(), resolution_note = 'Timeout do gateway ajustado.' where id = '00000000-0000-4000-8000-0000000002a1';
select results_eq(
  $$select event from doctor.webhook_deliveries order by created_at, event$$,
  $$values ('incident.opened'::text), ('incident.resolved')$$,
  'aberto e resolvido; atualizado não estava na inscrição'
);
select is(
  (select count(*)::int from doctor.outbox_messages where topic = 'webhook.deliver'),
  2, 'uma mensagem por entrega'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000e0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select ok(
  doctor.resend_webhook_delivery((select id from doctor.webhook_deliveries where event = 'incident.opened')) is not null,
  'Admin reenvia uma entrega'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000e0003', '00000000-0000-4000-8000-00000000be01', 'admin', 'aal2');
select is((select count(*)::int from doctor.webhooks) + (select count(*)::int from doctor.webhook_deliveries), 0,
  'outra Organização não vê webhooks nem entregas');
select throws_ok(
  $$select doctor.resend_webhook_delivery((select id from doctor.webhook_deliveries limit 1))$$,
  'P0002', null, 'nem reenvia'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000e0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select doctor.delete_webhook((select id from doctor.webhooks));
select tests.clear_authentication();
select is((select count(*)::int from vault.secrets where name like 'doctor/webhook/%'), 0, 'apagar tira o segredo do Vault');

select * from finish();
rollback;
