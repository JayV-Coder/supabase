begin;
\ir ../helpers/tenancy.psql
select plan(21);

select has_table('doctor', 'ingestion_tokens', 'tabela doctor.ingestion_tokens existe');
select has_table('doctor', 'ingestion_batches', 'tabela doctor.ingestion_batches existe');

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'davi@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'owner');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Notas', 'sap', 'gcp', 'prd');

-- Admin com MFA cria; o banco guarda só o hash.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
create temporary table created as
select doctor.create_ingestion_token('SAP PI produção', '00000000-0000-4000-8000-0000000001a1', repeat('a', 64), 'aid_ing_AbCd') as id;
select is((select count(*)::int from doctor.ingestion_tokens), 1, 'token criado na Organização');
select throws_ok(
  $$select token_hash from doctor.ingestion_tokens$$, '42501', null, 'o hash não é legível pelo cliente'
);
select throws_ok(
  $$select doctor.create_ingestion_token('x', '00000000-0000-4000-8000-0000000001b1', repeat('b', 64), 'aid_ing_x')$$,
  'P0002', null, 'token não aponta para Integração de outra Organização'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2'
);
select throws_ok(
  $$select doctor.create_ingestion_token('x', '00000000-0000-4000-8000-0000000001a1', repeat('c', 64), 'aid_ing_x')$$,
  '42501', null, 'Analyst não cria token'
);
select is((select count(*)::int from doctor.ingestion_tokens), 1, 'Analyst vê os tokens da Organização');

-- O sistema externo não tem sessão: entra como anon, só pelas funções do token.
select tests.authenticate_as_anon();
select results_eq(
  $$select tenant_id::text, integration_id::text from doctor.resolve_ingestion_token(repeat('a', 64))$$,
  $$values ('00000000-0000-4000-8000-00000000ac01'::text, '00000000-0000-4000-8000-0000000001a1'::text)$$,
  'o tenant sai do token, não do payload'
);
select throws_ok(
  $$select * from doctor.resolve_ingestion_token(repeat('f', 64))$$, 'DR006', null, 'token desconhecido'
);
select lives_ok(
  $$select doctor.accept_ingestion_batch(repeat('a', 64), '[{"event_id": "x"}]'::jsonb)$$,
  'aceita o lote'
);
select throws_ok($$select 1 from doctor.ingestion_batches$$, '42501', null, 'anon não lê lotes');
select throws_ok($$select 1 from doctor.ingestion_tokens$$, '42501', null, 'anon não lista tokens');
select tests.clear_authentication();
select results_eq(
  $$select b.tenant_id::text, b.event_count, o.topic, t.last_used_at is not null
    from doctor.ingestion_batches b
    join doctor.outbox_messages o on o.payload ->> 'batch_id' = b.id::text
    join doctor.ingestion_tokens t on t.id = b.token_id$$,
  $$values ('00000000-0000-4000-8000-00000000ac01'::text, 1, 'ingestion.raw'::text, true)$$,
  'lote gravado no tenant do token, com mensagem ingestion.raw e uso registrado'
);

-- Revogado não entra mais; outra Organização não revoga nem vê.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2'
);
select is_empty($$select 1 from doctor.ingestion_tokens$$, 'outra Organização não vê o token');
select throws_ok(
  format($$select doctor.revoke_ingestion_token(%L)$$, (select id from created)),
  'P0002', null, 'outra Organização não revoga'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select lives_ok(format($$select doctor.revoke_ingestion_token(%L)$$, (select id from created)), 'Admin revoga');
select tests.authenticate_as_anon();
select throws_ok(
  $$select * from doctor.resolve_ingestion_token(repeat('a', 64))$$, 'DR006', null, 'token revogado não entra'
);
select tests.clear_authentication();

-- Integração arquivada também fecha o token.
insert into doctor.ingestion_tokens (tenant_id, name, integration_id, token_hash, prefix)
values ('00000000-0000-4000-8000-00000000ac01', 'outro', '00000000-0000-4000-8000-0000000001a1', repeat('d', 64), 'aid_ing_d');
update doctor.integrations set archived_at = now() where id = '00000000-0000-4000-8000-0000000001a1';
select tests.authenticate_as_anon();
select throws_ok(
  $$select * from doctor.resolve_ingestion_token(repeat('d', 64))$$, 'DR006', null, 'Integração arquivada não recebe Eventos'
);
select tests.clear_authentication();
select is(
  has_function_privilege('authenticated', 'doctor.accept_ingestion_batch(text, jsonb)', 'execute'), true,
  'a função é a única porta, para anon e autenticado'
);
select is(
  has_table_privilege('anon', 'doctor.ingestion_tokens', 'select'), false, 'anon sem select direto'
);

select results_eq(
  $$select p.proname::text collate "default" from pg_proc p where p.pronamespace = 'doctor'::regnamespace
    and has_function_privilege('anon', p.oid, 'execute') and p.proname not in ('open_report_share', 'record_report_share_access', 'register_agent', 'resolve_agent', 'agent_seen', 'accept_agent_batch', 'jira_hook', 'servicenow_hook', 'claim_local_llm', 'finish_local_llm') order by 1$$,
  $$values ('accept_ingestion_batch'::text), ('resolve_ingestion_token'::text)$$,
  'anon executa só as duas funções do token (fora o link do Relatório, #32)'
);

select * from finish();
rollback;
