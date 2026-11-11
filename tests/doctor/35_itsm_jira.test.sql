begin;
\ir ../helpers/tenancy.psql
select plan(13);

select tests.create_user('00000000-0000-4000-8000-0000000f0001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f0002', 'viewer@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f0003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000f0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000f0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000f0003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code, rule_version, first_seen_at, last_seen_at)
values ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'critical', 'INT-003', '2026.10.1', now(), now());

-- Conexão: state de uso único, tokens no Vault.
select tests.authenticate_as('00000000-0000-4000-8000-0000000f0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select lives_ok($$select doctor.start_itsm_oauth(repeat('a', 64))$$, 'Admin começa a autorização');
select throws_ok($$select doctor.request_ticket('00000000-0000-4000-8000-0000000002a1')$$, 'DR080', null,
  'sem Jira configurado, não há chamado');
select ok(doctor.finish_itsm_oauth(repeat('a', 64), '{"access_token": "x"}',
  '[{"id": "cloud-1", "name": "acme", "url": "https://acme.atlassian.net"}]') is not null, 'a volta conecta');
select throws_ok($$select doctor.finish_itsm_oauth(repeat('a', 64), '{}', '[]')$$, 'DR081', null, 'o state não serve de novo');
select throws_ok($$select doctor.configure_jira('outro-site', 'SUST', 'Incidente', '{}', '{}', true, repeat('b', 64))$$,
  'DR082', null, 'site fora da autorização é recusado');
select lives_ok($$select doctor.configure_jira('cloud-1', 'SUST', 'Incidente', '{"critical": "Highest"}', '{}', true, repeat('b', 64))$$,
  'Admin configura o projeto');
select throws_ok($$select secret_id from doctor.itsm_connections$$, '42501', null, 'o id do segredo não é legível');

-- Chamado: uma vez por Incidente, à mão ou por Regra.
select ok(doctor.request_ticket('00000000-0000-4000-8000-0000000002a1') is not null, 'Admin abre o chamado');
select ok(doctor.request_ticket('00000000-0000-4000-8000-0000000002a1') is null, 'pedir de novo não abre outro');
select tests.clear_authentication();
select is((select count(*)::int from doctor.outbox_messages where topic = 'itsm.ticket'), 1, 'uma mensagem só');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f0002', '00000000-0000-4000-8000-00000000ac01', 'viewer', 'aal2');
select throws_ok($$select doctor.request_ticket('00000000-0000-4000-8000-0000000002a1')$$, '42501', null, 'Viewer não abre chamado');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is(doctor.jira_hook(repeat('c', 64), null), false, 'webhook com token errado não faz nada');
select is(doctor.jira_hook(encode(sha256(convert_to(repeat('b', 64), 'UTF8')), 'hex'), 'SUST-1'), true,
  'token certo pede a sincronização');
select tests.clear_authentication();

select * from finish();
rollback;
