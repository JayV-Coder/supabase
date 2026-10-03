-- Memória do projeto: cada um lê só as próprias notas, ninguém apaga linha, e
-- apagar o projeto apaga as notas dele sem que uma escrita atrasada as traga
-- de volta.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'dona@teste.local'),
  ('00000000-0000-0000-0000-0000000000c2', 'outra@teste.local');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
insert into public.projects (id, name, created_at, row_updated_at) values
  ('p-1', 'Loja', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.project_notes (id, project_id, kind, body, created_at, updated_at, row_updated_at) values
  ('n-1', 'p-1', 'note', 'Tests: npm test', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
insert into public.project_notes (id, project_id, kind, title, body, trigger, source, created_at, updated_at, row_updated_at) values
  ('n-2', 'p-1', 'recipe', 'Migração', '1. criar o arquivo', 'nova migração', 'manual', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');

select is((select count(*)::int from public.project_notes), 2, 'a dona lê as próprias notas');
select throws_ok(
  $$insert into public.project_notes (id, project_id, kind, body, created_at, updated_at) values ('n-x', 'p-1', 'other', 'x', 'a', 'a')$$,
  '23514', null, 'o tipo é nota ou receita');
select throws_ok($$delete from public.project_notes where id = 'n-1'$$, '42501', null,
  'ninguém apaga linha: a exclusão é a marca');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select is((select count(*)::int from public.project_notes), 0, 'outra conta não lê as notas');
update public.project_notes set body = 'invadido';
reset role;
select is((select body from public.project_notes where id = 'n-1'), 'Tests: npm test', 'outra conta não muda as notas');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
update public.projects set row_deleted_at = '2000-01-01T13:00:00Z', row_updated_at = '2000-01-01T13:00:00Z' where id = 'p-1';
select is((select count(*)::int from public.project_notes where row_deleted_at is null), 0, 'apagar o projeto apaga as notas dele');

insert into public.project_notes (id, project_id, kind, body, created_at, updated_at, row_updated_at, row_deleted_at)
  values ('n-1', 'p-1', 'note', 'Atrasada', '2000-01-01T12:00:00Z', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z', null)
  on conflict (id) do update set body = excluded.body, updated_at = excluded.updated_at,
    row_updated_at = excluded.row_updated_at, row_deleted_at = excluded.row_deleted_at;
select isnt((select row_deleted_at from public.project_notes where id = 'n-1'), null,
  'a escrita atrasada não ressuscita a nota de projeto apagado');
insert into public.project_notes (id, project_id, kind, body, created_at, updated_at, row_updated_at) values
  ('n-3', 'p-1', 'note', 'Nova', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z', '2000-01-01T14:00:00Z');
select isnt((select row_deleted_at from public.project_notes where id = 'n-3'), null,
  'a nota que chega num projeto apagado nasce apagada');

select * from finish();
rollback;
