begin;
\ir ../helpers/tenancy.psql
select plan(25);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'viewer@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'analyst@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000a0003', 'analyst');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code,
  rule_version, first_seen_at, last_seen_at, execution_count)
values
  ('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000001a1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1),
  ('00000000-0000-4000-8000-0000000005b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-0000000001b1', 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1);
-- v1 publicado e v2 na fila: o relatório usa o Diagnóstico atual que já terminou (v1).
insert into doctor.diagnoses (id, tenant_id, incident_id, version, status, requested_mode, mode, processing_key)
values
  ('00000000-0000-4000-8000-0000000009a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000005a1', 1, 'published', 'rules_only', 'rules_only', 'k1'),
  ('00000000-0000-4000-8000-0000000009a2', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-0000000005a1', 2, 'queued', 'rules_only', 'rules_only', 'k2');

-- Pedido: Analyst ou acima, idempotente, com a mensagem para o worker.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.request_report('00000000-0000-4000-8000-0000000005a1', 'pdf', true, false, 'r1')$$,
  '42501', null, 'Viewer não gera relatório'
);
select is((select count(*)::int from doctor.reports), 0, 'Viewer lê a lista (vazia ainda)');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select is(
  (select created from doctor.request_report('00000000-0000-4000-8000-0000000005a1', 'pdf', true, false, 'r1')),
  true, 'Analyst pede o relatório'
);
select is(
  (select created from doctor.request_report('00000000-0000-4000-8000-0000000005a1', 'pdf', true, false, 'r1')),
  false, 'a mesma chave devolve o mesmo relatório'
);
select throws_ok(
  $$select doctor.request_report('00000000-0000-4000-8000-0000000005a1', 'docx', false, false, 'r2')$$,
  '22023', null, 'formato fora de pdf/md é recusado'
);
select throws_ok(
  $$select doctor.request_report('00000000-0000-4000-8000-0000000005b1', 'md', false, false, 'r3')$$,
  'P0002', null, 'Incidente de outra Organização não existe para quem pede'
);
select tests.clear_authentication();
select results_eq(
  $$select r.diagnosis_id, r.status from doctor.reports r
    where r.tenant_id = '00000000-0000-4000-8000-00000000ac01'$$,
  $$values ('00000000-0000-4000-8000-0000000009a1'::uuid, 'queued'::text)$$,
  'um relatório, na fila, do Diagnóstico atual que já terminou'
);
select is(
  (select count(*)::int from doctor.outbox_messages
   where topic = 'report.requested' and payload ->> 'report_id' = (select id::text from doctor.reports
     where tenant_id = '00000000-0000-4000-8000-00000000ac01')),
  1, 'e uma mensagem para o worker'
);

-- Link compartilhável: só de relatório pronto, 7 dias, revogável e auditado.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select throws_ok(
  $$select doctor.create_report_share((select id from doctor.reports), repeat('a', 64), 'https://storage.test/a')$$,
  'DR060', null, 'relatório ainda na fila não é compartilhado'
);
select tests.clear_authentication();
update doctor.reports set status = 'ready', storage_path = tenant_id || '/' || id || '.pdf',
  size_bytes = 10, content_sha256 = repeat('c', 64), completed_at = now()
where tenant_id = '00000000-0000-4000-8000-00000000ac01';
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select ok(
  s.expires_at between now() + interval '7 days' - interval '1 minute' and now() + interval '7 days',
  'link vale 7 dias'
)
from doctor.create_report_share((select id from doctor.reports), repeat('a', 64), 'https://storage.test/a') s;
select throws_ok(
  $$select token_hash from doctor.report_shares$$, '42501', null,
  'o hash do token e a URL assinada não são lidos pela tela'
);
select is((select count(*)::int from doctor.report_shares where revoked_at is null), 1, 'a tela vê o link ativo');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000be01', 'analyst');
select is((select count(*)::int from doctor.reports), 0, 'outra Organização não vê o relatório');
select is((select count(*)::int from doctor.report_shares), 0, 'nem o link');
select tests.clear_authentication();

-- Quem tem o link abre sem sessão; cada acesso fica na trilha.
select tests.authenticate_as_anon();
select results_eq(
  $$select download_url, format from doctor.open_report_share(repeat('a', 64))$$,
  $$values ('https://storage.test/a'::text, 'pdf'::text)$$,
  'o link abre sem sessão'
);
select throws_ok($$select access_count from doctor.report_shares$$, '42501', null, 'anon não lê a tabela');
select lives_ok($$select doctor.record_report_share_access(repeat('a', 64))$$,
  'o acesso conta depois de o arquivo ser entregue');
select tests.clear_authentication();
select is((select access_count from doctor.report_shares where token_hash = repeat('a', 64)), 1,
  'um acesso contado');
-- Organização suspensa: o link para de abrir.
update doctor.tenants set status = 'suspended' where id = '00000000-0000-4000-8000-00000000ac01';
select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.open_report_share(repeat('a', 64))), 0,
  'Organização suspensa não serve o link');
select tests.clear_authentication();
update doctor.tenants set status = 'active' where id = '00000000-0000-4000-8000-00000000ac01';
-- Quem compartilhou perdeu o Papel: o link também para.
update doctor.memberships set role = 'viewer' where user_id = '00000000-0000-4000-8000-0000000a0001';
select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.open_report_share(repeat('a', 64))), 0,
  'quem compartilhou já não é Analyst: o link não abre');
select is((select count(*)::int from doctor.open_report_share(repeat('b', 64))), 0, 'token errado não abre');
select tests.clear_authentication();
update doctor.memberships set role = 'analyst' where user_id = '00000000-0000-4000-8000-0000000a0001';
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select lives_ok(
  $$select doctor.revoke_report_share((select id from doctor.report_shares))$$, 'Analyst revoga o link'
);
select tests.clear_authentication();
select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.open_report_share(repeat('a', 64))), 0, 'link revogado não abre');
select tests.clear_authentication();
update doctor.report_shares set revoked_at = null, expires_at = now() - interval '1 minute'
where tenant_id = '00000000-0000-4000-8000-00000000ac01';
select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.open_report_share(repeat('a', 64))), 0, 'nem o vencido');
select tests.clear_authentication();
select results_eq(
  $$select action from doctor.audit_logs
    where tenant_id = '00000000-0000-4000-8000-00000000ac01' and resource_type = 'report' order by action collate "C"$$,
  $$values ('report.requested'::text), ('report.share_accessed'), ('report.share_revoked'), ('report.shared')$$,
  'pedido, compartilhamento, acesso e revogação na trilha'
);

select * from finish();
rollback;
