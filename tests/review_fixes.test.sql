-- v0.50.1: escrever textos e idiomas exige o segundo fator; ler, não. E a
-- chamada ao Jev devolvida não conta no limite do dia.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000ad', 'admin@teste.local');
insert into auth.mfa_factors (user_id, status) values ('00000000-0000-0000-0000-0000000000ad', 'verified');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000ad');

create function pg_temp.as_user(id uuid, aal text) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', aal)::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000ad', 'aal1');
select ok((select count(*) from public.translations) > 0, 'aal1 ainda lê os textos');
select throws_ok($$ insert into public.translations (locale, key, value) values ('en', 'test.key', '"x"') $$, '42501', null, 'admin com só a senha não escreve textos');
select is((select count(*) from public.translations where key = 'auth.secondFactor.title' and value = '"x"'::jsonb), 0::bigint, 'nem muda os que existem');
select set_config('request.path', '/translations', true);
select set_config('request.method', 'POST', true);
select throws_ok($$ select public.require_second_factor() $$, 'PT403', 'second factor required', 'o PostgREST recusa escrita nos textos sem o segundo fator');
select set_config('request.method', 'GET', true);
select lives_ok($$ select public.require_second_factor() $$, 'e segue deixando ler');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000ad', 'aal2');
select lives_ok($$ insert into public.translations (locale, key, value) values ('en', 'test.key', '"x"') $$, 'com o segundo fator o admin escreve');
select public.jev_count_call();
select public.jev_count_call();
select public.jev_refund_call();
reset role;
select is((select calls from public.jev_usage where user_id = '00000000-0000-0000-0000-0000000000ad'), 1, 'a chamada devolvida sai da conta do dia');

select * from finish();
rollback;
