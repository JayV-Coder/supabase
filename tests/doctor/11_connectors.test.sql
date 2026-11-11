begin;
\ir ../helpers/tenancy.psql
select plan(19);

select has_table('doctor', 'connectors', 'tabela doctor.connectors existe');
select has_table('doctor', 'connector_syncs', 'tabela doctor.connector_syncs existe');
select is(
  (select bool_and(relrowsecurity) from pg_class
   where oid in ('doctor.connectors'::regclass, 'doctor.connector_syncs'::regclass)),
  true, 'RLS ligado'
);

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

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
create temporary table created as
select doctor.create_connector(
  '00000000-0000-4000-8000-0000000001a1', 'fake', 'Fake de teste', '{"pages": 1}', 'segredo-do-cliente'
) as id;
grant select on created to public;
select is((select count(*)::int from doctor.connectors), 1, 'Admin com MFA cria o Conector');
select throws_ok(
  $$select secret_id from doctor.connectors$$, '42501', null, 'nem o id do segredo é legível pelo cliente'
);
select throws_ok(
  format($$select doctor.get_connector_secret(%L)$$, (select id from created)),
  '42501', null, 'authenticated não lê a credencial'
);
select throws_ok(
  $$select doctor.create_connector('00000000-0000-4000-8000-0000000001b1', 'fake', 'x', '{}', 's')$$,
  'P0002', null, 'Conector não aponta para Integração de outra Organização'
);
select throws_ok(
  $$select doctor.create_connector('00000000-0000-4000-8000-0000000001a1', 'oracle', 'x', '{}', 's')$$,
  '23514', null, 'provedor fora da lista'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2'
);
select throws_ok(
  $$select doctor.create_connector('00000000-0000-4000-8000-0000000001a1', 'fake', 'x', '{}', 's')$$,
  '42501', null, 'Analyst não cria Conector'
);
select is((select count(*)::int from doctor.connectors), 1, 'Analyst vê os Conectores da Organização');
select tests.clear_authentication();

-- A plataforma (worker de conectores) lê a credencial; a troca vale na hora.
set local role service_role;
select is(
  doctor.get_connector_secret((select id from created)), 'segredo-do-cliente', 'service_role lê a credencial'
);
reset role;
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select lives_ok(
  format($$select doctor.put_connector_secret(%L, 'novo-segredo')$$, (select id from created)),
  'Admin troca a credencial'
);
select tests.clear_authentication();
set local role service_role;
select is(doctor.get_connector_secret((select id from created)), 'novo-segredo', 'a credencial nova vale');
reset role;
update doctor.connectors set status = 'paused', paused_reason = 'auth' where id = (select id from created);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select doctor.put_connector_secret((select id from created), 'segredo-corrigido');
select is((select status from doctor.connectors), 'active', 'credencial nova tira o Conector da pausa por erro de autenticação');
select tests.clear_authentication();

-- Outra Organização não vê nem troca.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2'
);
select is_empty($$select 1 from doctor.connectors$$, 'outra Organização não vê o Conector');
select throws_ok(
  format($$select doctor.put_connector_secret(%L, 'invasor')$$, (select id from created)),
  'P0002', null, 'outra Organização não troca a credencial'
);
select tests.clear_authentication();

insert into doctor.connector_syncs (tenant_id, connector_id, status)
select '00000000-0000-4000-8000-00000000ac01', id, 'succeeded' from created;
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2'
);
select is_empty($$select 1 from doctor.connector_syncs$$, 'nem as Sincronizações');
select tests.clear_authentication();

-- Lote da ingestão vem de um token ou de um Conector, nunca dos dois nem de nenhum.
select throws_ok(
  $$insert into doctor.ingestion_batches (tenant_id, integration_id, events, event_count)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', '[]', 0)$$,
  '23514', null, 'lote sem origem é recusado'
);
select lives_ok(
  format(
    $$insert into doctor.ingestion_batches (tenant_id, integration_id, connector_id, events, event_count)
      values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1', %L, '[]', 0)$$,
    (select id from created)
  ),
  'lote de Conector'
);

select * from finish();
rollback;
