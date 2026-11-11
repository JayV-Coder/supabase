begin;
\ir ../helpers/tenancy.psql
select plan(27);

select has_table('doctor', 'integrations', 'tabela doctor.integrations existe');
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.integrations'::regclass), true, 'RLS ligado'
);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'davi@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'owner');

-- Admin com MFA cadastra; o tenant vem do JWT, não do payload.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select lives_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'prd')$$,
  'Admin com MFA cadastra Integração'
);
select results_eq(
  $$select tenant_id::text, created_by::text from doctor.integrations$$,
  $$values ('00000000-0000-4000-8000-00000000ac01'::text, '00000000-0000-4000-8000-0000000a0001'::text)$$,
  'tenant e autor saem do JWT'
);
select throws_ok(
  $$insert into doctor.integrations (tenant_id, name, source_system, target_system, environment)
    values ('00000000-0000-4000-8000-00000000be01', 'Invasora', 'sap', 'gcp', 'prd')$$,
  '42501', null, 'o payload não escolhe o tenant'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'prd')$$,
  '23505', null, 'nome e Ambiente repetidos no mesmo tenant'
);
select lives_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'hml')$$,
  'mesmo nome em outro Ambiente'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Clientes', 'sap', 'salesforce', 'qa')$$,
  '23514', null, 'Ambiente fora de dev, hml e prd'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Clientes', 'oracle', 'salesforce', 'prd')$$,
  '23514', null, 'sistema fora da lista'
);
select throws_ok(
  $$delete from doctor.integrations$$, '42501', null, 'não há exclusão física: só arquivamento'
);
select lives_ok(
  $$update doctor.integrations set archived_at = now() where environment = 'hml'$$, 'Admin arquiva'
);
select is_empty(
  $$update doctor.integrations set name = 'Renomeada' where environment = 'hml' returning id$$,
  'arquivada fica congelada'
);
select lives_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'hml')$$,
  'o nome da arquivada volta a ficar livre'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'hml')$$,
  '23505', null, 'entre as ativas, nome e Ambiente seguem únicos'
);
select throws_ok(
  $$update doctor.integrations set tenant_id = '00000000-0000-4000-8000-00000000be01'$$,
  '42501', null, 'tenant não muda por update'
);

-- Admin sem MFA e Analyst leem, mas não escrevem.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal1'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Notas', 'sap', 'gcp', 'prd')$$,
  '42501', null, 'Admin sem MFA não cadastra'
);
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst', 'aal2'
);
select is((select count(*)::int from doctor.integrations), 3, 'Analyst lê as Integrações da Organização');
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Notas', 'sap', 'gcp', 'prd')$$,
  '42501', null, 'Analyst não cadastra'
);
select is_empty(
  $$update doctor.integrations set name = 'Renomeada' returning id$$, 'Analyst não altera'
);

-- O Papel vale o da tabela, não o da claim: Analyst com claim de Admin continua barrado.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal2'
);
select throws_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Notas', 'sap', 'gcp', 'prd')$$,
  '42501', null, 'claim de Papel atrasada não dá escrita'
);

-- Isolamento: a outra Organização não lê, não altera e pode repetir o nome.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2'
);
select is_empty($$select 1 from doctor.integrations$$, 'outra Organização não lê');
select is_empty(
  $$update doctor.integrations set name = 'Invadida' returning id$$, 'outra Organização não altera'
);
select lives_ok(
  $$insert into doctor.integrations (name, source_system, target_system, environment)
    values ('Pedidos Salesforce → SAP', 'salesforce', 'sap', 'prd')$$,
  'o mesmo nome vale em outra Organização'
);
select tests.clear_authentication();

-- FK composta: um registro do Varejo não aponta para a Integração da Acme.
create table tests.integration_children (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  integration_id uuid not null,
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id)
);
select throws_ok(
  $$insert into tests.integration_children (tenant_id, integration_id)
    select '00000000-0000-4000-8000-00000000be01', id from doctor.integrations
    where tenant_id = '00000000-0000-4000-8000-00000000ac01' and environment = 'prd'$$,
  '23503', null, 'referência à Integração de outro tenant falha no banco'
);
select lives_ok(
  $$insert into tests.integration_children (tenant_id, integration_id)
    select tenant_id, id from doctor.integrations
    where tenant_id = '00000000-0000-4000-8000-00000000ac01' and environment = 'prd'$$,
  'referência no mesmo tenant vale'
);

select is(
  (select count(*)::int from doctor.integrations where environment = 'hml' and archived_at is not null), 1,
  'a arquivada continua no banco'
);
select is(
  has_table_privilege('anon', 'doctor.integrations', 'select'), false, 'anon não lê Integrações'
);

select * from finish();
rollback;
