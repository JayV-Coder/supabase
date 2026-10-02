-- Apagar um projeto apaga, no Supabase, os chats dele e tudo o que eles
-- guardam — inclusive o que outra máquina subiu e esta nunca baixou — e nada
-- volta à vida por uma escrita atrasada.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@teste.local');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into public.projects (id, name, created_at, row_updated_at) values
  ('p-1', 'Loja', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z'),
  ('p-2', 'Outro', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.chats (id, project_id, title, created_at, updated_at, row_updated_at) values
  ('c-1', 'p-1', 'Um', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z'),
  -- Escrito por outra máquina depois: quem apaga o projeto não o conhece.
  ('c-2', 'p-1', 'Dois', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T13:30:00Z'),
  ('c-3', 'p-2', 'Fica', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.turns (id, chat_id, ordinal, status, created_at, row_updated_at) values
  ('t-1', 'c-1', 1, 'done', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z'),
  ('t-3', 'c-3', 1, 'done', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.messages (uid, chat_id, turn_id, role, content, created_at, row_updated_at) values
  ('m-1', 'c-1', 't-1', 'user', 'Pergunta', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z'),
  ('m-3', 'c-3', 't-3', 'user', 'Pergunta', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.turn_events (id, turn_id, at, seq, kind, detail, row_updated_at) values
  ('e-1', 't-1', '2000-01-01T12:00:00Z', 1, 'start', '', '2000-01-01T12:00:00Z');
insert into public.questions (turn_id, at, kind, prompt, options, source, status, row_updated_at) values
  ('t-1', '2000-01-01T12:00:00Z', 'choice', 'Qual?', '[]', 'jev', 'open', '2000-01-01T12:00:00Z');

create temp table before_delete on commit drop as select clock_timestamp() as at;
grant all on before_delete to authenticated;

-- A máquina apaga o projeto às 13h.
update public.projects set row_deleted_at = '2000-01-01T13:00:00Z', row_updated_at = '2000-01-01T13:00:00Z' where id = 'p-1';

select is((select row_deleted_at from public.chats where id = 'c-1'), '2000-01-01T13:00:00Z'::timestamptz,
  'o chat do projeto apagado é apagado com a hora do projeto');
select isnt((select row_deleted_at from public.chats where id = 'c-2'), null,
  'o chat que esta máquina não conhecia também é apagado');
select is((select row_updated_at from public.chats where id = 'c-2'), '2000-01-01T13:30:00Z'::timestamptz,
  'a marca não recua o row_updated_at do chat escrito depois');
select isnt((select row_deleted_at from public.turns where id = 't-1'), null, 'o turno do chat vai junto');
select isnt((select row_deleted_at from public.messages where uid = 'm-1'), null, 'a mensagem do chat vai junto');
select isnt((select row_deleted_at from public.turn_events where id = 'e-1'), null, 'o evento do turno vai junto');
select isnt((select row_deleted_at from public.questions where turn_id = 't-1'), null, 'a pergunta do turno vai junto');
select ok((select synced_at >= (select at from before_delete) from public.chats where id = 'c-2'),
  'o synced_at anda, para as outras máquinas baixarem a exclusão');

select is((select row_deleted_at from public.chats where id = 'c-3'), null, 'o chat de outro projeto fica');
select is((select row_deleted_at from public.messages where uid = 'm-3'), null, 'a mensagem de outro projeto fica');

-- Uma máquina atrasada sobe o chat vivo e uma mensagem nova nele.
insert into public.chats (id, project_id, title, created_at, updated_at, row_updated_at, row_deleted_at)
  values ('c-2', 'p-1', 'Dois de novo', '2000-01-01T12:00:00Z', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z', null)
  on conflict (id) do update set title = excluded.title, updated_at = excluded.updated_at,
    row_updated_at = excluded.row_updated_at, row_deleted_at = excluded.row_deleted_at;
select isnt((select row_deleted_at from public.chats where id = 'c-2'), null,
  'a escrita atrasada não ressuscita o chat de projeto apagado');
insert into public.chats (id, project_id, title, created_at, updated_at, row_updated_at) values
  ('c-4', 'p-1', 'Novo', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z');
select isnt((select row_deleted_at from public.chats where id = 'c-4'), null,
  'o chat que chega num projeto apagado nasce apagado');
insert into public.messages (uid, chat_id, role, content, created_at, row_updated_at) values
  ('m-4', 'c-1', 'user', 'Atrasada', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z');
select isnt((select row_deleted_at from public.messages where uid = 'm-4'), null,
  'a mensagem que chega num chat apagado nasce apagada');

-- Apagar um chat sozinho também desce para o que é dele.
update public.chats set row_deleted_at = '2000-01-01T15:00:00Z', row_updated_at = '2000-01-01T15:00:00Z' where id = 'c-3';
select isnt((select row_deleted_at from public.messages where uid = 'm-3'), null, 'apagar o chat apaga as mensagens dele');

select * from finish();
rollback;
