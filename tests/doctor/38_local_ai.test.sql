begin;
\ir ../helpers/tenancy.psql
select plan(13);

select tests.create_user('00000000-0000-4000-8000-0000000f3001', 'owner@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac31', 'acme-local');
select tests.create_tenant('00000000-0000-4000-8000-00000000be31', 'outra-local');
select tests.add_member('00000000-0000-4000-8000-00000000ac31', '00000000-0000-4000-8000-0000000f3001', 'owner');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment) values
  ('00000000-0000-4000-8000-0000000031a1', '00000000-0000-4000-8000-00000000ac31', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000031b1', '00000000-0000-4000-8000-00000000be31', 'Pedidos', 'salesforce', 'sap', 'prd');
insert into doctor.agents (id, tenant_id, integration_id, name, status, secret_hash, public_key) values
  ('00000000-0000-4000-8000-0000000031a2', '00000000-0000-4000-8000-00000000ac31', '00000000-0000-4000-8000-0000000031a1',
   'SAP', 'active', repeat('a', 64), repeat('A', 43) || '='),
  ('00000000-0000-4000-8000-0000000031b2', '00000000-0000-4000-8000-00000000be31', '00000000-0000-4000-8000-0000000031b1',
   'SAP', 'active', repeat('b', 64), repeat('B', 43) || '=');

set local role service_role;
select throws_ok($$select doctor.set_local_ai('00000000-0000-4000-8000-00000000ac31', 'agent', null, null, 'llama', 60)$$,
  '23514', null, 'pelo agente, o agente é obrigatório');
select lives_ok($$select doctor.set_local_ai('00000000-0000-4000-8000-00000000ac31', 'agent',
  '00000000-0000-4000-8000-0000000031a2', null, 'llama-3.1-70b', 60)$$, 'a operação liga o modo local');
insert into doctor.local_llm_requests (id, tenant_id, agent_id, request) values
  ('00000000-0000-4000-8000-0000000031c1', '00000000-0000-4000-8000-00000000ac31', '00000000-0000-4000-8000-0000000031a2',
   '{"messages": [{"role": "user", "content": "evidência sanitizada"}]}');
reset role;
select is((select ai_profile || '/' || llm_provider from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac31'),
  'local/local', 'perfil e provedor locais');

select tests.authenticate_as_anon();
select is((select count(*)::int from doctor.claim_local_llm(repeat('b', 64))), 0, 'o agente de outra Organização não vê o pedido');
select is((select request -> 'messages' -> 0 ->> 'content' from doctor.claim_local_llm(repeat('a', 64))),
  'evidência sanitizada', 'o agente da Organização busca o pedido');
select is((select count(*)::int from doctor.claim_local_llm(repeat('a', 64))), 0, 'o pedido não sai duas vezes');
select is(doctor.finish_local_llm(repeat('b', 64), '00000000-0000-4000-8000-0000000031c1', '{"x": 1}', null), false,
  'outro agente não responde pelo pedido');
select is(doctor.finish_local_llm(repeat('a', 64), '00000000-0000-4000-8000-0000000031c1', '{"choices": []}', null), true,
  'o agente devolve a resposta');
select throws_ok($$select * from doctor.claim_local_llm(repeat('c', 64))$$, 'DR071', null, 'segredo desconhecido é recusado');
select tests.clear_authentication();

select is((select status || '/' || request::text from doctor.local_llm_requests where id = '00000000-0000-4000-8000-0000000031c1'),
  'done/{}', 'respondido, o prompt sai da fila');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f3001', '00000000-0000-4000-8000-00000000ac31', 'owner', 'aal2');
select throws_ok($$select * from doctor.local_llm_requests$$, '42501', null, 'a fila é só da plataforma');
select throws_ok($$select doctor.set_ai_profile('local')$$, 'DR090', null, 'o local é contratado com a plataforma');
select lives_ok($$select doctor.set_ai_profile('br_region')$$, 'o Owner pode sair do local');
select tests.clear_authentication();

select * from finish();
rollback;
