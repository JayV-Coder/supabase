begin;
\ir ../helpers/tenancy.psql
select plan(41);

select tests.create_user('00000000-0000-4000-8000-0000000f4001', 'owner@acme.com.br');
select tests.create_user('00000000-0000-4000-8000-0000000f4002', 'admin@acme.com.br');
select tests.create_user('00000000-0000-4000-8000-0000000f4003', 'ana@acme.com.br');
select tests.create_user('00000000-0000-4000-8000-0000000f4006', 'dono@outra.com.br');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac41', 'acme-sso');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac42', 'outra-sso');
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4002', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac42', '00000000-0000-4000-8000-0000000f4006', 'owner');

-- O que o IdP mandou fica na identidade do provedor (`auth.identities`), que o Usuário não edita.
create function pg_temp.idp_groups(person uuid, groups jsonb) returns void language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider)
  values (person::text, person, jsonb_build_object('custom_claims', jsonb_build_object('groups', groups)),
    'sso:00000000-0000-4000-8000-00000000c501')
  on conflict (provider_id, provider) do update set identity_data = excluded.identity_data
$$;
create function pg_temp.sso_login(person uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
    set_config('request.jwt.claims', json_build_object('sub', person, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'sso/saml',
        'provider', '00000000-0000-4000-8000-00000000c501')))::text, true)
$$;
create function pg_temp.hook_tenant(person uuid, method text) returns text language sql as $$
  select doctor.custom_access_token_hook(json_build_object('user_id', person,
    'claims', json_build_object('amr', json_build_array(json_build_object('method', method))))::jsonb)
    -> 'claims' ->> 'tenant_id'
$$;

select tests.authenticate_as('00000000-0000-4000-8000-0000000f4002', '00000000-0000-4000-8000-00000000ac41', 'admin', 'aal2');
select throws_ok($$select doctor.configure_sso('https://idp.acme.com.br/metadata', false, null)$$, '42501', null,
  'SSO é do Owner');
select tests.clear_authentication();

-- Outra Organização cadastra o domínio da Acme sem provar nada: não pode travar a dona de verdade.
select tests.authenticate_as('00000000-0000-4000-8000-0000000f4006', '00000000-0000-4000-8000-00000000ac42', 'owner', 'aal2');
select ok(doctor.add_sso_domain('acme.com.br') is not null, 'cadastrar um domínio sem verificar não o reserva');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f4001', '00000000-0000-4000-8000-00000000ac41', 'owner', 'aal2');
select ok(doctor.add_sso_domain('ACME.com.br') is not null, 'Owner cadastra o domínio (normalizado)');
select throws_ok($$select doctor.add_sso_domain('acme.com.br')$$, 'DR100', null, 'sem repetir na mesma Organização');
select throws_ok($$select doctor.configure_sso('https://idp.acme.com.br/metadata', true, null)$$, 'DR101', null,
  'exigir SSO pede domínio verificado');
select ok(doctor.configure_sso('https://idp.acme.com.br/metadata', false, 'viewer') is not null, 'Owner configura o SAML');
select lives_ok($$select doctor.verify_sso_domain((select id from doctor.sso_domains))$$, 'pede a verificação do DNS');
select lives_ok($$select doctor.set_sso_groups('{"AID-Admins": "admin", "AID-Suporte": "analyst"}')$$,
  'mapeia grupos para Papéis');
select throws_ok($$select doctor.set_sso_groups('{"Donos": "owner"}')$$, '23514', null, 'grupo não vira Owner');
select throws_ok($$select scim_token_hash from doctor.sso_connections$$, '42501', null, 'o hash do SCIM não é legível');
select lives_ok($$select doctor.set_scim_token(repeat('5', 64))$$, 'gera o token do SCIM');
select tests.clear_authentication();

select is((select count(*)::int from doctor.outbox_messages where topic in ('sso.sync', 'sso.domain')
  and tenant_id = '00000000-0000-4000-8000-00000000ac41'), 2, 'sincronização e verificação vão para o worker');

-- "Exigir SSO" só vale com a conexão ativa: pendente ou com erro, ninguém entraria por lugar nenhum.
select tests.create_user('00000000-0000-4000-8000-0000000f4007', 'bia@acme.com.br');
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4007', 'viewer');
insert into doctor.user_active_tenant (user_id, tenant_id)
values ('00000000-0000-4000-8000-0000000f4007', '00000000-0000-4000-8000-00000000ac41');
update doctor.sso_domains set verified_at = now() where tenant_id = '00000000-0000-4000-8000-00000000ac41';
update doctor.sso_connections set require_sso = true;
select is(pg_temp.hook_tenant('00000000-0000-4000-8000-0000000f4007', 'password'), '00000000-0000-4000-8000-00000000ac41',
  'com o provedor ainda pendente, a senha continua abrindo o Doctor');
