-- Organizações: cada RPC com cada papel, o último owner, convites, a
-- privacidade dos perfis e a associação de projetos pelos remotes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'manu@teste.local', now(), '{"user_name":"manu"}'),
  ('00000000-0000-0000-0000-0000000000a3', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000a4', 'fora@teste.local', now(), '{"user_name":"fora"}'),
  ('00000000-0000-0000-0000-0000000000a5', 'novo@teste.local', null, '{"user_name":"novo"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- Criar: quem cria vira owner.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
select is((select role from public.organization_members where user_id = auth.uid()), 'owner', 'quem cria é owner');
select throws_ok($$select public.create_organization('Outra', 'acme')$$, 'P0001', 'org.slugTaken', 'slug repetido');
select throws_ok($$insert into public.organizations (name, slug) values ('x', 'xyz')$$, '42501', null, 'ninguém escreve direto');

-- Convites por @usuário.
insert into ids select 'inv_manu', public.invite_member((select id from ids where name = 'org'), '@manu', 'maintainer');
insert into ids select 'inv_membro', public.invite_member((select id from ids where name = 'org'), 'membro', 'member');
select throws_ok($$select public.invite_member((select id from ids where name = 'org'), 'manu', 'member')$$, 'P0001', 'org.alreadyInvited', 'convite pendente repetido');
select throws_ok($$select public.invite_member((select id from ids where name = 'org'), 'ninguem', 'member')$$, 'P0001', 'org.userNotFound', 'usuário inexistente');
select throws_ok($$select public.invite_member((select id from ids where name = 'org'), 'manu', 'owner')$$, 'P0001', 'org.forbidden', 'owner não se convida, se promove');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
select is_empty($$select 1 from public.organizations$$, 'quem não é membro não vê a organização');
select throws_ok($$select public.accept_invite((select id from ids where name = 'inv_manu'))$$, 'P0001', 'org.forbidden', 'o convite é só de quem foi convidado');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.my_invites()), 1, 'o convidado vê o próprio convite');
select is(public.accept_invite((select id from ids where name = 'inv_manu')), (select id from ids where name = 'org'), 'aceitar devolve a organização');
select is((select role from public.organization_members where user_id = auth.uid()), 'maintainer', 'entra com o papel do convite');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$select public.accept_invite((select id from ids where name = 'inv_membro'))$$, 'o member aceita');
select throws_ok($$select public.invite_member((select id from ids where name = 'org'), 'fora', 'member')$$, 'P0001', 'org.forbidden', 'member não convida');
select throws_ok($$select public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api')$$, 'P0001', 'org.forbidden', 'member não cadastra repositório');
select is((select count(*)::int from public.organization_members_view((select id from ids where name = 'org'))), 3, 'o member vê a lista de membros');
select is_empty($$select 1 from public.profiles where user_id <> auth.uid()$$, 'o member não lê o perfil completo de outro');

-- Convite por e-mail: só com o e-mail confirmado.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
insert into ids select 'inv_novo', public.invite_member((select id from ids where name = 'org'), 'NOVO@teste.local', 'member');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
select throws_ok($$select public.accept_invite((select id from ids where name = 'inv_novo'))$$, 'P0001', 'org.emailUnconfirmed', 'e-mail sem confirmação não aceita');
reset role;
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000a5';
update public.organization_invites set expires_at = now() - interval '1 day' where id = (select id from ids where name = 'inv_novo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
select throws_ok($$select public.accept_invite((select id from ids where name = 'inv_novo'))$$, 'P0001', 'org.inviteExpired', 'convite vencido');
select is((select count(*)::int from public.my_invites()), 0, 'o vencido some da caixa');

-- Repositórios.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$select public.add_repository((select id from ids where name = 'org'), 'github', 'Acme/API.git')$$, 'maintainer cadastra repositório');
select is((select repo_key from public.organization_repositories), 'github.com/acme/api', 'a chave é normalizada');
select throws_ok($$select public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api')$$, 'P0001', 'org.repoTaken', 'repositório repetido');
select throws_ok($$select public.add_repository((select id from ids where name = 'org'), 'github', 'só-um')$$, 'P0001', 'org.repoInvalid', 'caminho sem dono');

-- Papéis e o último owner.
select throws_ok($$select public.set_member_role((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000a3', 'maintainer')$$, 'P0001', 'org.forbidden', 'maintainer não troca papel');
select throws_ok($$select public.remove_member((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000a1')$$, 'P0001', 'org.forbidden', 'maintainer não remove owner');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$select public.leave_organization((select id from ids where name = 'org'))$$, 'P0001', 'org.lastOwner', 'o último owner não sai');
select throws_ok($$select public.set_member_role((select id from ids where name = 'org'), auth.uid(), 'member')$$, 'P0001', 'org.lastOwner', 'o último owner não se rebaixa');
select lives_ok($$select public.set_member_role((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000a2', 'owner')$$, 'owner promove');
select lives_ok($$select public.leave_organization((select id from ids where name = 'org'))$$, 'com outro owner, sai');

-- Associação de projetos: o fork conta pela organização do upstream.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
insert into public.projects (id, name, created_at, repo_keys) values
  ('p-fork', 'Fork', '2026-10-02T12:00:00Z', '["github.com/membro/api","github.com/acme/api"]');
select is(public.project_organization('p-fork'), (select id from ids where name = 'org'), 'o fork pertence à organização do upstream');
select is((select org_slug from public.my_project_organizations()), 'acme', 'o dono vê a associação');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
insert into public.projects (id, name, created_at, repo_keys) values ('p-fora', 'Fora', '2026-10-02T12:00:00Z', '["github.com/acme/api"]');
select is(public.project_organization('p-fora'), null, 'quem não é membro não associa');

-- A busca para convidar.
select is((select array_agg(username order by username) from public.find_users('@ma')), array['manu'], 'busca por prefixo');

select * from finish();
rollback;
