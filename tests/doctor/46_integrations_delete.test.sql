-- Excluir Integração (complementa o #10 do jayv-doctor): Owner ou Admin com MFA excluem a que
-- não tem histórico; com Execuções, Eventos, Conectores, Importações..., o banco recusa (arquivar).
begin;
\ir ../helpers/tenancy.psql
select plan(9);

select tests.create_user('00000000-0000-4000-8000-00000046a001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000046b001', 'bia@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000046c001', 'caio@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-0000004600a1', 'acme-46');
select tests.create_tenant('00000000-0000-4000-8000-0000004600b1', 'varejo-46');
select tests.add_member('00000000-0000-4000-8000-0000004600a1', '00000000-0000-4000-8000-00000046a001', 'admin');
select tests.add_member('00000000-0000-4000-8000-0000004600a1', '00000000-0000-4000-8000-00000046b001', 'viewer');
select tests.add_member('00000000-0000-4000-8000-0000004600b1', '00000000-0000-4000-8000-00000046c001', 'owner');
insert into doctor.integrations (id, tenant_id, name, environment, source_system, target_system) values
  ('00000000-0000-4000-8000-0000004601a1', '00000000-0000-4000-8000-0000004600a1', 'Sem histórico', 'prd', 'sap', 'salesforce'),
  ('00000000-0000-4000-8000-0000004601a2', '00000000-0000-4000-8000-0000004600a1', 'Com Execução', 'prd', 'sap', 'gcp');
insert into doctor.executions (tenant_id, integration_id, status, first_event_at, last_event_at, correlation_keys) values
  ('00000000-0000-4000-8000-0000004600a1', '00000000-0000-4000-8000-0000004601a2', 'failed', now(), now(), '{}');
insert into doctor.correlation_mappings (tenant_id, integration_id, name, keys)
values ('00000000-0000-4000-8000-0000004600a1', '00000000-0000-4000-8000-0000004601a1', 'Pedido', '[{"system": "sap", "field": "execution_id"}]');

-- Quem não pode: o RLS não deixa ver a linha para excluir (nada sai).
create function pg_temp.remaining() returns bigint language sql security definer as
  $$select count(*) from doctor.integrations where tenant_id = '00000000-0000-4000-8000-0000004600a1'$$;
select tests.authenticate_as('00000000-0000-4000-8000-00000046b001', '00000000-0000-4000-8000-0000004600a1', 'viewer', 'aal2');
delete from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a1';
select is(pg_temp.remaining(), 2::bigint, 'viewer não exclui');
select tests.authenticate_as('00000000-0000-4000-8000-00000046a001', '00000000-0000-4000-8000-0000004600a1', 'admin', 'aal1');
delete from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a1';
select is(pg_temp.remaining(), 2::bigint, 'admin sem MFA não exclui');
select tests.authenticate_as('00000000-0000-4000-8000-00000046c001', '00000000-0000-4000-8000-0000004600b1', 'owner', 'aal2');
delete from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a1';
select is(pg_temp.remaining(), 2::bigint, 'outra Organização não exclui');

-- Admin com MFA.
select tests.authenticate_as('00000000-0000-4000-8000-00000046a001', '00000000-0000-4000-8000-0000004600a1', 'admin', 'aal2');
select throws_ok(
  $$delete from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a2'$$, '23503', null,
  'com Execução, o banco recusa'
);
select lives_ok($$delete from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a1'$$, 'sem histórico, exclui');
select tests.clear_authentication();
select is((select count(*) from doctor.integrations where id = '00000000-0000-4000-8000-0000004601a1'), 0::bigint, 'saiu do banco');
select is((select count(*) from doctor.correlation_mappings where integration_id = '00000000-0000-4000-8000-0000004601a1'), 0::bigint, 'os Mapas dela saem junto');
select is(
  (select count(*) from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-0000004600a1' and action = 'integration.deleted'),
  1::bigint, 'a exclusão vai para a trilha de auditoria'
);
select is(has_table_privilege('anon', 'doctor.integrations', 'delete'), false, 'anon não exclui');

select * from finish();
rollback;
