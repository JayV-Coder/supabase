begin;
\ir ../helpers/tenancy.psql
select plan(39);

select has_table('doctor', 'memberships', 'tabela doctor.memberships existe');
select has_table('doctor', 'user_active_tenant', 'tabela doctor.user_active_tenant existe');
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.memberships'::regclass), true, 'RLS ligado em memberships'
);
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.user_active_tenant'::regclass), true,
  'RLS ligado em user_active_tenant'
);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo-brasil');
select tests.create_tenant('00000000-0000-4000-8000-00000000cc01', 'industria-meridional');

select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000a0001', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'admin');
insert into public.organization_members (org_id, user_id, role)
values ('00000000-0000-4000-8000-00000000cc01', '00000000-0000-4000-8000-0000000b0001', 'member');

select throws_ok(
  $$insert into doctor.memberships (tenant_id, user_id, role)
    values ('00000000-0000-4000-8000-00000000cc01', '00000000-0000-4000-8000-0000000b0001', 'root')$$,
  '23514', null, 'Papel fora da lista é recusado'
);
select throws_ok(
  $$insert into doctor.user_active_tenant (user_id, tenant_id)
    values ('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000cc01')$$,
  '23503', null, 'Organização ativa exige Vínculo'
);

-- Custom Access Token Hook
insert into doctor.user_active_tenant (user_id, tenant_id)
values ('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01');

create function tests.hook_claims(user_id uuid, claims jsonb default '{"role": "authenticated"}')
returns jsonb
language sql
as $$
  select doctor.custom_access_token_hook(jsonb_build_object('user_id', user_id, 'claims', claims)) -> 'claims'
$$;

select is(
  tests.hook_claims('00000000-0000-4000-8000-0000000a0001') ->> 'tenant_id',
  '00000000-0000-4000-8000-00000000ac01', 'hook injeta o tenant ativo'
);
select is(
  tests.hook_claims('00000000-0000-4000-8000-0000000a0001') ->> 'tenant_role', 'owner', 'hook injeta o Papel do Vínculo'
);
select is(
  tests.hook_claims('00000000-0000-4000-8000-0000000a0001') ->> 'role', 'authenticated', 'hook preserva as demais claims'
);
select is(
  tests.hook_claims(
    '00000000-0000-4000-8000-0000000b0001',
    '{"role": "authenticated", "tenant_id": "00000000-0000-4000-8000-00000000ac01", "tenant_role": "owner"}'
  ) ->> 'tenant_id',
  null, 'sem Organização ativa, claims antigas de tenant somem'
);

select is(
  has_function_privilege('authenticated', 'doctor.custom_access_token_hook(jsonb)', 'execute'), false,
  'authenticated não executa o hook'
);
select is(
  has_function_privilege('supabase_auth_admin', 'doctor.custom_access_token_hook(jsonb)', 'execute'), true,
  'supabase_auth_admin executa o hook'
);

-- Isolamento
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'owner', 'aal2'
);
select results_eq(
  $$select o.slug from doctor.tenants t join public.organizations o on o.id = t.id$$,
  $$values ('acme'::text)$$,
  'em doctor.tenants, o Usuário só lê a Organização ativa'
);
select results_eq(
  $$select slug, role from doctor.list_organizations() order by slug$$,
  $$values ('acme'::text, 'owner'::text), ('varejo-brasil'::text, 'viewer'::text)$$,
  'o seletor lista as Organizações com Vínculo, e não as outras'
);
select results_eq(
  $$select count(*)::int from doctor.memberships where tenant_id <> doctor.current_tenant_id()$$,
  $$values (0)$$,
  'Vínculos fora da Organização ativa ficam ocultos, mesmo os próprios'
);
select results_eq(
  $$select tenant_id::text from doctor.memberships where user_id <> auth.uid()$$,
  $$select null::text where false$$,
  'Vínculos de outras pessoas em Organização não ativa ficam ocultos'
);
select lives_ok(
  $$select doctor.switch_organization('00000000-0000-4000-8000-00000000be01')$$, 'troca para Organização com Vínculo'
);
select throws_ok(
  $$select doctor.switch_organization('00000000-0000-4000-8000-00000000cc01')$$,
  '42501', null, 'troca sem Vínculo é recusada'
);
select results_eq(
  $$select tenant_id::text from doctor.user_active_tenant$$,
  $$values ('00000000-0000-4000-8000-00000000be01'::text)$$,
  'a troca recusada não muda a Organização ativa'
);
select throws_ok(
  $$update doctor.user_active_tenant set tenant_id = '00000000-0000-4000-8000-00000000ac01'$$,
  '42501', null, 'Organização ativa não muda por escrita direta'
);
select throws_ok(
  $$insert into doctor.memberships (tenant_id, user_id, role)
    values ('00000000-0000-4000-8000-00000000cc01', auth.uid(), 'owner')$$,
  '42501', null, 'Usuário não cria Vínculo por escrita direta'
);

