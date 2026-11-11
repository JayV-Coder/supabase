begin;
\ir ../helpers/tenancy.psql
select plan(13);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'davi@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'owner');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
create temporary table created as
select doctor.create_connector('00000000-0000-4000-8000-0000000001a1', 'fake', 'Fake', '{"pages": 1}', 's') as id;
grant select on created to public;

select lives_ok(
  format($$select doctor.update_connector(%L, 'Fake renomeado', '{"pages": 2}', 600)$$, (select id from created)),
  'Admin altera nome, config e intervalo'
);
select results_eq(
  $$select name, config ->> 'pages', sync_interval_seconds from doctor.connectors$$,
  $$values ('Fake renomeado'::text, '2'::text, 600)$$,
  'alteração gravada'
);
select lives_ok(format($$select doctor.pause_connector(%L)$$, (select id from created)), 'pausa');
select is((select status from doctor.connectors), 'paused', 'pausado');
select lives_ok(format($$select doctor.resume_connector(%L)$$, (select id from created)), 'retoma');
select lives_ok(format($$select doctor.request_connector_sync(%L)$$, (select id from created)), 'pede Sincronização agora');
select tests.clear_authentication();
select is(
  (select count(*)::int from doctor.outbox_messages
   where topic = 'connector.sync' and payload ->> 'connector_id' = (select id::text from created)),
  1, 'Sincronização enfileirada na outbox'
);

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2'
);
select throws_ok(
  format($$select doctor.pause_connector(%L)$$, (select id from created)), '42501', null, 'Analyst não pausa'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2'
);
select throws_ok(
  format($$select doctor.request_connector_sync(%L)$$, (select id from created)),
  'P0002', null, 'outra Organização não mexe no Conector'
);
select tests.clear_authentication();

-- Pausa manual não volta com credencial nova; pausa por autenticação volta.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select doctor.pause_connector((select id from created));
select doctor.put_connector_secret((select id from created), 'outra');
select is((select status from doctor.connectors), 'paused', 'pausa manual continua depois de trocar a credencial');
select tests.clear_authentication();
update doctor.connectors set paused_reason = 'auth';
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select doctor.put_connector_secret((select id from created), 'corrigida');
select is((select status from doctor.connectors), 'active', 'pausa por autenticação sai com a credencial nova');
select tests.clear_authentication();

update doctor.connectors set status = 'disabled';
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select throws_ok(
  format($$select doctor.resume_connector(%L)$$, (select id from created)), 'DR008', null,
  'Conector desativado não é retomado pela gestão'
);
select tests.clear_authentication();
update doctor.connectors set status = 'active';
insert into doctor.connector_syncs (tenant_id, connector_id) select '00000000-0000-4000-8000-00000000ac01', id from created;
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select throws_ok(
  format($$select doctor.request_connector_sync(%L)$$, (select id from created)), 'DR009', null,
  'com Sincronização em curso, o pedido é recusado'
);
select tests.clear_authentication();

select * from finish();
rollback;
