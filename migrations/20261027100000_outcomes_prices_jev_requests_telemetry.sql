-- App 0.110.0 e site 2.26.0: a Fase 2 do roadmap (prova de economia).
--
-- 1. `model_prices`: a tabela de preços por modelo, em dólares por milhão de
--    tokens, que o admin edita no site. O app e os painéis estimam com ela o
--    dinheiro das chamadas cujo custo a ferramenta não informou.
-- 2. O teto diário do Jev em pedidos: `plans.jev_daily_requests` conta turnos
--    distintos (o cabeçalho `x-jev-turn` que o app manda), não chamadas. O
--    plano padrão (Free) começa com 20. Depois do teto, a função `jev` recusa
--    com `daily_limit` e o app usa a heurística local até a meia-noite UTC.
-- 3. `admin_jev_costs`: o que o Jev custou por plano e por conta, para o admin.
-- 4. `org_usage`: o uso da equipe por semana (pedidos, objetivos, tarefas
--    comprovadas, tokens e dinheiro), para dono e mantenedor no site.
-- 5. A telemetria opcional dos recursos: só com o consentimento de quem usa
--    (`usage_telemetry`), o app conta o uso de cada recurso por dia
--    (`feature_usage`), e o admin vê a lista com o uso em 30 e 60 dias.

-- 1. Preços dos modelos -------------------------------------------------------

