begin;
\ir ../helpers/tenancy.psql
select plan(18);

select tests.create_user('00000000-0000-4000-8000-0000000f4001', 'owner@acme.com.br');
select tests.create_user('00000000-0000-4000-8000-0000000f4002', 'admin@acme.com.br');
select tests.create_user('00000000-0000-4000-8000-0000000f4003', 'ana@acme.com.br');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac41', 'acme-sso');
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac41', '00000000-0000-4000-8000-0000000f4002', 'admin');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f4002', '00000000-0000-4000-8000-00000000ac41', 'admin', 'aal2');
select throws_ok($$select doctor.configure_sso('https://idp.acme.com.br/metadata', false, null)$$, '42501', null,
  'SSO é do Owner');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f4001', '00000000-0000-4000-8000-00000000ac41', 'owner', 'aal2');
select ok(doctor.add_sso_domain('ACME.com.br') is not null, 'Owner cadastra o domínio (normalizado)');
select throws_ok($$select doctor.add_sso_domain('acme.com.br')$$, 'DR100', null, 'domínio é de uma Organização só');
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

-- A plataforma confirma o DNS e registra o provedor no Supabase Auth.
set local role service_role;
select doctor.mark_sso_domain((select id from doctor.sso_domains), true);
select doctor.set_sso_provider((select id from doctor.sso_connections), '00000000-0000-4000-8000-00000000c501', 'active', null);
reset role;

select tests.authenticate_as_anon();
select is((select required from doctor.sso_discover('Ana@ACME.com.br')), false, 'o login acha o SSO pelo domínio');
select is((select count(*)::int from doctor.sso_discover('ana@outra.com')), 0, 'outro domínio segue sem SSO');
select tests.clear_authentication();

-- JIT: a Ana entra pelo SSO com o grupo AID-Suporte e vira Analyst.
update auth.users set raw_user_meta_data = '{"custom_claims": {"groups": ["AID-Suporte", "Todos"]}}'
where id = '00000000-0000-4000-8000-0000000f4003';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000f4003',
  'role', 'authenticated', 'amr', json_build_array(json_build_object('method', 'sso/saml',
  'provider', '00000000-0000-4000-8000-00000000c501')))::text, true);
select is((select role from doctor.sso_provision()), 'analyst', 'JIT cria o Vínculo pelo grupo');
reset role;

-- Exigir SSO: sem `amr` de SSO, o hook não dá as claims do Doctor (o login do resto segue).
update doctor.sso_connections set require_sso = true;
select is(doctor.custom_access_token_hook(json_build_object('user_id', '00000000-0000-4000-8000-0000000f4003',
  'claims', json_build_object('amr', json_build_array(json_build_object('method', 'otp'))))::jsonb) -> 'claims' ->> 'tenant_id',
  null, 'link mágico num domínio que exige SSO não abre o Doctor');
select is(doctor.custom_access_token_hook(json_build_object('user_id', '00000000-0000-4000-8000-0000000f4003',
  'claims', json_build_object('amr', json_build_array(json_build_object('method', 'sso/saml'))))::jsonb) -> 'claims' ->> 'tenant_id',
  '00000000-0000-4000-8000-00000000ac41', 'pelo SSO, as claims vêm');

-- SCIM: desativar no IdP tira o Vínculo.
select tests.authenticate_as_anon();
select ok(doctor.scim_upsert_user(repeat('5', 64), 'ANA@acme.com.br', 'okta-1', false) is not null,
  'o IdP desativa pelo SCIM');
select tests.clear_authentication();
select is((select count(*)::int from doctor.memberships where user_id = '00000000-0000-4000-8000-0000000f4003'), 0,
  'o Vínculo some');

select * from finish();
rollback;
