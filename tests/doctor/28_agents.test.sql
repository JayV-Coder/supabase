begin;
\ir ../helpers/tenancy.psql
select plan(18);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'admin@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000a0003', 'admin');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');

-- Só Owner/Admin com MFA cria.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2');
select throws_ok(
  $$select doctor.create_agent('SAP ECC', '00000000-0000-4000-8000-0000000001a1', repeat('a', 64), '{"collections": []}')$$,
  '42501', null, 'Analyst não cria agente'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select ok(
  doctor.create_agent('SAP ECC', '00000000-0000-4000-8000-0000000001a1', repeat('a', 64), '{"collections": []}') is not null,
  'Admin com MFA cria, com token de registro'
);
select throws_ok($$select registration_token_hash from doctor.agents$$, '42501', null, 'a tela não lê os hashes');
select is((select status from doctor.agents), 'pending', 'pendente até o registro');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000be01', 'admin', 'aal2');
select is((select count(*)::int from doctor.agents), 0, 'outra Organização não vê o agente');
select tests.clear_authentication();

-- Registro: token de uso único; depois, o segredo e a chave pública.
select tests.authenticate_as_anon();
select throws_ok(
  $$select * from doctor.register_agent(repeat('b', 64), repeat('c', 64), repeat('A', 43) || '=', repeat('d', 64), '0.1.0')$$,
  'DR070', null, 'token errado não registra'
);
select is(
  (select integration_id from doctor.register_agent(repeat('a', 64), repeat('c', 64), repeat('A', 43) || '=', repeat('d', 64), '0.1.0')),
  '00000000-0000-4000-8000-0000000001a1'::uuid, 'token certo registra'
);
select throws_ok(
  $$select * from doctor.register_agent(repeat('a', 64), repeat('e', 64), repeat('B', 43) || '=', repeat('f', 64), '0.1.0')$$,
  'DR070', null, 'o mesmo token não serve de novo'
);
select is((select public_key from doctor.resolve_agent(repeat('c', 64))), repeat('A', 43) || '=', 'o segredo resolve o agente');
select is((select count(*)::int from doctor.resolve_agent(repeat('9', 64))), 0, 'segredo errado não resolve');
select ok(doctor.accept_agent_batch(repeat('c', 64), '[{"x": 1}]') is not null, 'o agente envia um lote');
select tests.clear_authentication();
select is(
  (select count(*)::int from doctor.ingestion_batches where agent_id = (select id from doctor.agents)),
  1, 'lote gravado com a origem no agente'
);
select is(
  (select count(*)::int from doctor.outbox_messages where topic = 'ingestion.raw'
   and payload ->> 'batch_id' in (select id::text from doctor.ingestion_batches where agent_id is not null)),
  1, 'e a mensagem para a ingestão'
);

-- Revogar vale na próxima chamada.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select lives_ok($$select doctor.revoke_agent((select id from doctor.agents))$$, 'Admin revoga');
select tests.clear_authentication();
select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.resolve_agent(repeat('c', 64))), 0, 'revogado não resolve');
select throws_ok($$select doctor.accept_agent_batch(repeat('c', 64), '[]')$$, 'DR071', null, 'nem envia lote');
select tests.clear_authentication();
select results_eq(
  $$select action from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01'
    and resource_type = 'agent' order by action collate "C"$$,
  $$values ('agent.created'::text), ('agent.registered'), ('agent.revoked')$$,
  'criação, registro e revogação na trilha'
);
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2');
select throws_ok($$select doctor.rotate_agent((select id from doctor.agents), repeat('7', 64))$$, 'P0002', null,
  'revogado não volta por rotação');
select tests.clear_authentication();

select * from finish();
rollback;
