-- O que é só do app fica em `coder`; `public` guarda o compartilhado e, durante a transição, uma
-- view de mesmo nome para cada tabela movida, com o RLS de quem consulta.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

select is((select count(*)::int from information_schema.tables
  where table_schema = 'coder' and table_type = 'BASE TABLE'), 28, 'as 28 tabelas do app estão em coder');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v' and c.relname in (
    select table_name from information_schema.tables where table_schema = 'coder')
  and c.reloptions @> array['security_invoker=true']), 28, 'cada uma tem a view de compatibilidade com security_invoker');
select ok(to_regclass('public.organizations') is not null and (select relkind from pg_class
  where oid = 'public.organizations'::regclass) = 'r', 'organizações seguem tabela em public');
select ok((select relkind from pg_class where oid = 'public.organization_git_connections'::regclass) = 'r',
  'o que o app escuta pelo Realtime fica em public por enquanto');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'coder') and p.prokind in ('f', 'p')
    and p.prosrc ~ ('\mpublic\.(' || (select string_agg(table_name, '|') from information_schema.tables
      where table_schema = 'coder' and table_type = 'BASE TABLE') || ')\M')), 0,
  'nenhuma função do banco cita a tabela antiga em public');

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000c0d01', 'coder-a@teste.local'),
  ('00000000-0000-0000-0000-0000000c0d02', 'coder-b@teste.local');
create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0d01');
insert into public.projects (id, name, created_at) values ('p-view', 'Pela view', '2026-11-12T12:00:00Z');
select is((select count(*)::int from coder.projects where name = 'Pela view'), 1, 'escrever pela view grava em coder');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0d02');
select is((select count(*)::int from public.projects where name = 'Pela view'), 0, 'o RLS vale através da view');

select * from finish();
rollback;
