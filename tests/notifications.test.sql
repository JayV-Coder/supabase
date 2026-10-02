-- Notificações: cada gatilho avisa quem não fez a ação, cada um lê só as
-- suas, e só as RPCs marcam como lidas ou limpam.
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000b1', 'dona@teste.local', now(), '{"user_name":"dona"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'manu@teste.local', now(), '{"user_name":"manu"}'),
  ('00000000-0000-0000-0000-0000000000b3', 'membro@teste.local', now(), '{"user_name":"membro"}'),
  ('00000000-0000-0000-0000-0000000000b4', 'mail@teste.local', now(), '{"user_name":"mail"}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- Convites: a conta convidada é avisada, por @usuário ou pelo e-mail
-- confirmado; quem convida, não.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into ids select 'inv_manu', public.invite_member((select id from ids where name = 'org'), '@manu', 'maintainer');
insert into ids select 'inv_membro', public.invite_member((select id from ids where name = 'org'), 'membro', 'member');
insert into ids select 'inv_mail', public.invite_member((select id from ids where name = 'org'), 'MAIL@teste.local', 'member');
select is_empty($$select 1 from public.notifications$$, 'quem convida não se avisa');
select throws_ok($$insert into public.notifications (user_id, kind) values (auth.uid(), 'org.removed')$$, '42501', null, 'ninguém escreve direto');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is((select kind from public.notifications), 'org.invited', 'o convidado por @usuário é avisado');
select is((select data from public.notifications),
  jsonb_build_object('orgId', (select id from ids where name = 'org'), 'org', 'Acme', 'inviteId', (select id from ids where name = 'inv_manu'), 'role', 'maintainer', 'user', 'dona'),
  'o aviso traz organização, convite, papel e quem convidou');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b4');
select is((select count(*)::int from public.notifications where kind = 'org.invited'), 1, 'o convidado por e-mail confirmado é avisado');

-- Aceitar avisa quem convidou e marca o convite como lido para o convidado.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select public.accept_invite((select id from ids where name = 'inv_manu'));
select isnt((select read_at from public.notifications where kind = 'org.invited'), null, 'o convite respondido vira lido');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select public.decline_invite((select id from ids where name = 'inv_membro'));

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select is((select data->>'user' from public.notifications where kind = 'org.inviteAccepted'), 'manu', 'quem convidou sabe quem aceitou');
select is((select data->>'user' from public.notifications where kind = 'org.inviteDeclined'), 'membro', 'e quem recusou');
select is((select count(*)::int from public.notifications), 2, 'a dona lê só as dela');

-- Revogar não avisa ninguém, mas o convite pendente deixa de pedir resposta.
select public.revoke_invite((select id from ids where name = 'inv_mail'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b4');
select isnt((select read_at from public.notifications where kind = 'org.invited'), null, 'o convite revogado vira lido');

-- Papel e política: avisam os outros membros, não quem mudou.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.set_member_role((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000b2', 'member');
select public.set_llm_policy((select id from ids where name = 'org'), null, '{"safe_agents": true}');
select public.set_llm_policy((select id from ids where name = 'org'), null, '{"safe_agents": false}');
insert into ids select 'repo', public.add_repository((select id from ids where name = 'org'), 'github', 'acme/api');
select public.set_llm_policy((select id from ids where name = 'org'), (select id from ids where name = 'repo'), '{"redact_secrets": true}');
select is((select count(*)::int from public.notifications where kind in ('org.roleChanged', 'org.policyChanged')), 0, 'quem muda não se avisa');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is((select data->>'role' from public.notifications where kind = 'org.roleChanged'), 'member', 'o membro sabe o papel novo');
select is((select count(*)::int from public.notifications where kind = 'org.policyChanged'), 2, 'cada política gravada avisa');
select is((select count(*)::int from public.notifications where kind = 'org.policyChanged' and data->>'repository' is null), 1, 'regravar (apagar e inserir) avisa uma vez');
select is((select data->>'repository' from public.notifications where kind = 'org.policyChanged' and data ? 'repository'), 'github.com/acme/api', 'a do repositório diz qual');

-- Tirar o repositório leva a política junto, sem aviso.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.remove_repository((select id from ids where name = 'repo'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is((select count(*)::int from public.notifications where kind = 'org.policyChanged'), 2, 'a política apagada em cascata não avisa');

-- Marcar e limpar: só as próprias.
select lives_ok($$select public.mark_notifications_read(array[(select id from public.notifications where kind = 'org.roleChanged')])$$, 'marca uma');
select is((select count(*)::int from public.notifications where read_at is null), 2, 'só aquela virou lida');
select public.mark_notifications_read();
select is((select count(*)::int from public.notifications where read_at is null), 0, 'sem lista, marca todas');
select throws_ok($$update public.notifications set read_at = null$$, '42501', null, 'ninguém desmarca direto');
select public.clear_notifications();
select is_empty($$select 1 from public.notifications$$, 'limpar apaga as lidas');

-- Sair por conta própria não avisa; ser removido, sim.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
insert into ids select 'inv_membro2', public.invite_member((select id from ids where name = 'org'), 'membro', 'member');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select public.accept_invite((select id from ids where name = 'inv_membro2'));
select public.leave_organization((select id from ids where name = 'org'));
select is((select count(*)::int from public.notifications where kind = 'org.removed'), 0, 'quem sai não é avisado');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.remove_member((select id from ids where name = 'org'), '00000000-0000-0000-0000-0000000000b2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is((select data->>'org' from public.notifications where kind = 'org.removed'), 'Acme', 'quem é removido é avisado');

-- Excluir a organização avisa os membros, com o nome que ela tinha.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.invite_member((select id from ids where name = 'org'), 'manu', 'member');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select public.accept_invite((select id from public.my_invites()));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.delete_organization((select id from ids where name = 'org'));
select is((select count(*)::int from public.notifications where kind = 'org.deleted'), 0, 'quem exclui não é avisado');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select is((select data->>'org' from public.notifications where kind = 'org.deleted'), 'Acme', 'o membro sabe qual organização saiu');
select is((select count(*)::int from public.notifications where kind = 'org.removed'), 1, 'a exclusão não vira remoção');

select * from finish();
rollback;
