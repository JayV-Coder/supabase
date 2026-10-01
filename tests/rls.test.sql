-- Um usuário não lê nem escreve o que é de outro; só admins escrevem o
-- conteúdo global; a escrita atrasada não passa por cima da recente.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@teste.local'),
  ('00000000-0000-0000-0000-00000000000b', 'b@teste.local');
insert into public.locales (id, name) values ('pt-BR', 'Português');
insert into public.translations (locale, key, value) values ('pt-BR', 'app.title', '"JayV"');
insert into public.jev_questions (question_set, id, body) values ('entry', 'goal_is_clear', '{}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

-- A cria um projeto.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.projects (id, name, created_at, row_updated_at) values ('p-a', 'Loja', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z')$$,
  'o dono cria o projeto');
select is((select user_id from public.projects where id = 'p-a'), '00000000-0000-0000-0000-00000000000a'::uuid,
  'user_id vem da sessão');

-- B não vê, não muda e não escreve em nome de A.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is_empty($$select id from public.projects where id = 'p-a'$$, 'B não vê o projeto de A');
update public.projects set name = 'Invadido' where id = 'p-a';
select throws_ok(
  $$insert into public.projects (id, name, created_at, user_id) values ('p-b', 'X', '2026-09-30T12:00:00Z', '00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'B não grava em nome de A');
select throws_ok($$delete from public.projects$$, '42501', null, 'ninguém apaga linha');
reset role;
select is((select name from public.projects where id = 'p-a'), 'Loja', 'o update de B não chegou à linha de A');

-- Edição mais recente ganha; o cursor do servidor anda. As horas ficam no
-- passado distante para não disputar com o `now()` do padrão.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update public.projects set name = 'Nova', row_updated_at = '2000-01-01T13:00:00Z' where id = 'p-a';
reset role;
create temp table seen as select synced_at from public.projects where id = 'p-a';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into public.projects (id, name, created_at, row_updated_at) values ('p-a', 'Velha', '2000-01-01T12:00:00Z', '2000-01-01T12:30:00Z')
  on conflict (id) do update set name = excluded.name, row_updated_at = excluded.row_updated_at;
reset role;
select is((select name from public.projects where id = 'p-a'), 'Nova', 'a escrita atrasada é descartada');
select is((select synced_at from public.projects where id = 'p-a'), (select synced_at from seen), 'descartar não move o cursor');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update public.projects set name = 'Mais nova', row_updated_at = '2000-01-01T14:00:00Z' where id = 'p-a';
reset role;
select ok((select synced_at from public.projects where id = 'p-a') > (select synced_at from seen), 'synced_at anda a cada escrita aceita');

-- Conteúdo global.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select throws_ok($$insert into public.translations (locale, key, value) values ('pt-BR', 'x', '"y"')$$,
  '42501', null, 'quem não é admin não escreve traduções');
reset role;
insert into public.admins (user_id) values ('00000000-0000-0000-0000-00000000000b');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select lives_ok($$insert into public.translations (locale, key, value) values ('pt-BR', 'x', '"y"')$$, 'admin escreve traduções');

select results_eq($$select public.jev_take_call(2) union all select public.jev_take_call(2) union all select public.jev_take_call(2)$$,
  $$values (true), (true), (false)$$, 'o limite diário corta a terceira chamada');

reset role;
set local role anon;
select isnt_empty($$select key from public.translations where locale = 'pt-BR'$$, 'a tela de login lê as traduções sem sessão');
select throws_ok($$select id from public.jev_questions$$, '42501', null, 'as instruções do Jev não são públicas');

select * from finish();
rollback;