create table public.model_prices (
  -- Um pedaço do id do modelo, em minúsculas: `sonnet`, `gpt-5-mini`. O
  -- padrão mais longo contido no id vence.
  pattern text primary key check (pattern = lower(btrim(pattern)) and char_length(pattern) between 1 and 80),
  input_usd numeric(12, 6) not null check (input_usd >= 0),
  output_usd numeric(12, 6) not null check (output_usd >= 0),
  -- Vazio: o cache lido vale um décimo da entrada; o escrito, 1,25×.
  cache_read_usd numeric(12, 6) check (cache_read_usd >= 0),
  cache_write_usd numeric(12, 6) check (cache_write_usd >= 0),
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.model_prices enable row level security;
create policy "quem entrou lê" on public.model_prices for select to authenticated using (true);
revoke insert, update, delete on public.model_prices from anon, authenticated;

-- Grava um preço. `previous` troca o padrão de uma linha que já existia.
create function public.admin_save_model_price(
  pattern text, input_usd numeric, output_usd numeric,
  cache_read_usd numeric default null, cache_write_usd numeric default null, previous text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  chosen text := lower(btrim(coalesce(pattern, '')));
begin
  perform public.admin_require();
  if chosen = '' or char_length(chosen) > 80 or input_usd is null or output_usd is null
     or input_usd < 0 or output_usd < 0 or cache_read_usd < 0 or cache_write_usd < 0 then
    raise exception 'admin.error.priceInvalid';
  end if;
  if previous is not null and lower(btrim(previous)) <> chosen then
    if exists (select 1 from public.model_prices m where m.pattern = chosen) then raise exception 'admin.error.priceDuplicate'; end if;
    delete from public.model_prices m where m.pattern = lower(btrim(previous));
  end if;
  insert into public.model_prices (pattern, input_usd, output_usd, cache_read_usd, cache_write_usd, updated_by, updated_at)
  values (chosen, input_usd, output_usd, cache_read_usd, cache_write_usd, auth.uid(), now())
  on conflict on constraint model_prices_pkey do update set
    input_usd = excluded.input_usd, output_usd = excluded.output_usd, cache_read_usd = excluded.cache_read_usd,
    cache_write_usd = excluded.cache_write_usd, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;
revoke all on function public.admin_save_model_price(text, numeric, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.admin_save_model_price(text, numeric, numeric, numeric, numeric, text) to authenticated;

create function public.admin_delete_model_price(pattern text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_require();
  delete from public.model_prices m where m.pattern = lower(btrim(admin_delete_model_price.pattern));
end;
$$;
revoke all on function public.admin_delete_model_price(text) from public, anon;
grant execute on function public.admin_delete_model_price(text) to authenticated;

-- O dinheiro de uma chamada: o custo informado ou, sem ele, a estimativa pela
-- tabela (o padrão mais longo contido no id do modelo). Nulo sem os dois.
create function public.usage_money(
  model text, cost_usd double precision, input_tokens bigint, output_tokens bigint, cache_read_tokens bigint, cache_write_tokens bigint
) returns double precision language sql stable security definer set search_path = '' as $$
  select coalesce(cost_usd, (
    select ((input_tokens * p.input_usd + output_tokens * p.output_usd
             + cache_read_tokens * coalesce(p.cache_read_usd, p.input_usd * 0.1)
             + cache_write_tokens * coalesce(p.cache_write_usd, p.input_usd * 1.25)) / 1000000)::double precision
    from public.model_prices p
    where strpos(lower(coalesce(model, '')), p.pattern) > 0
    order by char_length(p.pattern) desc
    limit 1));
$$;
revoke all on function public.usage_money(text, double precision, bigint, bigint, bigint, bigint) from public, anon, authenticated;

-- 2. O teto do Jev em pedidos -------------------------------------------------

alter table public.plans add column jev_daily_requests integer check (jev_daily_requests is null or jev_daily_requests > 0);
comment on column public.plans.jev_daily_requests is
  'Pedidos (turnos distintos) por dia que passam pelo Jev completo. Vazio: sem teto em pedidos (vale só jev_daily_limit, em chamadas).';
update public.plans set jev_daily_requests = 20 where is_default;

-- Os pedidos do dia por turno. Só as funções escrevem; ninguém lê.
create table public.jev_turns (
  user_id uuid not null references auth.users on delete cascade,
  day date not null default (now() at time zone 'utc')::date,
  turn_id text not null check (turn_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  primary key (user_id, day, turn_id)
);
alter table public.jev_turns enable row level security;
revoke all on public.jev_turns from anon, authenticated;

-- Conta o turno `turn` uma vez no dia e devolve os pedidos do dia. Os dias de
-- antes de ontem saem na passagem.
create function public.jev_count_turn(turn text) returns int language plpgsql security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
  today date := (now() at time zone 'utc')::date;
begin
  if me is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  if turn is null or turn !~ '^[A-Za-z0-9_-]{1,64}$' then
    raise exception 'jev.turnInvalid';
  end if;
  delete from public.jev_turns where user_id = me and day < today - 1;
  insert into public.jev_turns (user_id, day, turn_id) values (me, today, turn) on conflict do nothing;
  return (select count(*)::int from public.jev_turns where user_id = me and day = today);
end;
$$;
revoke all on function public.jev_count_turn(text) from public, anon;
grant execute on function public.jev_count_turn(text) to authenticated;

-- O teto de pedidos do plano de quem chama. O admin do sistema não tem teto.
create function public.my_jev_request_limit() returns integer language sql stable security definer set search_path = '' as $$
  select case when coalesce(public.is_admin(), false) then null
              else (select p.jev_daily_requests from public.plans p where p.key = public.my_plan()) end;
$$;
revoke all on function public.my_jev_request_limit() from public, anon;
grant execute on function public.my_jev_request_limit() to authenticated;

-- O admin grava o teto de pedidos de um plano (vazio tira o teto). Fica fora
-- do `admin_save_plan` para o site antigo continuar salvando planos.
create function public.admin_set_plan_jev_requests(plan text, requests integer) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_require();
  if requests is not null and requests < 1 then raise exception 'admin.error.planInvalid'; end if;
  update public.plans p set jev_daily_requests = requests, updated_by = auth.uid(), updated_at = now() where p.key = plan;
  if not found then raise exception 'admin.error.planInvalid'; end if;
end;
$$;
revoke all on function public.admin_set_plan_jev_requests(text, integer) from public, anon;
grant execute on function public.admin_set_plan_jev_requests(text, integer) to authenticated;

-- `my_features()` da 0.107.0, com o teto de pedidos em `limits`.
create or replace function public.my_features() returns jsonb language sql stable security definer set search_path = '' as $$
  with mine as (select public.my_plan() as plan_key),
  me as (select coalesce(public.is_admin(), false) as admin),
  included as (
    select f.key, f.position, pf.mode, pf.default_on
    from public.features f
    left join public.plan_features pf on pf.feature_key = f.key and pf.plan_key = (select plan_key from mine)
    where case when (select admin from me) then true else f.enabled and pf.feature_key is not null end
  )
  select jsonb_build_object(
    'plan', (select plan_key from mine),
    'admin', (select admin from me),
    'managed', true,
    'features', coalesce((select jsonb_agg(key order by position, key) from included), '[]'::jsonb),
    'locked', coalesce((select jsonb_agg(key order by position, key) from included
                        where case when (select admin from me) then key in ('keepSessionModel', 'limitResume', 'planBuildSession', 'autoTurnCeiling') else mode = 'locked' end), '[]'::jsonb),
    'defaults', coalesce((select jsonb_object_agg(key, coalesce(default_on, true)) from included where mode is distinct from 'locked' or (select admin from me)), '{}'::jsonb),
    'limits', (select jsonb_build_object('jevDailyLimit', p.jev_daily_limit, 'maxConcurrentTurns', p.max_concurrent_turns,
                                         'jevDailyRequests', case when (select admin from me) then null else p.jev_daily_requests end)
               from public.plans p where p.key = (select plan_key from mine))
  );
$$;

-- 3. O custo do Jev, para o admin ---------------------------------------------

-- Nos últimos `days` dias (1 a 365): por plano, quantas contas usaram o Jev,
-- chamadas, tokens e dinheiro (pela tabela de preços, padrão do modelo do Jev),
-- e a média por conta; e as 20 contas que mais gastaram, com o plano de cada.
create function public.admin_jev_costs(days int default 30) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  span int := least(greatest(coalesce(days, 30), 1), 365);
  since timestamptz := now() - make_interval(days => span);
begin
  perform public.admin_require();
  return (
    with jev as (
      select r.user_id, count(*) as calls,
             sum(r.input_tokens + r.output_tokens) as tokens,
             sum(public.usage_money(r.model, r.cost_usd, r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens)) as money,
             count(*) filter (where public.usage_money(r.model, r.cost_usd, r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens) is null) as unpriced,
             count(distinct r.turn_id) as requests
      from public.usage_records r
      where r.row_deleted_at is null and split_part(r.source, ':', 1) = 'jev' and public.dashboard_time(r.created_at) >= since
      group by r.user_id
    ),
    planned as (select j.*, public.plan_of(j.user_id) as plan_key from jev j)
    select jsonb_build_object(
      'days', span,
      'plans', coalesce((
        select jsonb_agg(jsonb_build_object(
          'plan', x.plan_key, 'users', x.users, 'calls', x.calls, 'requests', x.requests, 'tokens', x.tokens,
          'cost_usd', x.money, 'unpriced_calls', x.unpriced,
          'cost_per_user', case when x.users = 0 or x.money is null then null else x.money / x.users end,
          'requests_per_user_day', case when x.users = 0 then null else x.requests::double precision / x.users / span end
        ) order by x.plan_key)
        from (select plan_key, count(*) as users, sum(calls) as calls, sum(requests) as requests, sum(tokens) as tokens,
                     sum(money) as money, sum(unpriced) as unpriced
              from planned group by plan_key) x), '[]'::jsonb),
      'top', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', p.user_id, 'email', u.email, 'plan', p.plan_key, 'calls', p.calls, 'requests', p.requests,
          'tokens', p.tokens, 'cost_usd', p.money
        ) order by p.tokens desc)
        from (select * from planned order by tokens desc limit 20) p
        left join auth.users u on u.id = p.user_id), '[]'::jsonb)
    )
  );
end;
$$;
revoke all on function public.admin_jev_costs(int) from public, anon;
grant execute on function public.admin_jev_costs(int) to authenticated;

-- 4. O uso da equipe, por semana ------------------------------------------------

-- O uso da organização nas últimas `weeks` semanas (1 a 26), semana começando
-- na segunda-feira no fuso de quem vê. Um chat é um objetivo; o turno validado
-- vale pelo último veredito; o dinheiro é dos agentes (o Jev fica de fora),
-- informado ou estimado pela tabela de preços. Só dono e mantenedor.
create function public.org_usage(org uuid, weeks int default 8) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  span int := least(greatest(coalesce(weeks, 8), 1), 26);
  zone text;
  first_week date;
  since timestamptz;
  env text := org::text;
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  zone := public.dashboard_zone((select auth.uid()));
  first_week := date_trunc('week', (now() at time zone zone))::date - (span - 1) * 7;
  since := first_week::timestamp at time zone zone;
  return (
    with
    t as (
      select t.id, t.chat_id, t.user_id, date_trunc('week', public.dashboard_time(t.created_at) at time zone zone)::date as week
      from public.turns t
      where t.environment_id = env and t.row_deleted_at is null and public.dashboard_time(t.created_at) >= since
    ),
    v as (
      select distinct on (j.user_id, j.turn_id) j.user_id, j.turn_id, j.kind,
             date_trunc('week', public.dashboard_time(j.created_at) at time zone zone)::date as week
      from public.jev_records j
      where j.environment_id = env and j.row_deleted_at is null and j.turn_id is not null
        and j.kind in ('validation:passed', 'validation:failed', 'validation:unproven')
        and public.dashboard_time(j.created_at) >= since
      order by j.user_id, j.turn_id, j.created_at desc, j.id desc
    ),
    u as (
      select r.user_id, date_trunc('week', public.dashboard_time(r.created_at) at time zone zone)::date as week,
             r.input_tokens + r.output_tokens as tokens, r.cost_usd,
             public.usage_money(r.model, r.cost_usd, r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens) as money
      from public.usage_records r
      where r.environment_id = env and r.row_deleted_at is null and split_part(r.source, ':', 1) <> 'jev'
        and public.dashboard_time(r.created_at) >= since
    ),
    weeks_list as (select first_week + g * 7 as week from generate_series(0, span - 1) g)
    select jsonb_build_object(
      'weeks', span,
      'zone', zone,
      'from', first_week,
      'series', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'week', w.week,
          'requests', (select count(*) from t where t.week = w.week),
          'objectives', (select count(distinct t.chat_id) from t where t.week = w.week),
          'members', (select count(distinct t.user_id) from t where t.week = w.week),
          'verified', (select count(*) from v where v.week = w.week and v.kind = 'validation:passed'),
          'failed', (select count(*) from v where v.week = w.week and v.kind = 'validation:failed'),
          'unproven', (select count(*) from v where v.week = w.week and v.kind = 'validation:unproven'),
          'tokens', (select coalesce(sum(u.tokens), 0) from u where u.week = w.week),
          'reported_usd', (select coalesce(sum(u.cost_usd), 0) from u where u.week = w.week),
          'cost_usd', (select coalesce(sum(u.money), 0) from u where u.week = w.week),
          'unpriced_calls', (select count(*) from u where u.week = w.week and u.money is null)
        ) order by w.week), '[]'::jsonb)
        from weeks_list w),
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'user_id', m.user_id, 'name', coalesce(pr.display_name, us.email),
          'requests', (select count(*) from t where t.user_id = m.user_id),
          'verified', (select count(*) from v where v.user_id = m.user_id and v.kind = 'validation:passed'),
          'tokens', (select coalesce(sum(u.tokens), 0) from u where u.user_id = m.user_id),
          'cost_usd', (select coalesce(sum(u.money), 0) from u where u.user_id = m.user_id)
        ) order by (select count(*) from t where t.user_id = m.user_id) desc, coalesce(pr.display_name, us.email)), '[]'::jsonb)
        from public.organization_members m
        left join public.profiles pr on pr.user_id = m.user_id
        left join auth.users us on us.id = m.user_id
        where m.org_id = org)
    )
  );
