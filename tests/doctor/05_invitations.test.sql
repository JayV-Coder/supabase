begin;
\ir ../helpers/tenancy.psql
select plan(43);

select has_table('doctor', 'invitations', 'tabela doctor.invitations existe');
select is(
  (select relrowsecurity from pg_class where oid = 'doctor.invitations'::regclass), true, 'RLS ligado em invitations'
);

-- ana: Owner · bia: Admin · caio: Analyst · dani: Viewer da Acme; edu: Owner da Varejo
select tests.create_user('00000000-0000-4000-8000-00000000000a', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000000000b', 'bia@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000000000c', 'caio@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000000000d', 'dani@acme.test');
select tests.create_user('00000000-0000-4000-8000-00000000000e', 'edu@varejo.test');
select tests.create_user('00000000-0000-4000-8000-00000000000f', 'fabi@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000000a', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000000b', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000000c', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000000d', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-00000000000e', 'owner');

create function tests.as_acme(person text, role text, aal text default 'aal2')
returns void
language sql
as $$
  select tests.authenticate_as(('00000000-0000-4000-8000-00000000000' || person)::uuid, '00000000-0000-4000-8000-00000000ac01', role, aal)
$$;
grant execute on function tests.as_acme(text, text, text) to anon, authenticated;

create function tests.member_id(person text)
returns uuid
language sql
security definer
as $$
  select id from doctor.memberships
  where tenant_id = '00000000-0000-4000-8000-00000000ac01'
    and user_id = ('00000000-0000-4000-8000-00000000000' || person)::uuid
$$;
grant execute on function tests.member_id(text) to anon, authenticated;

create function tests.invitation_id(target text)
returns uuid
language sql
security definer
as $$
  select id from doctor.invitations where email = target
$$;
grant execute on function tests.invitation_id(text) to anon, authenticated;

-- Quem convida
select tests.as_acme('a', 'owner');
select lives_ok($$select * from doctor.invite_member('OWNER2@acme.test', 'owner', 'h-owner')$$, 'Owner convida Owner');
select results_eq(
  $$select email, role from doctor.list_invitations() where email = 'owner2@acme.test'$$,
  $$values ('owner2@acme.test'::text, 'owner'::text)$$, 'e-mail fica em minúsculas'
);
select tests.as_acme('b', 'admin');
select lives_ok($$select * from doctor.invite_member('fabi@acme.test', 'analyst', 'h-fabi')$$, 'Admin convida Analyst');
select throws_ok($$select * from doctor.invite_member('x@acme.test', 'owner', 'h-x')$$, '42501', null, 'Admin não convida Owner');
select throws_ok(
  $$select * from doctor.invite_member('fabi@acme.test', 'viewer', 'h-dup')$$, '23505', null, 'convite pendente repetido é recusado'
);
select throws_ok(
  $$select * from doctor.invite_member('caio@acme.test', 'viewer', 'h-caio')$$, 'DR004', null, 'quem já tem Papel não é convidado'
);
select tests.as_acme('b', 'admin', 'aal1');
select throws_ok($$select * from doctor.invite_member('y@acme.test', 'viewer', 'h-y')$$, '42501', null, 'gestão exige aal2');
select tests.as_acme('c', 'analyst');
select throws_ok($$select * from doctor.invite_member('y@acme.test', 'viewer', 'h-y')$$, '42501', null, 'Analyst não convida');
select tests.as_acme('d', 'viewer');
select throws_ok($$select * from doctor.invite_member('y@acme.test', 'viewer', 'h-y')$$, '42501', null, 'Viewer não convida');
select tests.as_acme('c', 'admin');
select throws_ok(
  $$select * from doctor.invite_member('y@acme.test', 'viewer', 'h-y')$$, '42501', null, 'claim antiga não vale: o Papel é lido do banco'
);

-- O que cada Papel lê
select tests.as_acme('b', 'admin');
select is((select count(*)::int from doctor.list_invitations()), 2, 'Admin lê os convites da Organização');
select throws_ok($$select token_hash from doctor.invitations$$, '42501', null, 'hash do token não é legível');
select throws_ok($$select id from doctor.invitations$$, '42501', null, 'convites só saem pela função');
select is((select count(*)::int from doctor.list_members()), 4, 'Admin lista os membros');
select tests.as_acme('c', 'analyst');
select throws_ok($$select * from doctor.list_invitations()$$, '42501', null, 'Analyst não lê convites');
select tests.as_acme('c', 'admin');
select throws_ok($$select * from doctor.list_invitations()$$, '42501', null, 'claim antiga não lê convites');
select tests.as_acme('c', 'analyst');
select throws_ok($$select * from doctor.list_members()$$, '42501', null, 'Analyst não lista membros');
select tests.authenticate_as('00000000-0000-4000-8000-00000000000e', '00000000-0000-4000-8000-00000000be01', 'owner', 'aal2');
select is((select count(*)::int from doctor.list_invitations()), 0, 'outra Organização não lê os convites da Acme');
select throws_ok(
  format($$select doctor.revoke_invitation('%s')$$, tests.invitation_id('fabi@acme.test')), 'P0002', null, 'não revoga convite de outra Organização'
);
select throws_ok(
  format($$select * from doctor.resend_invitation('%s', 'h-z')$$, tests.invitation_id('fabi@acme.test')), 'P0002', null, 'não reenvia convite de outra Organização'
);
select throws_ok(
  format($$select doctor.update_member_role('%s', 'owner')$$, tests.member_id('c')), 'P0002', null, 'não muda Papel em outra Organização'
);
select throws_ok(
  format($$select doctor.remove_member('%s')$$, tests.member_id('c')), 'P0002', null, 'não remove membro de outra Organização'
);
select tests.clear_authentication();
select throws_ok(
  format($$select doctor.update_member_role('%s', 'viewer')$$, tests.member_id('c')), '42501', null, 'sem sessão não gerencia'
);

-- Aceite
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000f');
select throws_ok($$select doctor.accept_invitation('h-owner')$$, 'DR003', null, 'outro e-mail não aceita');
select throws_ok($$select doctor.accept_invitation('nao-existe')$$, 'P0002', null, 'token desconhecido');
select tests.clear_authentication();
update auth.users set email_confirmed_at = null where id = '00000000-0000-4000-8000-00000000000f';
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000f');
select throws_ok($$select doctor.accept_invitation('h-fabi')$$, 'DR003', null, 'e-mail não confirmado não aceita');
select tests.clear_authentication();
update auth.users set email_confirmed_at = now() where id = '00000000-0000-4000-8000-00000000000f';
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000f');
select lives_ok($$select doctor.accept_invitation('h-fabi')$$, 'convidada aceita');
select throws_ok($$select doctor.accept_invitation('h-fabi')$$, 'DR002', null, 'convite usado não vale de novo');
select tests.clear_authentication();
select results_eq(
  $$select m.role, a.tenant_id::text, o.role
    from doctor.memberships m
    join doctor.user_active_tenant a on a.user_id = m.user_id
    join public.organization_members o on o.org_id = m.tenant_id and o.user_id = m.user_id
    where m.user_id = '00000000-0000-4000-8000-00000000000f'$$,
  $$values ('analyst'::text, '00000000-0000-4000-8000-00000000ac01'::text, 'member'::text)$$,
  'aceitar cria Vínculo, Papel e Organização ativa'
);
update doctor.invitations set accepted_at = null, expires_at = now() - interval '1 day' where email = 'fabi@acme.test';
delete from doctor.memberships where user_id = '00000000-0000-4000-8000-00000000000f';
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000f');
select throws_ok($$select doctor.accept_invitation('h-fabi')$$, 'DR002', null, 'convite expirado não vale');

-- Quem já tem Papel não muda por convite, mesmo trocando de e-mail depois de convidado.
select tests.clear_authentication();
insert into doctor.invitations (tenant_id, email, role, token_hash)
values ('00000000-0000-4000-8000-00000000ac01', 'ana@acme.test', 'viewer', 'h-ana');
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000a');
select throws_ok($$select doctor.accept_invitation('h-ana')$$, 'DR004', null, 'aceite não rebaixa quem já tem Papel');
select tests.clear_authentication();
select is(
  (select role from doctor.memberships where user_id = '00000000-0000-4000-8000-00000000000a'), 'owner',
  'o Papel continua o mesmo'
);

-- Organização suspensa não recebe ninguém.
delete from doctor.invitations where email = 'ana@acme.test';
update doctor.invitations set accepted_at = null, expires_at = now() + interval '1 day' where email = 'fabi@acme.test';
update doctor.tenants set status = 'suspended' where id = '00000000-0000-4000-8000-00000000ac01';
select tests.authenticate_without_tenant('00000000-0000-4000-8000-00000000000f');
select throws_ok($$select doctor.accept_invitation('h-fabi')$$, 'DR002', null, 'convite de Organização suspensa não vale');
select tests.clear_authentication();
update doctor.tenants set status = 'active' where id = '00000000-0000-4000-8000-00000000ac01';

-- Papel e remoção
select tests.as_acme('a', 'owner');
select throws_ok(
  format($$select doctor.update_member_role('%s', 'admin')$$, tests.member_id('a')), 'DR001', null, 'único Owner não se rebaixa'
);
select throws_ok(format($$select doctor.remove_member('%s')$$, tests.member_id('a')), 'DR001', null, 'único Owner não sai');
select tests.as_acme('b', 'admin');
select throws_ok(
  format($$select doctor.update_member_role('%s', 'owner')$$, tests.member_id('c')), '42501', null, 'Admin não promove a Owner'
);
select throws_ok(
  format($$select doctor.update_member_role('%s', 'viewer')$$, tests.member_id('a')), '42501', null, 'Admin não mexe em Owner'
);
select throws_ok(format($$select doctor.remove_member('%s')$$, tests.member_id('a')), '42501', null, 'Admin não remove Owner');
select lives_ok(format($$select doctor.update_member_role('%s', 'viewer')$$, tests.member_id('c')), 'Admin rebaixa Analyst');
select lives_ok(format($$select doctor.remove_member('%s')$$, tests.member_id('c')), 'Admin remove membro');
select tests.clear_authentication();
select is(
  (select count(*)::int from public.organization_members
   where org_id = '00000000-0000-4000-8000-00000000ac01' and user_id = '00000000-0000-4000-8000-00000000000c'), 1,
  'remover do Doctor mantém o Vínculo no jayv-coder'
);

select * from finish();
rollback;
