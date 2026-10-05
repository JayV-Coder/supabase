-- v0.59.1: a chamada ao Jev repetida pelo app conta uma vez no limite do dia;
-- a devolvida volta para o limite e conta de novo se for repetida.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'calls@teste.local');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select is(public.jev_count_call('11111111-1111-4111-8111-111111111111'::uuid), 1, 'a primeira vez conta');
select is(public.jev_count_call('11111111-1111-4111-8111-111111111111'::uuid), 1, 'a repetição com o mesmo id não soma');
select is(public.jev_count_call('22222222-2222-4222-8222-222222222222'::uuid), 2, 'outro id soma');
select lives_ok($$ select public.jev_refund_call('22222222-2222-4222-8222-222222222222'::uuid) $$, 'a recusa devolve a chamada');
select lives_ok($$ select public.jev_refund_call('22222222-2222-4222-8222-222222222222'::uuid) $$, 'devolver duas vezes não quebra');
select is(public.jev_count_call('11111111-1111-4111-8111-111111111111'::uuid), 1, 'e devolve uma vez só');
select is(public.jev_count_call('22222222-2222-4222-8222-222222222222'::uuid), 2, 'o id devolvido conta de novo na repetição');
select is(public.jev_count_call(null::uuid), 3, 'sem id, conta como o app antigo');
select throws_ok($$ select * from public.jev_calls $$, '42501', null, 'ninguém lê os ids pela API');

reset role;
select is((select value from public.jev_parameters where key = 'deadline_seconds'), '8.0'::jsonb, 'o prazo da portaria é parâmetro');

select * from finish();
rollback;