end;
$$;
revoke all on function public.org_usage(uuid, int) from public, anon;
grant execute on function public.org_usage(uuid, int) to authenticated;

-- 5. Telemetria opcional dos recursos -------------------------------------------

-- Quem aceitou mandar o uso dos recursos. Sem linha, não aceitou.
create table public.usage_telemetry (
  user_id uuid primary key references auth.users on delete cascade,
  granted_at timestamptz not null default now()
);
alter table public.usage_telemetry enable row level security;
create policy "dono lê" on public.usage_telemetry for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.usage_telemetry from anon, authenticated;

-- O uso de cada recurso por dia, de quem aceitou. Só a RPC escreve.
create table public.feature_usage (
  user_id uuid not null references auth.users on delete cascade,
  feature text not null references public.features (key) on delete cascade,
  day date not null,
  uses integer not null check (uses between 1 and 100000),
  primary key (user_id, feature, day)
);
alter table public.feature_usage enable row level security;
create policy "dono lê" on public.feature_usage for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.feature_usage from anon, authenticated;

-- Liga ou desliga o envio. Desligar apaga o que já foi enviado.
create function public.set_usage_telemetry(granted boolean) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then raise exception 'sem sessão' using errcode = '28000'; end if;
  if granted then
    insert into public.usage_telemetry (user_id) values (me) on conflict (user_id) do nothing;
  else
    delete from public.usage_telemetry where user_id = me;
    delete from public.feature_usage where user_id = me;
  end if;
  return granted;
