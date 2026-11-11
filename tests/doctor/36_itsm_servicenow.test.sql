begin;
\ir ../helpers/tenancy.psql
select plan(23);

select tests.create_user('00000000-0000-4000-8000-0000000f1001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f1002', 'viewer@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f1003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac11', 'acme-sn');
select tests.create_tenant('00000000-0000-4000-8000-00000000be11', 'varejo-sn');
select tests.add_member('00000000-0000-4000-8000-00000000ac11', '00000000-0000-4000-8000-0000000f1001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac11', '00000000-0000-4000-8000-0000000f1002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be11', '00000000-0000-4000-8000-0000000f1003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000011a1', '00000000-0000-4000-8000-00000000ac11', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code, rule_version, first_seen_at, last_seen_at)
values ('00000000-0000-4000-8000-0000000012a1', '00000000-0000-4000-8000-00000000ac11',
  '00000000-0000-4000-8000-0000000011a1', 'Timeout', 'TIMEOUT', 'critical', 'INT-003', '2026.10.1', now(), now());

select tests.authenticate_as('00000000-0000-4000-8000-0000000f1001', '00000000-0000-4000-8000-00000000ac11', 'admin', 'aal2');
select throws_ok($$select doctor.request_ticket('00000000-0000-4000-8000-0000000012a1', 'servicenow')$$, 'DR080', null,
  'sem ServiceNow configurado, não há chamado');
select throws_ok($$select doctor.configure_servicenow('https://acme.service-now.com', 'app', null, '{}', '{}', null, true, repeat('h', 40))$$,
  'DR084', null, 'a primeira configuração exige o secret');
select throws_ok($$select doctor.configure_servicenow('https://10.0.0.1', 'app', 's3', '{}', '{}', null, true, repeat('h', 40))$$,
  '23514', null, 'só instâncias service-now.com');
select throws_ok($$select doctor.configure_servicenow('https://acme.service-now.com', 'app', 's3', '{}', '{"erp": "X"}', null, true, repeat('h', 40))$$,
  'DR083', null, 'grupo de Sistema desconhecido é recusado');
select ok(doctor.configure_servicenow('https://acme.service-now.com', 'app', 's3', '{}',
  '{"sap": "SAP Basis", "salesforce": "CRM"}', 'Service Desk', true, repeat('h', 40)) is not null,
  'Admin configura a instância');
select lives_ok($$select doctor.configure_servicenow('https://acme.service-now.com', 'app', null, '{"critical": {"impact": 1, "urgency": 1}}', '{"sap": "SAP N2"}', 'Service Desk', true, null)$$,
  'mudar só os grupos não pede o secret de novo');
select throws_ok($$select doctor.configure_servicenow('https://outra.service-now.com', 'app', null, '{}', '{}', null, true, null)$$,
  'DR084', null, 'outra instância exige o secret de novo');
select lives_ok($$select doctor.configure_servicenow('https://acme.service-now.com', 'app', null, null, '{"sap": "SAP N2"}', 'Service Desk', true, null)$$,
  'sem impact_map, o atual fica');
select is((select impact_map -> 'critical' ->> 'impact' from doctor.itsm_connections where provider = 'servicenow'), '1',
  'o mapa de impacto não volta ao padrão nem some');
select is((select assignment_groups ->> 'sap' from doctor.itsm_connections where provider = 'servicenow'), 'SAP N2',
  'a regra de grupos fica legível na Organização');
select throws_ok($$select secret_id from doctor.itsm_connections where provider = 'servicenow'$$, '42501', null,
  'o id do segredo não é legível');

-- Chamado: um por Incidente e provedor.
select ok(doctor.request_ticket('00000000-0000-4000-8000-0000000012a1', 'servicenow') is not null, 'Admin abre o incident');
select ok(doctor.request_ticket('00000000-0000-4000-8000-0000000012a1', 'servicenow') is null, 'pedir de novo não abre outro');
select throws_ok($$select doctor.request_ticket('00000000-0000-4000-8000-0000000012a1')$$, 'DR080', null,
  'o Jira segue sendo o padrão e não está configurado');
select throws_ok($$select doctor.configure_servicenow('https://nova.service-now.com', 'app', 's4', null, '{}', null, true, null)$$,
  'DR085', null, 'instância nova sem endereço novo do webhook é recusada');
select lives_ok($$select doctor.configure_servicenow('https://nova.service-now.com', 'app', 's4', null, '{}', 'Service Desk', true, repeat('n', 40))$$,
  'trocar de instância com secret e endereço novos');
select tests.clear_authentication();
select is((select decrypted_secret::jsonb ->> 'client_secret' from vault.decrypted_secrets s
  join doctor.itsm_connections c on c.secret_id = s.id where c.provider = 'servicenow'), 's4', 'o secret fica no Vault');
select is((select status || ': ' || error from doctor.incident_tickets where provider = 'servicenow'),
  'failed: A instância do ServiceNow mudou: abra o chamado de novo.', 'o chamado da instância antiga falha e pode ser aberto de novo');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f1002', '00000000-0000-4000-8000-00000000ac11', 'viewer', 'aal2');
select throws_ok($$select doctor.configure_servicenow('https://acme.service-now.com', 'app', 'x', '{}', '{}', null, true, null)$$,
  '42501', null, 'Viewer não configura');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f1003', '00000000-0000-4000-8000-00000000be11', 'admin', 'aal2');
select is((select count(*)::int from doctor.itsm_connections), 0, 'outra Organização não vê a conexão');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(doctor.servicenow_hook(repeat('c', 64), 'INC0010001'), false, 'webhook com token errado não faz nada');
select is(doctor.servicenow_hook(encode(sha256(convert_to(repeat('n', 40), 'UTF8')), 'hex'), 'INC0010001'), true,
  'token certo pede a leitura do incident');
select is(doctor.jira_hook(encode(sha256(convert_to(repeat('n', 40), 'UTF8')), 'hex'), null), false,
  'o token do ServiceNow não vale no webhook do Jira');
select tests.clear_authentication();

select * from finish();
rollback;