update doctor.sso_connections set require_sso = false;
update doctor.sso_domains set verified_at = null;

-- A plataforma confirma o DNS e registra o provedor no Supabase Auth.
set local role service_role;
select is(doctor.mark_sso_domain((select id from doctor.sso_domains where tenant_id = '00000000-0000-4000-8000-00000000ac41')),
  true, 'a plataforma marca o domínio como verificado');
select is(doctor.mark_sso_domain((select id from doctor.sso_domains where tenant_id = '00000000-0000-4000-8000-00000000ac42')),
  false, 'quem verifica primeiro fica com o domínio');
select doctor.set_sso_provider((select id from doctor.sso_connections), '00000000-0000-4000-8000-00000000c501', 'active', null);
reset role;
select tests.authenticate_as('00000000-0000-4000-8000-0000000f4006', '00000000-0000-4000-8000-00000000ac42', 'owner', 'aal2');
select throws_ok($$select doctor.add_sso_domain('sub.acme.com.br'), doctor.add_sso_domain('acme.com.br')$$, 'DR100', null,
  'domínio verificado é de uma Organização só');
select tests.clear_authentication();

select tests.authenticate_as_anon();
select is((select required from doctor.sso_discover('Ana@ACME.com.br')), false, 'o login acha o SSO pelo domínio');
select is((select count(*)::int from doctor.sso_discover('ana@outra.com')), 0, 'outro domínio segue sem SSO');
select tests.clear_authentication();

-- JIT: a Ana entra pelo SSO com o grupo AID-Suporte e vira Analyst. O que ela mesma escreve no
-- perfil (`raw_user_meta_data`) não conta.
update auth.users set raw_user_meta_data = '{"custom_claims": {"groups": ["AID-Admins"]}}'
where id = '00000000-0000-4000-8000-0000000f4003';
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4003', '["AID-Suporte", "Todos"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'analyst', 'JIT cria o Vínculo pelo grupo que o IdP mandou');
reset role;

-- Sem grupo mapeado, vale o Papel padrão (aqui, Viewer), nunca o grupo do perfil.
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4003', '["Todos"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'viewer', 'grupo escrito pelo próprio Usuário não dá Papel');
reset role;

-- Organização no limite de vagas: quem já tem Vínculo entra e tem o Papel atualizado; gente
-- nova fica de fora, com o erro do plano.
update doctor.plan_limits set "limit" = (select count(*) from doctor.memberships
  where tenant_id = '00000000-0000-4000-8000-00000000ac41') where plan = 'pilot' and resource = 'members';
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4003', '["AID-Suporte"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'analyst', 'no limite de vagas, quem já é Membro entra e muda de Papel');
reset role;
select tests.create_user('00000000-0000-4000-8000-0000000f4008', 'novo@acme.com.br');
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4008', '["AID-Suporte"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4008');
select throws_ok($$select * from doctor.sso_provision()$$, 'DR051', null, 'e gente nova esbarra no limite do plano');
reset role;
update doctor.plan_limits set "limit" = 20 where plan = 'pilot' and resource = 'members';

-- Saiu de todos os grupos mapeados e não há Papel padrão: o Vínculo some no login seguinte (e
-- continua sumido: nada de exceção que desfaça a remoção).
update doctor.sso_connections set default_role = null;
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4003', '["Todos"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select count(*)::int from doctor.sso_provision()), 0, 'sem grupo mapeado, o JIT não devolve Vínculo');
reset role;
select is((select count(*)::int from doctor.memberships where user_id = '00000000-0000-4000-8000-0000000f4003'), 0,
  'e o Vínculo anterior some');
select pg_temp.idp_groups('00000000-0000-4000-8000-0000000f4003', '["AID-Suporte"]');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'analyst', 'de volta ao grupo, o Vínculo volta');
reset role;

-- Sem nenhum grupo mapeado, o IdP não manda nos Papéis: o que foi dado na tela fica.
delete from doctor.sso_group_roles;
update doctor.memberships set role = 'admin' where user_id = '00000000-0000-4000-8000-0000000f4003';
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'admin', 'mapeamento vazio não rebaixa nem remove ninguém');
reset role;
insert into doctor.sso_group_roles (tenant_id, group_name, role) values
  ('00000000-0000-4000-8000-00000000ac41', 'AID-Suporte', 'analyst');