end;
$$;
revoke all on function public.set_usage_telemetry(boolean) from public, anon;
grant execute on function public.set_usage_telemetry(boolean) to authenticated;

-- Soma o uso enviado pelo app: `[{ feature, day, uses }]`. Sem consentimento,
-- recurso desconhecido ou dia fora dos últimos dois, a linha é ignorada.
-- Devolve quantas linhas entraram.
create function public.record_feature_usage(items jsonb) returns int language plpgsql security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
  today date := (now() at time zone 'utc')::date;
  taken int;
begin
  if me is null then raise exception 'sem sessão' using errcode = '28000'; end if;
  if not exists (select 1 from public.usage_telemetry t where t.user_id = me) then return 0; end if;
  if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) > 200 then raise exception 'telemetry.invalid'; end if;
  insert into public.feature_usage as f (user_id, feature, day, uses)
  select me, i.feature, i.day, least(sum(i.uses), 100000)::int
  from (
    select x->>'feature' as feature, (x->>'day')::date as day, (x->>'uses')::int as uses
    from jsonb_array_elements(items) x
    where jsonb_typeof(x) = 'object' and coalesce(x->>'day', '') ~ '^\d{4}-\d{2}-\d{2}$'
      and coalesce(x->>'uses', '') ~ '^[1-9][0-9]{0,4}$'
  ) i
  join public.features ft on ft.key = i.feature
  where i.day between today - 2 and today + 1
  group by i.feature, i.day
  on conflict (user_id, feature, day) do update set uses = least(f.uses + excluded.uses, 100000);
  get diagnostics taken = row_count;
  return taken;