select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'admin', 'aal2'
);
select is(
  (select count(*)::int from doctor.memberships), 2, 'na Organização ativa, o Usuário vê todos os Vínculos dela'
);
select is(
  (select count(*)::int from doctor.user_active_tenant), 0, 'Organização ativa de outra pessoa fica oculta'
);

-- Criação de Organização
select tests.authenticate_without_tenant('00000000-0000-4000-8000-0000000b0001');
select lives_ok(
  $$select doctor.create_organization('Nova Org', 'nova-org', 'Varejo', 'vertex')$$, 'cria a Organização'
);
select tests.clear_authentication();
select results_eq(
  $$select m.role, t.llm_provider, t.dpa_accepted_at is not null, a.tenant_id = t.id
    from doctor.tenants t
    join public.organizations o on o.id = t.id
    join doctor.memberships m on m.tenant_id = t.id
    join doctor.user_active_tenant a on a.user_id = m.user_id
    where o.slug = 'nova-org' and m.user_id = '00000000-0000-4000-8000-0000000b0001'$$,
  $$values ('owner'::text, 'vertex'::text, true, true)$$,
  'quem cria vira Owner, aceita o DPA e passa a agir na nova Organização'
);

-- Remover o Vínculo tira as claims na renovação seguinte.
-- O Vínculo é o de public: remover no jayv-coder tira o acesso ao Doctor.
delete from public.organization_members
where org_id = '00000000-0000-4000-8000-00000000be01' and user_id = '00000000-0000-4000-8000-0000000a0001';
select is(
  tests.hook_claims('00000000-0000-4000-8000-0000000a0001') ->> 'tenant_id', null,
  'Vínculo removido: as claims de tenant somem'
);

-- Organização que não está ativa na plataforma não emite claims nem aceita troca.
update doctor.tenants set status = 'suspended' where id = (select id from public.organizations where slug = 'nova-org');
select is(
  tests.hook_claims('00000000-0000-4000-8000-0000000b0001') ->> 'tenant_id', null,
  'Organização suspensa: as claims de tenant somem'
);
select tests.authenticate_without_tenant('00000000-0000-4000-8000-0000000b0001');
select results_eq(
  $$select slug from doctor.list_organizations()$$,
  $$values ('varejo-brasil'::text)$$,
  'Organização suspensa sai do seletor'
);
select throws_ok(
  $$select doctor.switch_organization((select id from public.organizations where slug = 'nova-org'))$$,
  '42501', null, 'troca para Organização suspensa é recusada'
);

-- A plataforma administra o Doctor com service_role.
select is(has_table_privilege('service_role', 'doctor.tenants', 'update'), true, 'service_role altera tenants');
select is(has_table_privilege('service_role', 'doctor.memberships', 'delete'), true, 'service_role altera Papéis');
select is(has_table_privilege('authenticated', 'doctor.schema_migrations', 'select'), false, 'histórico não é do cliente');

-- Apagar a Organização no jayv-coder não pode levar dados do Doctor junto.
select tests.clear_authentication();
select throws_ok(
  $$delete from public.organizations where id = '00000000-0000-4000-8000-00000000ac01'$$,
  '23503', null, 'Organização habilitada no Doctor não é apagada por public'
);

-- O perfil é o de public.profiles, com o RLS do jayv-coder.
select tests.authenticate_without_tenant('00000000-0000-4000-8000-0000000b0001');
select is_empty(
  $$select 1 from public.profiles where user_id <> auth.uid()$$, 'perfil de outra pessoa fica oculto'
);
select throws_ok(
  $$select doctor.create_organization('Outra', 'nova-org', 'Varejo', 'anthropic')$$,
  '23505', null, 'identificador repetido vira unique_violation'
);
select tests.clear_authentication();

-- Quem só existe no jayv-coder não ganha nada no Doctor.
select tests.authenticate_without_tenant('00000000-0000-4000-8000-0000000b0001');
select is(
  (select count(*)::int from doctor.list_organizations() where id = '00000000-0000-4000-8000-00000000cc01'), 0,
  'Vínculo só em public não dá acesso ao Doctor'
);
select throws_ok(
  $$select doctor.switch_organization('00000000-0000-4000-8000-00000000cc01')$$,
  '42501', null, 'sem Papel no Doctor a troca é recusada'
);
select tests.clear_authentication();

-- Toda emissão de token do jayv-coder passa pelo hook: ele nunca pode derrubar o login.
select is(
  doctor.custom_access_token_hook('{"user_id": "nao-e-uuid", "claims": {"role": "authenticated"}}') -> 'claims' ->> 'role',
  'authenticated', 'erro no hook devolve o token sem claims de tenant'
);
select is(
  has_table_privilege('authenticated', 'public.organizations', 'insert'), false,
  'o Doctor não concede escrita em public.organizations'
);

select * from finish();
rollback;
