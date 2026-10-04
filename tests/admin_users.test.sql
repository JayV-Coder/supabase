-- Site v1.1.0: a página Usuários. Só o admin lista e age; ele não age sobre a
-- própria conta, não bloqueia nem exclui outro admin, e cada ação fica no
-- registro.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email, encrypted_password) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@teste.local', 'x'),
  ('00000000-0000-0000-0000-0000000000b2', 'pessoa@teste.local', ''),
  ('00000000-0000-0000-0000-0000000000c3', 'dona@teste.local', '');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select throws_ok($$ select * from public.admin_users() $$, 'P0001', 'admin.forbidden', 'quem não é admin não lista');
select throws_ok($$ select public.admin_set_banned('00000000-0000-0000-0000-0000000000c3', true) $$, 'P0001', 'admin.forbidden', 'nem age');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select is((select count(*) from public.admin_users()), 3::bigint, 'o admin vê todas as contas');
select is((select total from public.admin_users('pessoa') limit 1), 1::bigint, 'a busca filtra por e-mail');
select is((select count(*) from public.admin_users('%')), 0::bigint, 'o curinga da busca é texto, não padrão');
select is((public.admin_user('00000000-0000-0000-0000-0000000000b2')->>'email'), 'pessoa@teste.local', 'e abre uma conta');
select throws_ok($$ select public.admin_user('00000000-0000-0000-0000-00000000ffff') $$, 'P0001', 'site.users.error.notFound', 'conta que não existe');

select throws_ok($$ select public.admin_set_admin('00000000-0000-0000-0000-0000000000a1', false) $$, 'P0001', 'site.users.error.self', 'o admin não tira o próprio papel');
select throws_ok($$ select public.admin_delete_user('00000000-0000-0000-0000-0000000000a1') $$, 'P0001', 'site.users.error.self', 'nem se exclui');

select lives_ok($$ select public.admin_set_banned('00000000-0000-0000-0000-0000000000b2', true) $$, 'bloqueia uma conta');
reset role;
select ok((select banned_until > now() from auth.users where id = '00000000-0000-0000-0000-0000000000b2'), 'o Supabase Auth passa a recusar a conta');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.admin_set_banned('00000000-0000-0000-0000-0000000000b2', false) $$, 'e desbloqueia');
reset role;
select ok((select banned_until is null from auth.users where id = '00000000-0000-0000-0000-0000000000b2'), 'a conta volta a entrar');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select lives_ok($$ select public.admin_set_admin('00000000-0000-0000-0000-0000000000b2', true) $$, 'dá o papel de admin');
select throws_ok($$ select public.admin_set_banned('00000000-0000-0000-0000-0000000000b2', true) $$, 'P0001', 'site.users.error.isAdmin', 'admin não é bloqueado sem antes perder o papel');
select lives_ok($$ select public.admin_set_admin('00000000-0000-0000-0000-0000000000b2', false) $$, 'e tira');

select is(public.admin_password_reset('00000000-0000-0000-0000-0000000000b2'), 'pessoa@teste.local', 'o link de senha vai ao e-mail da conta');

-- A dona é a única owner de uma organização com mais gente: não sai sem promover alguém.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c3');
select public.create_organization('Acme', 'acme-users-test');
reset role;
insert into public.organization_members (org_id, user_id, role)
  select id, '00000000-0000-0000-0000-0000000000b2', 'member' from public.organizations where slug = 'acme-users-test';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.admin_delete_user('00000000-0000-0000-0000-0000000000c3') $$, 'P0001', 'site.users.error.soleOwner', 'a única owner com membros não é excluída');
select lives_ok($$ select public.admin_delete_user('00000000-0000-0000-0000-0000000000b2') $$, 'outra conta é excluída');

reset role;
select is((select array_agg(action order by id) from public.admin_audit where target_id = '00000000-0000-0000-0000-0000000000b2'),
  array['ban', 'unban', 'grantAdmin', 'revokeAdmin', 'passwordReset', 'deleteUser'], 'cada ação ficou no registro, mesmo com a conta excluída');

select * from finish();
rollback;
