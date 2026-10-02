-- Com o app autenticador confirmado, uma sessão só com a senha (`aal1`) não
-- lê nem escreve nada além dos textos da tela; com o código (`aal2`), tudo
-- volta ao normal. Conta sem app autenticador segue como antes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@teste.local'),
  ('00000000-0000-0000-0000-00000000000b', 'b@teste.local');
insert into auth.mfa_factors (user_id, status) values
  ('00000000-0000-0000-0000-00000000000a', 'verified'),
  -- Cadastro pela metade não conta.
  ('00000000-0000-0000-0000-00000000000b', 'unverified');

create function pg_temp.as_user(id uuid, aal text) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', aal)::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', 'aal2');
insert into public.projects (id, name, created_at, row_updated_at) values ('p-a', 'Um', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z');
select ok(public.second_factor_ok(), 'aal2 com app autenticador passa');
select is((select count(*) from public.projects), 1::bigint, 'aal2 lê os próprios projetos');
select lives_ok($$ select public.require_second_factor() $$, 'aal2 passa pela checagem do PostgREST');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000a', 'aal1');
select ok(not public.second_factor_ok(), 'aal1 com app autenticador não passa');
select is((select count(*) from public.projects), 0::bigint, 'aal1 não lê os projetos');
select throws_ok($$ insert into public.projects (id, name, created_at, row_updated_at) values ('p-x', 'X', '2000-01-01T12:00:00Z', '2000-01-01T12:00:00Z') $$, '42501', null, 'aal1 não escreve');
select is((select count(*) from public.profiles), 0::bigint, 'aal1 não lê o perfil');
select throws_ok($$ select public.require_second_factor() $$, 'PT403', 'second factor required', 'aal1 é recusado antes de qualquer RPC');
select set_config('request.path', '/translations', true);
select lives_ok($$ select public.require_second_factor() $$, 'aal1 ainda lê os textos da tela');
select ok((select count(*) from public.translations where key = 'auth.secondFactor.title') = 10, 'a tela do código tem texto nos dez idiomas');
select set_config('request.path', '/rpc/account_has_password', true);

select pg_temp.as_user('00000000-0000-0000-0000-00000000000b', 'aal1');
select ok(public.second_factor_ok(), 'conta sem app confirmado segue só com a senha');
select lives_ok($$ select public.require_second_factor() $$, 'e passa pela checagem do PostgREST');

select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
select ok(public.second_factor_ok(), 'sem sessão não há segundo fator a exigir');

select * from finish();
rollback;
