-- Um usuário não lê nem escreve o que é de outro; só admins escrevem o
-- conteúdo global; a escrita atrasada não passa por cima da recente.
begin;
create extension if not exists pgtap with schema extensions;
select plan(35);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@teste.local'),
  ('00000000-0000-0000-0000-00000000000b', 'b@teste.local');
insert into public.locales (id, name) values ('pt-BR', 'Português') on conflict (id) do nothing;
insert into public.translations (locale, key, value) values ('pt-BR', 'app.title', '"JayV"') on conflict do nothing;
insert into public.jev_questions (question_set, id, body) values ('entry', 'goal_is_clear', '{}') on conflict do nothing;

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

-- Perfil: nasce com a conta, só o dono lê e muda, valores fechados.
reset role;
insert into auth.users (id, email, raw_user_meta_data, encrypted_password) values
  ('00000000-0000-0000-0000-00000000000c', 'carla@teste.local', '{"display_name":"Carla"}', 'x'),
  ('00000000-0000-0000-0000-00000000000d', 'dev.d@teste.local', '{"user_name":"devd"}', '');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000000c'), 'Carla', 'o registro dá o nome');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000000d'), 'devd', 'o OAuth dá o nome');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select is_empty($$select 1 from public.profiles where user_id <> auth.uid()$$, 'ninguém lê o perfil de outro');
select lives_ok($$update public.profiles set gender = 'other', gender_custom = 'agênero' where user_id = auth.uid()$$, 'o dono muda o próprio perfil');
select throws_ok($$update public.profiles set sex = 'x' where user_id = auth.uid()$$, '23514', null, 'valor fora da lista é recusado');
select throws_ok($$update public.profiles set gender = 'woman', gender_custom = 'x' where user_id = auth.uid()$$, '23514', null, 'texto livre só com other');
select throws_ok($$insert into public.profiles (user_id, display_name) values (auth.uid(), 'x')$$, '42501', null, 'o cliente não cria perfil');
select throws_ok($$delete from public.profiles$$, '42501', null, 'o cliente não apaga perfil');
select results_eq($$select public.account_has_password()$$, $$values (true)$$, 'a conta com senha diz que tem');

-- Nome de usuário: gerado, único sem diferenciar caixa, com sufixo na colisão.
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000e', 'carla@outro.local', '{}');
select is((select username from public.profiles where user_id = '00000000-0000-0000-0000-00000000000c'), 'carla', 'o e-mail dá o nome de usuário');
select is((select username from public.profiles where user_id = '00000000-0000-0000-0000-00000000000e'), 'carla-2', 'a colisão ganha sufixo');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select throws_ok($$update public.profiles set username = 'Ana!' where user_id = auth.uid()$$, '23514', null, 'formato fora da regra é recusado');
select throws_ok($$update public.profiles set username = 'devd' where user_id = auth.uid()$$, '23505', null, 'nome de outro é recusado');
select results_eq($$select public.username_available('devd'), public.username_available('carla'), public.username_available('nova-ana'), public.username_available('a')$$,
  $$values (false, true, true, false)$$, 'disponibilidade: de outro não, o próprio sim, livre sim, curto não');
select lives_ok($$update public.profiles set username = 'nova-ana' where user_id = auth.uid()$$, 'o dono troca o próprio nome de usuário');
-- Depois de gravado, o nome de usuário não muda mais.
select lives_ok($$update public.profiles set username = 'ana-fixa', username_set_at = now() where user_id = auth.uid()$$, 'a primeira gravação fixa o nome');
select throws_ok($$update public.profiles set username = 'outra-ana' where user_id = auth.uid()$$, 'P0001', 'profile.username.locked', 'nome fixado não muda');
select throws_ok($$update public.profiles set username = 'outra-ana', username_set_at = null where user_id = auth.uid()$$, 'P0001', 'profile.username.locked', 'apagar a marca não destrava');
select lives_ok($$update public.profiles set display_name = 'Ana', username = 'ana-fixa', username_set_at = now() where user_id = auth.uid()$$, 'o resto do perfil continua mudando');
select is((select username || ':' || (username_set_at is not null) from public.profiles where user_id = auth.uid()), 'ana-fixa:true', 'o nome e a marca ficam');
reset role;
set local role anon;
select throws_ok($$select public.username_available('x')$$, '42501', null, 'sem sessão não consulta nomes');
reset role;

select * from finish();
rollback;