end;
$$;
revoke all on function public.record_feature_usage(jsonb) from public, anon;
grant execute on function public.record_feature_usage(jsonb) to authenticated;

-- O recurso de uma marca do Jev (`jev_records.kind`), para quem aceitou a
-- telemetria: as portarias, a proteção, a sessão, o cache e a memória contam
-- sozinhos, sem o app mandar nada a mais.
create function public.feature_of_jev_kind(kind text) returns text language sql immutable set search_path = '' as $$
  select case
    when kind like 'entry:%' then 'entryGate'
    when kind like 'exit:%' then 'exitGate'
    when kind = 'secret_redacted' then 'secretRedaction'
    when kind = 'file_withheld' then 'sensitiveFiles'
    when kind = 'session_resumed' then 'agentSessions'
    when kind = 'cache_hit' then 'contextCache'
    when kind = 'answer_recalled' then 'answerRecall'
    when kind = 'note_learned' then 'projectNotes'
  end;
$$;

-- Os recursos que o app mede (a lista `MEASURED` de `src/modules/telemetry`
-- no app, mais os que saem das marcas do Jev). Os outros aparecem como "sem
-- medição", e não como zero.
create function public.telemetry_measured() returns text[] language sql immutable set search_path = '' as $$
  select array['organizations', 'orgChat', 'stats', 'gateBoard', 'liveFiles', 'chatSearch', 'conversationFind', 'mcp', 'skills',
               'skillsHub', 'kiloCode', 'gatewayProviders', 'customMods',
               'entryGate', 'exitGate', 'secretRedaction', 'sensitiveFiles', 'agentSessions', 'contextCache', 'answerRecall', 'projectNotes'];
$$;

-- Para o admin: cada recurso do catálogo com quantas contas o usaram e
-- quantas vezes, em 30 e em 60 dias, só de quem aceitou a telemetria.
create function public.admin_feature_usage() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  today date := (now() at time zone 'utc')::date;
begin
  perform public.admin_require();
  return (
    with consenting as (select user_id from public.usage_telemetry),
    signals as (
      select f.user_id, f.feature, f.day, f.uses from public.feature_usage f join consenting c on c.user_id = f.user_id
      where f.day >= today - 60
      union all
      select j.user_id, public.feature_of_jev_kind(j.kind), (public.dashboard_time(j.created_at) at time zone 'utc')::date, greatest(round(j.amount)::int, 1)
      from public.jev_records j join consenting c on c.user_id = j.user_id
      where j.row_deleted_at is null and public.feature_of_jev_kind(j.kind) is not null
        and public.dashboard_time(j.created_at) >= (today - 60)::timestamp at time zone 'utc'
    )
    select jsonb_build_object(
      'consenting', (select count(*) from consenting),
      'features', coalesce(jsonb_agg(jsonb_build_object(
        'feature', ft.key,
        'enabled', ft.enabled,
        'measured', ft.key = any (public.telemetry_measured()),
        'users_30', (select count(distinct s.user_id) from signals s where s.feature = ft.key and s.day > today - 30),
        'users_60', (select count(distinct s.user_id) from signals s where s.feature = ft.key),
        'uses_30', (select coalesce(sum(s.uses), 0) from signals s where s.feature = ft.key and s.day > today - 30),
        'uses_60', (select coalesce(sum(s.uses), 0) from signals s where s.feature = ft.key)
      ) order by ft.position, ft.key), '[]'::jsonb)
    )
    from public.features ft
  );
end;
$$;
revoke all on function public.admin_feature_usage() from public, anon;
grant execute on function public.admin_feature_usage() to authenticated;
