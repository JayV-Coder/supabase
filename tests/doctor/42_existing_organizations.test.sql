-- Organização que já existe no jayv-coder: aparece no Doctor, o owner ativa o produto e os
-- membros entram com o Papel equivalente; quem o Doctor removeu não volta sozinho.
begin;
\ir ../helpers/tenancy.psql
select plan(25);

select tests.create_user('00000000-0000-4000-8000-00000042a001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000042b001', 'bruno@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000042c001', 'carla@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000042d001', 'dani@fora.test');
select tests.create_user('00000000-0000-4000-8000-00000042e001', 'elisa@acme.test');

-- Só no jayv-coder: sem linha em doctor.tenants.
insert into public.organizations (id, name, slug)
values ('00000000-0000-4000-8000-0000004200a1', 'Acme', 'acme-42');
insert into public.organization_members (org_id, user_id, role) values
  ('00000000-0000-4000-8000-0000004200a1', '00000000-0000-4000-8000-00000042a001', 'owner'),
  ('00000000-0000-4000-8000-0000004200a1', '00000000-0000-4000-8000-00000042b001', 'maintainer'),
  ('00000000-0000-4000-8000-0000004200a1', '00000000-0000-4000-8000-00000042c001', 'member');

select has_function('doctor', 'available_organizations', array[]::text[], 'available_organizations existe');
select has_function('doctor', 'enable_organization', array['uuid', 'text', 'text'], 'enable_organization existe');
select has_function('doctor', 'join_organizations', array[]::text[], 'join_organizations existe');

-- Antes de ativar: a Organização aparece para quem é dela, com o Papel do jayv-coder.
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042a001');
select results_eq(
  $$select id, name, slug, coder_role from doctor.available_organizations()$$,
  $$values ('00000000-0000-4000-8000-0000004200a1'::uuid, 'Acme'::text, 'acme-42'::text, 'owner'::text)$$,
  'owner vê a Organização do jayv-coder ainda sem o Doctor'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042b001');
select is(
  (select coder_role from doctor.available_organizations()), 'maintainer', 'maintainer também a vê, com o Papel dele'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042d001');
select is((select count(*) from doctor.available_organizations()), 0::bigint, 'quem não é membro não a vê');

-- Só o owner do jayv-coder ativa.
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042b001');
select throws_ok(
  $$select doctor.enable_organization('00000000-0000-4000-8000-0000004200a1', 'Indústria', 'anthropic')$$,
  '42501', null, 'maintainer não ativa o Doctor'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042d001');
select throws_ok(
  $$select doctor.enable_organization('00000000-0000-4000-8000-0000004200a1', 'Indústria', 'anthropic')$$,
  'P0002', null, 'quem não é membro recebe o mesmo que se ela não existisse'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042a001');
select throws_ok(
  $$select doctor.enable_organization('00000000-0000-4000-8000-0000004200a1', 'x', 'anthropic')$$,
  '23514', null, 'segmento curto demais é recusado'
);
select is(
  doctor.enable_organization('00000000-0000-4000-8000-0000004200a1', 'Indústria', 'vertex'),
  '00000000-0000-4000-8000-0000004200a1'::uuid, 'owner ativa o Doctor na Organização que já existe'
);
select tests.clear_authentication();

select results_eq(
  $$select segment, llm_provider, ai_profile, dpa_accepted_at is not null, status
    from doctor.tenants where id = '00000000-0000-4000-8000-0000004200a1'$$,
  $$values ('Indústria'::text, 'vertex'::text, 'br_region'::text, true, 'active'::text)$$,
  'a ativação grava segmento, perfil de IA e o aceite do DPA'
);
select is((select count(*) from public.organizations where slug = 'acme-42'), 1::bigint, 'nenhuma Organização nova');
select results_eq(
  $$select user_id, role from doctor.memberships
    where tenant_id = '00000000-0000-4000-8000-0000004200a1' order by role$$,
  $$values ('00000000-0000-4000-8000-00000042b001'::uuid, 'admin'::text),
           ('00000000-0000-4000-8000-00000042a001'::uuid, 'owner'::text),
           ('00000000-0000-4000-8000-00000042c001'::uuid, 'viewer'::text)$$,
  'membros entram com o Papel equivalente: owner, maintainer→admin, member→viewer'
);
select is(
  (select tenant_id from doctor.user_active_tenant where user_id = '00000000-0000-4000-8000-00000042a001'),
  '00000000-0000-4000-8000-0000004200a1'::uuid, 'quem ativou fica com ela ativa'
);

select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042a001');
select throws_ok(
  $$select doctor.enable_organization('00000000-0000-4000-8000-0000004200a1', 'Indústria', 'anthropic')$$,
  '23505', null, 'ativar de novo é recusado'
);
select is((select count(*) from doctor.available_organizations()), 0::bigint, 'ativada, sai da lista de disponíveis');

-- Quem entra no jayv-coder depois ganha o acesso no próximo acesso ao Doctor.
select tests.clear_authentication();
insert into public.organization_members (org_id, user_id, role)
values ('00000000-0000-4000-8000-0000004200a1', '00000000-0000-4000-8000-00000042e001', 'member');
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042e001');
select is((select count(*) from doctor.list_organizations()), 0::bigint, 'antes de entrar no Doctor, sem Vínculo');
select lives_ok($$select doctor.join_organizations()$$, 'join_organizations cria o Vínculo que falta');
select results_eq(
  $$select id, role from doctor.list_organizations()$$,
  $$values ('00000000-0000-4000-8000-0000004200a1'::uuid, 'viewer'::text)$$,
  'membro novo do jayv-coder entra como viewer'
);
select lives_ok($$select doctor.join_organizations()$$, 'join_organizations é idempotente');

-- Removido pelo Doctor não volta sozinho.
select tests.authenticate_as(
  '00000000-0000-4000-8000-00000042a001', '00000000-0000-4000-8000-0000004200a1', 'owner', 'aal2'
);
select lives_ok(
  $$select doctor.remove_member((select id from doctor.memberships
    where user_id = '00000000-0000-4000-8000-00000042c001'))$$,
  'owner remove a carla do Doctor'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042c001');
select doctor.join_organizations();
select is((select count(*) from doctor.list_organizations()), 0::bigint, 'removida pelo Doctor, não volta no próximo acesso');

-- Organização suspensa no Doctor não recebe Vínculos novos.
select tests.clear_authentication();
update doctor.tenants set status = 'suspended' where id = '00000000-0000-4000-8000-0000004200a1';
insert into public.organization_members (org_id, user_id, role)
values ('00000000-0000-4000-8000-0000004200a1', '00000000-0000-4000-8000-00000042d001', 'member');
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000042d001');
select doctor.join_organizations();
select is(
  (select count(*) from doctor.memberships where user_id = '00000000-0000-4000-8000-00000042d001'), 0::bigint,
  'suspensa, não dá acesso automático'
);

select tests.clear_authentication();
select is(has_function_privilege('anon', 'doctor.enable_organization(uuid, text, text)', 'execute'), false, 'anon não ativa');
select is(has_function_privilege('anon', 'doctor.join_organizations()', 'execute'), false, 'anon não entra');

select * from finish();
rollback;
