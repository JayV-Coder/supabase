-- App 0.87.0: a Administração vê a conta por ambiente; só o admin chama.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@teste.local', now(), '{"user_name":"adm"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'pessoa@teste.local', now(), '{"user_name":"pessoa"}');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;
insert into ids select 'org', public.create_organization('Acme', 'acme');
insert into public.projects (id, name, created_at, org_id) values (gen_random_uuid(), 'da org', 'x', (select id from ids where name = 'org'));
insert into public.projects (id, name, created_at) values (gen_random_uuid(), 'pessoal', 'x');

select throws_ok($$ select public.admin_user_environments('00000000-0000-0000-0000-0000000000b2') $$, 'P0001', 'admin.forbidden', 'quem não é admin não vê');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select is(jsonb_array_length(public.admin_user_environments('00000000-0000-0000-0000-0000000000b2')), 2, 'o pessoal e uma organização');
select is((public.admin_user_environments('00000000-0000-0000-0000-0000000000b2')->0->>'id'), 'personal', 'o pessoal vem primeiro');
select is((public.admin_user_environments('00000000-0000-0000-0000-0000000000b2')->0->>'projects')::int, 1, 'projeto pessoal no pessoal');
select is((public.admin_user_environments('00000000-0000-0000-0000-0000000000b2')->1->>'projects')::int, 1, 'projeto da organização no ambiente dela');

select * from finish();
rollback;
