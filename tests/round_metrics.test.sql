-- Métricas de voltas (v0.55.0): cada conta vê só as próprias linhas pelas
-- views, e a retomada de sessão sai com o motivo de cada sessão nova.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000d1', 'dona@teste.local'),
  ('00000000-0000-0000-0000-0000000000d2', 'outra@teste.local');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true);
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
insert into public.jev_records (id, chat_id, turn_id, kind, amount, precision, created_at) values
  ('m-1', 'c-1', 't-1', 'session_new:first', 1, 'reported', '2026-10-05T12:00:00Z'),
  ('m-2', 'c-1', 't-2', 'session_new:other_model', 1, 'reported', '2026-10-05T12:01:00Z'),
  ('m-3', 'c-1', 't-3', 'session_resumed', 1, 'reported', '2026-10-05T12:02:00Z'),
  ('m-4', 'c-1', 't-3', 'cache_hit', 1, 'reported', '2026-10-05T12:02:00Z');
insert into public.usage_records (id, chat_id, turn_id, source, model, input_tokens, output_tokens, cost_usd, precision, created_at) values
  ('u-1', 'c-1', 't-1', 'claude', 'sonnet', 100, 50, 0.01, 'reported', '2026-10-05T12:00:00Z'),
  ('u-2', 'c-1', 't-1', 'jev:entry', 'jev-latest', 1200, 20, null, 'reported', '2026-10-05T12:00:00Z');

select is((select sessions from public.jev_metric_agent_sessions where outcome = 'new' and reason = 'other_model'), 1::bigint,
  'a sessão nova sai com o motivo');
select is((select sessions from public.jev_metric_agent_sessions where outcome = 'resumed'), 1::bigint,
  'a retomada conta à parte');
select is((select resume_rate from public.jev_metric_chat_resume_rate where chat_id = 'c-1'), 0.33::numeric,
  'outras marcas do Jev não entram na taxa de retomada');
select is((select calls from public.jev_metric_spend_by_source where source = 'jev:entry'), 1::bigint,
  'o gasto do Jev aparece separado do agente');
select is((select tokens from public.jev_metric_chat_cost where chat_id = 'c-1'), 1370::bigint,
  'o custo do chat soma agente e Jev');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select is((select count(*)::int from public.jev_metric_agent_sessions), 0,
  'outra conta não vê as sessões de ninguém');

select * from finish();
rollback;