select pg_temp.sso_login('00000000-0000-4000-8000-0000000f4003');
select is((select role from doctor.sso_provision()), 'analyst', 'com mapeamento, o grupo do IdP volta a valer');
reset role;

-- Exigir SSO: sem `amr` de SSO, o hook não dá as claims do Doctor (o login do resto segue).
update doctor.sso_connections set require_sso = true;
select is(pg_temp.hook_tenant('00000000-0000-4000-8000-0000000f4003', 'otp'), null,
  'link mágico num domínio que exige SSO não abre o Doctor');
select is(pg_temp.hook_tenant('00000000-0000-4000-8000-0000000f4003', 'sso/saml'), '00000000-0000-4000-8000-00000000ac41',
  'pelo SSO, as claims vêm');

-- O Owner entra por senha mesmo com "Exigir SSO": se o IdP cair, é ele quem desliga a regra.
insert into doctor.user_active_tenant (user_id, tenant_id)
values ('00000000-0000-4000-8000-0000000f4001', '00000000-0000-4000-8000-00000000ac41')
on conflict (user_id) do update set tenant_id = excluded.tenant_id;
select is(pg_temp.hook_tenant('00000000-0000-4000-8000-0000000f4001', 'password'), '00000000-0000-4000-8000-00000000ac41',
  'o Owner não fica trancado para fora');

-- SCIM: desativar no IdP tira o Vínculo. As sessões só caem para quem é de um domínio
-- verificado da Organização e tinha Vínculo nela: o token SCIM não desloga quem é de fora.
select tests.create_user('00000000-0000-4000-8000-0000000f4004', 'fora@gmail.com');
insert into auth.users (id, instance_id, aud, role, email, is_sso_user)
values ('00000000-0000-4000-8000-0000000f4005', '00000000-0000-0000-0000-000000000000', 'authenticated',
  'authenticated', 'ana@acme.com.br', true);
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4005', 'viewer');
insert into auth.sessions (id, user_id) values
  (gen_random_uuid(), '00000000-0000-4000-8000-0000000f4003'),
  (gen_random_uuid(), '00000000-0000-4000-8000-0000000f4004'),
  (gen_random_uuid(), '00000000-0000-4000-8000-0000000f4005');
select tests.authenticate_as_anon();
select ok(doctor.scim_upsert_user(repeat('5', 64), 'fora@gmail.com', null, false) is not null,
  'o IdP pode citar um e-mail de fora');
select tests.clear_authentication();
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-8000-0000000f4004'), 1,
  'mas a sessão de quem não é da Organização fica');

select tests.authenticate_as_anon();
select ok(doctor.scim_upsert_user(repeat('5', 64), 'ANA@acme.com.br', 'okta-1', false) is not null,
  'o IdP desativa pelo SCIM');
select ok(doctor.scim_upsert_user(repeat('5', 64), 'caio@acme.com.br', 'okta-2', true) is not null,
  'e provisiona mais gente');
-- Listagem em páginas, com o total certo em qualquer página.
select is((select count(*)::int from doctor.scim_users(repeat('5', 64), null, null, 0, 2)), 2, 'a página respeita o tamanho');
select is((select count(distinct user_name)::int from (
    select user_name from doctor.scim_users(repeat('5', 64), null, null, 0, 2)
    union all select user_name from doctor.scim_users(repeat('5', 64), null, null, 2, 2)) pages), 3,
  'a página seguinte continua de onde a anterior parou, sem repetir ninguém');
select is(doctor.scim_user_count(repeat('5', 64), null), 3::bigint, 'o total não depende da página');
select throws_ok($$select doctor.scim_user_count(repeat('9', 64), null)$$, 'DR106', null, 'token SCIM errado não conta nada');
select tests.clear_authentication();
select is((select count(*)::int from doctor.memberships where user_id in
  ('00000000-0000-4000-8000-0000000f4003', '00000000-0000-4000-8000-0000000f4005')), 0,
  'o Vínculo some, nas duas contas com o e-mail (a de senha e a do SSO)');
select is((select count(*)::int from auth.sessions where user_id in
  ('00000000-0000-4000-8000-0000000f4003', '00000000-0000-4000-8000-0000000f4005')), 0,
  'e as sessões de quem é do domínio verificado caem');
select is((select count(*)::int from public.organization_members
  where org_id = '00000000-0000-4000-8000-00000000ac41' and user_id = '00000000-0000-4000-8000-0000000f4003'), 1,
  'a Organização em public não é tocada');

select * from finish();
rollback;
