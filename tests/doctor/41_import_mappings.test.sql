-- Mapeamento de colunas da Importação por Integração (#11): quem importa (Owner, Admin, Analyst)
-- grava; todos da Organização leem; o worker de ingestão lê como plataforma.
begin;
\ir ../helpers/tenancy.psql
select plan(11);

select tests.create_user('00000000-0000-4000-8000-0000000f6001', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f6002', 'viewer@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f6003', 'owner@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac61', 'acme-mapas');
select tests.create_tenant('00000000-0000-4000-8000-00000000be61', 'varejo-mapas');
select tests.add_member('00000000-0000-4000-8000-00000000ac61', '00000000-0000-4000-8000-0000000f6001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac61', '00000000-0000-4000-8000-0000000f6002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be61', '00000000-0000-4000-8000-0000000f6003', 'owner');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment) values
  ('00000000-0000-4000-8000-0000000d6101', '00000000-0000-4000-8000-00000000ac61', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000d6102', '00000000-0000-4000-8000-00000000be61', 'Notas', 'sap', 'other', 'prd');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f6001', '00000000-0000-4000-8000-00000000ac61', 'analyst', 'aal1');
select lives_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101',
  '{"timestamp": "Data/Hora", "message": "Texto da mensagem"}')$$, 'Analyst grava o mapeamento da Integração');
select is((select columns ->> 'timestamp' from doctor.import_mappings), 'Data/Hora', 'o mapeamento fica gravado');
select lives_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101', '{"operation": "BAPI"}')$$,
  'gravar de novo substitui');
select is((select columns::text from doctor.import_mappings), '{"operation": "BAPI"}', 'um mapeamento por Integração');
select throws_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101', '{"cliente": "Nome"}')$$,
  '22023', null, 'só campos do Contrato de evento');
select throws_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101', '{"message": ""}')$$,
  '22023', null, 'coluna vazia não vale');
select throws_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6102', '{"operation": "BAPI"}')$$,
  'P0002', null, 'Integração de outra Organização não existe');
select lives_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101', '{}')$$,
  'mapeamento vazio volta para a detecção pelo nome');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f6002', '00000000-0000-4000-8000-00000000ac61', 'viewer', 'aal1');
select throws_ok($$select doctor.set_import_mapping('00000000-0000-4000-8000-0000000d6101', '{}')$$, '42501', null,
  'Viewer não importa, então não mapeia');
select is((select count(*)::int from doctor.import_mappings), 1, 'mas lê o mapeamento');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f6003', '00000000-0000-4000-8000-00000000be61', 'owner', 'aal2');
select is((select count(*)::int from doctor.import_mappings), 0, 'outra Organização não lê');
select tests.clear_authentication();

select * from finish();
rollback;
