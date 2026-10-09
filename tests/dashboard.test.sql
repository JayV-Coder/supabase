-- Site 2.10.0: a página Dashboard. Cada conta vê o próprio uso; o sistema
-- inteiro só o admin vê. Os turnos chegam com o fuso do computador.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'admin@teste.local', now()),
  ('00000000-0000-0000-0000-0000000000e2', 'pessoa@teste.local', now());
insert into public.admins (user_id) values ('00000000-0000-0000-0000-0000000000e1');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

-- Agora, escrito como o app escreve: UTC com Z (uso) e o fuso local (turnos).
create function pg_temp.utc(moment timestamptz) returns text language sql as $$
  select to_char(moment at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;
create function pg_temp.local(moment timestamptz) returns text language sql as $$
  select to_char(moment at time zone 'America/Recife', 'YYYY-MM-DD"T"HH24:MI:SS.US"000-03:00"');
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
insert into public.projects (id, name, created_at) values ('p-1', 'app', pg_temp.utc(now()));
insert into public.chats (id, project_id, title, created_at, updated_at) values ('c-1', 'p-1', 'primeiro', pg_temp.utc(now()), pg_temp.utc(now()));
insert into public.turns (id, chat_id, ordinal, status, created_at) values
  ('t-1', 'c-1', 1, 'answered', pg_temp.local(now())),
  ('t-2', 'c-1', 2, 'failed', pg_temp.local(now())),
  ('t-3', 'c-1', 3, 'answered', pg_temp.local(now() - interval '60 days')),
  ('t-4', 'c-1', 4, 'answered', 'sem data');
insert into public.usage_records (id, project_id, chat_id, turn_id, source, model, input_tokens, output_tokens, cost_usd, precision, created_at) values
  ('u-1', 'p-1', 'c-1', 't-1', 'claude', 'sonnet', 100, 50, 0.01, 'reported', pg_temp.utc(now())),
  ('u-2', 'p-1', 'c-1', 't-1', 'jev:entry', 'jev-latest', 1200, 20, null, 'reported', pg_temp.utc(now())),
  ('u-3', 'p-1', 'c-1', 't-3', 'claude', 'sonnet', 900, 900, 0.5, 'reported', pg_temp.utc(now() - interval '60 days'));

select is((public.my_dashboard(30)->'requests'->>'total')::int, 2, 'só os pedidos do período; data inválida fica de fora');
select is((public.my_dashboard(30)->'requests'->>'failed')::int, 1, 'conta o que deu errado');
select is((public.my_dashboard(30)->'usage'->>'calls')::int, 2, 'as chamadas do período');
select is((public.my_dashboard(30)->'usage'->>'jev_calls')::int, 1, 'as do Jev à parte');
select is((public.my_dashboard(30)->'totals'->>'requests')::int, 4, 'o total desde o início');
select is(jsonb_array_length(public.my_dashboard(7)->'daily'), 7, 'um dia por dia do período');
select is((public.my_dashboard(7)->'daily'->-1->>'requests')::int, 2, 'hoje tem os dois pedidos');
select is(public.my_dashboard(30)->'environments'->0->>'id', 'personal', 'o pessoal vem primeiro');
select is(public.my_dashboard(30)->'recent_chats'->0->>'project', 'app', 'o chat recente diz o projeto');
select throws_ok($$ select public.admin_dashboard(30) $$, 'P0001', 'admin.forbidden', 'quem não é admin não vê o sistema');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select is((public.admin_dashboard(30)->'activity'->>'requests')::int, 2, 'o admin vê os pedidos de todo mundo');
select is((public.admin_dashboard(30)->'top_users'->0->>'user_id'), '00000000-0000-0000-0000-0000000000e2', 'quem mais usou vem primeiro');

select * from finish();
rollback;
