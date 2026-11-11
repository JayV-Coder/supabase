begin;
\ir ../helpers/tenancy.psql
select plan(29);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'owner@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'analyst@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0003', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000a0001', 'owner');
select doctor.ensure_event_partition(now()::date);
select doctor.ensure_event_partition((now() - interval '100 days')::date);

-- Políticas: Owner/Admin com MFA, dentro dos limites; a auditoria nunca abaixo de 365 dias.
select is(doctor.effective_retention('00000000-0000-4000-8000-00000000ac01', 'raw_logs'), 30, 'padrão do PRD: Logs brutos 30 dias');
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select throws_ok($$select doctor.set_retention_policy('raw_logs', 15)$$, '42501', null, 'Analyst não muda a retenção');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select throws_ok(
  $$select doctor.effective_retention('00000000-0000-4000-8000-00000000be01', 'audit')$$,
  '42501', null, 'cliente não lê a retenção de outra Organização'
);
select is(doctor.my_retention('events'), 90, 'só a da Organização ativa');
select throws_ok($$select doctor.set_retention_policy('audit', 90)$$, 'DR040', null, 'auditoria não fica abaixo de 365 dias');
select throws_ok($$select doctor.set_retention_policy('raw_logs', 1000)$$, 'DR040', null, 'nem acima do limite');
select lives_ok($$select doctor.set_retention_policy('raw_logs', 7)$$, 'Admin com MFA ajusta');
select lives_ok($$select doctor.set_llm_enabled(false)$$, 'e desliga o envio ao LLM');
select throws_ok($$select doctor.request_tenant_deletion('acme')$$, '42501', null, 'Admin não pede a exclusão total');
select tests.clear_authentication();
select is(
  (select llm_enabled from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac01'), false,
  'LLM desligado para a Organização'
);
select is(
  (select count(*)::int from doctor.audit_logs
   where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'retention_policy.created'),
  1, 'mudança de retenção auditada'
);

-- Logs brutos vencidos pela retenção da Organização (7 dias).
insert into doctor.raw_log_objects (id, tenant_id, storage_path, sha256, size_bytes, source, created_at, expires_at)
values
  ('00000000-0000-4000-8000-0000000002a1', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-00000000ac01/api/velho.json', repeat('a', 64), 10, 'api', now() - interval '10 days', now() + interval '20 days'),
  ('00000000-0000-4000-8000-0000000002a2', '00000000-0000-4000-8000-00000000ac01',
   '00000000-0000-4000-8000-00000000ac01/api/novo.json', repeat('b', 64), 10, 'api', now() - interval '1 day', now() + interval '20 days'),
  ('00000000-0000-4000-8000-0000000002b1', '00000000-0000-4000-8000-00000000be01',
   '00000000-0000-4000-8000-00000000be01/api/b.json', repeat('c', 64), 10, 'api', now() - interval '10 days', now() + interval '20 days');
select results_eq(
  $$select id from doctor.expired_raw_logs(100)
    where tenant_id in ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000be01')$$,
  $$values ('00000000-0000-4000-8000-0000000002a1'::uuid)$$,
  'vence o Log de 10 dias de A (retenção 7) e não o de B (padrão 30)'
);
select is(doctor.forget_raw_logs(array['00000000-0000-4000-8000-0000000002a1'::uuid]), 1, 'e a linha sai');

-- Purga por Organização: Incidente resolvido antigo sai, aberto fica; Eventos e auditoria antigos saem.
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code, rule_version,
  first_seen_at, last_seen_at, execution_count, status, resolved_at, resolution_note)
values
  ('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
   'Antigo', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now() - interval '200 days', now() - interval '200 days', 1,
   'resolved', now() - interval '199 days', 'ok'),
  ('00000000-0000-4000-8000-0000000005a2', '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
   'Aberto', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now() - interval '200 days', now() - interval '200 days', 1,
   'open', null, null);
insert into doctor.events (id, tenant_id, integration_id, timestamp, schema_version, source, operation, severity, dedup_key)
values
  (gen_random_uuid(), '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
   now() - interval '100 days', '1.0', '{}', 'BAPI', 'ERROR', 'velho'),
  (gen_random_uuid(), '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1',
   now(), '1.0', '{}', 'BAPI', 'ERROR', 'novo');
insert into doctor.audit_logs (tenant_id, occurred_at, actor_type, action)
values ('00000000-0000-4000-8000-00000000ac01', now() - interval '400 days', 'system', 'teste.antigo');
select results_eq(
  $$select (c ->> 'incidents')::int, (c ->> 'events')::int, (c ->> 'audit')::int
    from doctor.purge_tenant_data('00000000-0000-4000-8000-00000000ac01', 1) c$$,
  $$values (1, 1, 1)$$,
  'purga o Incidente resolvido, o Evento e a auditoria vencidos'
);
select is(
  (select array_agg(title) from doctor.incidents where tenant_id = '00000000-0000-4000-8000-00000000ac01'),
  array['Aberto'], 'Incidente aberto não sai'
);
select is(
  (select (after ->> 'raw_logs')::int from doctor.audit_logs
   where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'retention.purge'),
  1, 'a execução fica na trilha (retention.purge)'
);

-- Partição inteira que ninguém mais precisa sai com drop.
select doctor.ensure_event_partition('2024-01-15');
select ok('events_2024_01' = any(doctor.drop_expired_partitions()), 'partição de Eventos vencida sai inteira');
select is(to_regclass('doctor.events_2024_01'), null, 'e não existe mais');

-- Titular: localizar e apagar pela Referência (HMAC), sem gravar a Referência na trilha.
update doctor.events set business_reference = 'hmac:' || repeat('f', 64)
where tenant_id = '00000000-0000-4000-8000-00000000ac01';
insert into doctor.executions (id, tenant_id, integration_id, first_event_at, last_event_at, correlation_keys)
values ('00000000-0000-4000-8000-0000000004a1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', now(), now(),
  jsonb_build_object('business_reference', jsonb_build_array('hmac:' || repeat('f', 64), 'hmac:outra')));
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select is((select events from doctor.find_subject_events('hmac:' || repeat('f', 64))), 2::bigint,
  'acha os Eventos e as Execuções do titular');
select is(doctor.erase_subject_events('hmac:' || repeat('f', 64)), 1::bigint, 'e apaga');
select tests.clear_authentication();
select is(
  (select correlation_keys -> 'business_reference' from doctor.executions
   where id = '00000000-0000-4000-8000-0000000004a1'),
  '["hmac:outra"]'::jsonb, 'a Referência sai também das chaves da Execução'
);
select is(
  (select after::text not like '%hmac%' from doctor.audit_logs
   where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'subject.erased'),
  true, 'a trilha guarda a quantidade, não a Referência'
);

-- Exclusão total: Owner com MFA, digitando o slug; carência de 7 dias.
insert into doctor.connectors (id, tenant_id, integration_id, provider, name, secret_id)
values ('00000000-0000-4000-8000-000000000ca1', '00000000-0000-4000-8000-00000000ac01',
  '00000000-0000-4000-8000-0000000001a1', 'gcp', 'Logging', vault.create_secret('{}', 'doctor/connector/teste-exclusao'));
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'owner', 'aal2');
select throws_ok($$select doctor.request_tenant_deletion('outra')$$, 'DR041', null, 'slug errado não confirma');
select ok(doctor.request_tenant_deletion('acme') > now() + interval '6 days', 'Owner pede, com 7 dias de carência');
select tests.clear_authentication();
select throws_ok(
  $$select doctor.purge_tenant('00000000-0000-4000-8000-00000000ac01', 0)$$, 'DR042', null,
  'na carência, nada é apagado'
);
update doctor.tenants set deletion_scheduled_for = now() - interval '1 minute'
where id = '00000000-0000-4000-8000-00000000ac01';
select ok(doctor.purge_tenant('00000000-0000-4000-8000-00000000ac01', 3) is not null, 'vencida a carência, apaga');
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
   where c.relnamespace = 'doctor'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
     and c.relname <> 'deletion_receipts'
     and case
       when exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id')
       then (xpath('/row/n/text()', query_to_xml(format(
         'select count(*) as n from doctor.%I where tenant_id = %L', c.relname,
         '00000000-0000-4000-8000-00000000ac01'), false, true, '')))[1]::text::int > 0
       else false
     end),
  null, 'nenhuma tabela do Doctor guarda o tenant_id apagado'
);
select is(
  (select count(*)::int from vault.secrets where name = 'doctor/connector/teste-exclusao'), 0,
  'nem o Vault'
);
select results_eq(
  $$select (removed ->> 'storage_objects')::int, (removed ->> 'vault_secrets')::int
    from doctor.deletion_receipts where tenant_id = '00000000-0000-4000-8000-00000000ac01'$$,
  $$values (3, 1)$$,
  'o comprovante fica, com as contagens'
);

select * from finish();
rollback;
