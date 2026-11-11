begin;
\ir ../helpers/tenancy.psql
select plan(16);

select tests.create_user('00000000-0000-4000-8000-0000000f2001', 'owner@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f2002', 'admin@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac21', 'acme-ia');
select tests.add_member('00000000-0000-4000-8000-00000000ac21', '00000000-0000-4000-8000-0000000f2001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac21', '00000000-0000-4000-8000-0000000f2002', 'admin');
insert into public.organizations (id, name, slug) values ('00000000-0000-4000-8000-00000000be21', 'BR', 'br-ia');
insert into doctor.tenants (id, llm_provider) values ('00000000-0000-4000-8000-00000000be21', 'vertex');

select is((select ai_profile || '/' || llm_provider from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac21'),
  'standard/anthropic', 'o padrão é Claude pela API');
select is((select ai_profile from doctor.tenants where id = '00000000-0000-4000-8000-00000000be21'), 'br_region',
  'quem escolheu o Vertex ao criar fica no perfil Brasil');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f2002', '00000000-0000-4000-8000-00000000ac21', 'admin', 'aal2');
select throws_ok($$select doctor.set_ai_profile('br_region')$$, '42501', null, 'Admin não troca o perfil');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f2001', '00000000-0000-4000-8000-00000000ac21', 'owner', 'aal1');
select throws_ok($$select doctor.set_ai_profile('br_region')$$, '42501', null, 'sem MFA, nem o Owner');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f2001', '00000000-0000-4000-8000-00000000ac21', 'owner', 'aal2');
select throws_ok($$select doctor.set_ai_profile('dedicated')$$, 'DR090', null, 'o dedicado é contratado com a plataforma');
select lives_ok($$select doctor.set_ai_profile('br_region')$$, 'Owner com MFA passa para o Brasil');
select is((select llm_provider from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac21'), 'vertex',
  'o provedor segue o perfil');
select throws_ok($$select * from doctor.ai_profile_checks$$, '42501', null, 'as verificações são da plataforma');
select tests.clear_authentication();

select is((select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac21'
  and action = 'org.ai_profile_changed'), 1, 'a troca fica na trilha de auditoria');
select is((select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac21'
  and action = 'org.updated'), 0, 'e só uma vez (a auditoria genérica não a repete)');
update doctor.tenants set llm_provider = 'anthropic' where id = '00000000-0000-4000-8000-00000000be21';
select is((select ai_profile from doctor.tenants where id = '00000000-0000-4000-8000-00000000be21'), 'standard',
  'mudar só o provedor (ADR-0007) muda o perfil junto');

set local role service_role;
select lives_ok($$select doctor.set_dedicated_ai('00000000-0000-4000-8000-00000000ac21', 'cliente-ia-123')$$,
  'a operação liga o dedicado no projeto do cliente');
insert into doctor.ai_profile_checks (profile, target, ok, hosts, region)
values ('dedicated', 'cliente-ia-123', true, '{southamerica-east1-aiplatform.googleapis.com}', 'southamerica-east1');
reset role;
select is((select llm_provider || '/' || ai_project from doctor.tenants where id = '00000000-0000-4000-8000-00000000ac21'),
  'vertex_dedicated/cliente-ia-123', 'dedicado com Provisioned Throughput no projeto do cliente');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f2001', '00000000-0000-4000-8000-00000000ac21', 'owner', 'aal2');
select is((select region from doctor.ai_profile_status()), 'southamerica-east1', 'a tela vê a última verificação do seu perfil');
select lives_ok($$select doctor.set_ai_profile('standard')$$, 'o Owner pode sair do dedicado');
select tests.clear_authentication();
select is((select ai_profile || '/' || llm_provider || '/' || coalesce(ai_project, '-') from doctor.tenants
  where id = '00000000-0000-4000-8000-00000000ac21'), 'standard/anthropic/-', 'saindo do dedicado, o projeto sai junto');

select * from finish();
rollback;
