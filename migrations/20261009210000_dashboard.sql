-- Site 2.10.0: a página Dashboard do painel. Quem entra no site cai nela:
-- `my_dashboard` mostra o uso do app da própria conta e `admin_dashboard`, só
-- para o admin, o uso do sistema inteiro (contas, acessos, pedidos, chats,
-- tokens e custo). As duas leem o que o app já sincroniza; nada novo é gravado.
--
-- Os dias são cortados no fuso do perfil de quem vê (`profiles.timezone`), ou
-- em UTC sem ele. O `created_at` das tabelas sincronizadas é texto ISO e os
-- turnos o trazem com o fuso do computador (`-03:00`), por isso tudo passa
-- por `dashboard_time`, que lê o instante e devolve nulo para o que não for
-- uma data.

-- O instante de um `created_at` sincronizado, ou nulo.
create function public.dashboard_time(value text) returns timestamptz
language sql stable set search_path = '' as $$
  select case
    when value ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)?$' then value::timestamptz
  end;
$$;
revoke execute on function public.dashboard_time(text) from public, anon;
grant execute on function public.dashboard_time(text) to authenticated;

-- O fuso do perfil, se for um nome que o Postgres conhece; senão, UTC.
create function public.dashboard_zone(person uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select p.timezone from public.profiles p
      where p.user_id = person
        and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p.timezone)),
    'UTC');
$$;
revoke execute on function public.dashboard_zone(uuid) from public, anon, authenticated;

-- 1. O uso da própria conta nos últimos `days` dias (1 a 365): pedidos e o
-- que deu cada um, chamadas a modelos, tokens e custo, o Jev de hoje, a conta
-- de cada dia, os modelos mais usados, cada ambiente e os chats recentes.
create function public.my_dashboard(days int default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
  span int := least(greatest(coalesce(days, 30), 1), 365);
  zone text;
  first_day date;
  since timestamptz;
begin
  if me is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  zone := public.dashboard_zone(me);
  first_day := (now() at time zone zone)::date - (span - 1);
  since := first_day::timestamp at time zone zone;
  return (
    with
    my_turns as (
      select t.status, t.environment_id, t.chat_id, (public.dashboard_time(t.created_at) at time zone zone)::date as day
      from public.turns t
      where t.user_id = me and t.row_deleted_at is null and public.dashboard_time(t.created_at) >= since
    ),
    my_usage as (
      select r.model, r.source, r.environment_id, r.machine_id, r.success, r.duration_ms,
             r.input_tokens + r.output_tokens as tokens, r.input_tokens, r.output_tokens,
             r.cache_read_tokens + r.cache_write_tokens as cache_tokens, coalesce(r.cost_usd, 0) as cost,
             (public.dashboard_time(r.created_at) at time zone zone)::date as day
      from public.usage_records r
      where r.user_id = me and r.row_deleted_at is null and public.dashboard_time(r.created_at) >= since
    ),
    envs as (
      select 'personal'::text as id, null::text as name
      union all
      select o.id::text, o.name from public.organizations o
      join public.organization_members m on m.org_id = o.id and m.user_id = me
    )
    select jsonb_build_object(
      'days', span,
      'zone', zone,
      'from', first_day,
      'totals', jsonb_build_object(
        'projects', (select count(*) from public.projects p where p.user_id = me and p.row_deleted_at is null),
        'chats', (select count(*) from public.chats c where c.user_id = me and c.row_deleted_at is null),
        'requests', (select count(*) from public.turns t where t.user_id = me and t.row_deleted_at is null),
        'organizations', (select count(*) from public.organization_members m where m.user_id = me)
      ),
      'requests', (
        select jsonb_build_object(
          'total', count(*),
          'answered', count(*) filter (where status = 'answered'),
          'failed', count(*) filter (where status = 'failed'),
          'blocked', count(*) filter (where status = 'blocked'),
          'chats', count(distinct chat_id))
        from my_turns),
      'usage', (
        select jsonb_build_object(
          'calls', count(*),
          'failures', count(*) filter (where success = 0),
          'input_tokens', coalesce(sum(input_tokens), 0),
          'output_tokens', coalesce(sum(output_tokens), 0),
          'cache_tokens', coalesce(sum(cache_tokens), 0),
          'cost_usd', coalesce(sum(cost), 0),
          'jev_calls', count(*) filter (where split_part(source, ':', 1) = 'jev'),
          'avg_ms', coalesce(round(avg(duration_ms)), 0),
          'devices', count(distinct machine_id) filter (where machine_id <> ''))
        from my_usage),
      'jev', jsonb_build_object(
        'today', coalesce((select j.calls from public.jev_usage j where j.user_id = me and j.day = (now() at time zone 'utc')::date), 0),
        'limit', public.my_jev_daily_limit()),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'day', d.day, 'requests', coalesce(tt.requests, 0), 'tokens', coalesce(uu.tokens, 0), 'cost_usd', coalesce(uu.cost, 0)
          ) order by d.day), '[]'::jsonb)
        from (select first_day + g as day from generate_series(0, span - 1) g) d
        left join (select day, count(*) as requests from my_turns group by day) tt on tt.day = d.day
        left join (select day, sum(tokens) as tokens, sum(cost) as cost from my_usage group by day) uu on uu.day = d.day),
      'models', (
        select coalesce(jsonb_agg(jsonb_build_object('model', model, 'calls', calls, 'tokens', tokens, 'cost_usd', cost) order by calls desc, model), '[]'::jsonb)
        from (select model, count(*) as calls, sum(tokens) as tokens, sum(cost) as cost from my_usage group by model order by count(*) desc, model limit 8) top),
      'environments', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'id', envs.id, 'name', envs.name,
            'requests', (select count(*) from my_turns t where t.environment_id = envs.id),
            'tokens', (select coalesce(sum(u.tokens), 0) from my_usage u where u.environment_id = envs.id),
            'cost_usd', (select coalesce(sum(u.cost), 0) from my_usage u where u.environment_id = envs.id)
          ) order by (envs.id <> 'personal'), envs.name), '[]'::jsonb)
        from envs),
      'recent_chats', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'id', c.id, 'code', c.code, 'title', c.title, 'project', c.project, 'environment', c.environment_id,
            'environment_name', c.environment_name, 'updated_at', c.touched
          ) order by c.touched desc), '[]'::jsonb)
        from (
          select c.id, c.code, c.title, p.name as project, c.environment_id, o.name as environment_name,
                 public.dashboard_time(c.updated_at) as touched
          from public.chats c
          left join public.projects p on p.id = c.project_id and p.user_id = c.user_id
          left join public.organizations o on o.id::text = c.environment_id
          where c.user_id = me and c.row_deleted_at is null and public.dashboard_time(c.updated_at) is not null
          order by public.dashboard_time(c.updated_at) desc
          limit 6
        ) c)
    )
  );
end;
$$;
revoke execute on function public.my_dashboard(int) from public, anon;
grant execute on function public.my_dashboard(int) to authenticated;

-- 2. O sistema inteiro nos últimos `days` dias, só para o admin: contas
-- (novas, confirmadas, com segundo fator, bloqueadas), acessos (quem entrou
-- e as sessões abertas), quem usou o app, pedidos e chats, chamadas, tokens e
-- custo, o Jev, organizações, planos, a conta de cada dia, as contas que mais
-- usaram, os modelos e as contas novas.
--
-- As sessões vêm de `auth.sessions`, que só guarda as que não saíram: o
-- número de acessos por dia é o das sessões abertas naquele dia que ainda
-- existem.
create function public.admin_dashboard(days int default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
  span int := least(greatest(coalesce(days, 30), 1), 365);
  zone text;
  first_day date;
  since timestamptz;
begin
  perform public.admin_require();
  zone := public.dashboard_zone(me);
  first_day := (now() at time zone zone)::date - (span - 1);
  since := first_day::timestamp at time zone zone;
  return (
    with
    all_turns as (
      select t.user_id, t.status, t.environment_id, public.dashboard_time(t.created_at) as ts
      from public.turns t
      where t.row_deleted_at is null
    ),
    turns_p as (
      select user_id, status, environment_id, (ts at time zone zone)::date as day from all_turns where ts >= since
    ),
    usage_p as (
      select r.user_id, r.model, r.source, r.success, r.input_tokens + r.output_tokens as tokens,
             r.cache_read_tokens + r.cache_write_tokens as cache_tokens, coalesce(r.cost_usd, 0) as cost,
             (public.dashboard_time(r.created_at) at time zone zone)::date as day
      from public.usage_records r
      where r.row_deleted_at is null and public.dashboard_time(r.created_at) >= since
    ),
    sessions_p as (
      select s.user_id, (s.created_at at time zone zone)::date as day from auth.sessions s where s.created_at >= since
    ),
    signups_p as (
      select u.id, (u.created_at at time zone zone)::date as day from auth.users u where u.created_at >= since
    ),
    per_user as (
      select coalesce(t.user_id, u.user_id) as user_id, coalesce(t.requests, 0) as requests,
             coalesce(u.tokens, 0) as tokens, coalesce(u.cost, 0) as cost
      from (select user_id, count(*) as requests from turns_p group by user_id) t
      full join (select user_id, sum(tokens) as tokens, sum(cost) as cost from usage_p group by user_id) u on u.user_id = t.user_id
    )
    select jsonb_build_object(
      'days', span,
      'zone', zone,
      'from', first_day,
      'users', (
        select jsonb_build_object(
          'total', count(*),
          'new', count(*) filter (where u.created_at >= since),
          'confirmed', count(*) filter (where u.email_confirmed_at is not null),
          'mfa', count(*) filter (where exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified')),
          'banned', count(*) filter (where u.banned_until > now()),
          'admins', (select count(*) from public.admins),
          'signed_in_day', count(*) filter (where u.last_sign_in_at >= now() - interval '1 day'),
          'signed_in_week', count(*) filter (where u.last_sign_in_at >= now() - interval '7 days'),
          'signed_in_period', count(*) filter (where u.last_sign_in_at >= since))
        from auth.users u),
      'access', jsonb_build_object(
        'sessions', (select count(*) from sessions_p),
        'open_sessions', (select count(*) from auth.sessions s where s.not_after is null or s.not_after > now()),
        'active_period', (select count(distinct user_id) from turns_p),
        'active_week', (select count(distinct user_id) from all_turns where ts >= now() - interval '7 days'),
        'active_day', (select count(distinct user_id) from all_turns where ts >= now() - interval '1 day')),
      'activity', jsonb_build_object(
        'projects', (select count(*) from public.projects p where p.row_deleted_at is null),
        'chats', (select count(*) from public.chats c where c.row_deleted_at is null),
        'chats_new', (select count(*) from public.chats c where c.row_deleted_at is null and public.dashboard_time(c.created_at) >= since),
        'messages', (select count(*) from public.messages m where m.row_deleted_at is null and public.dashboard_time(m.created_at) >= since),
        'requests', (select count(*) from turns_p),
        'answered', (select count(*) from turns_p where status = 'answered'),
        'failed', (select count(*) from turns_p where status = 'failed'),
        'blocked', (select count(*) from turns_p where status = 'blocked'),
        'organization_requests', (select count(*) from turns_p where environment_id <> 'personal')),
      'usage', (
        select jsonb_build_object(
          'calls', count(*),
          'failures', count(*) filter (where success = 0),
          'tokens', coalesce(sum(tokens), 0),
          'cache_tokens', coalesce(sum(cache_tokens), 0),
          'cost_usd', coalesce(sum(cost), 0),
          'jev_calls', count(*) filter (where split_part(source, ':', 1) = 'jev'),
          'jev_cost_usd', coalesce(sum(cost) filter (where split_part(source, ':', 1) = 'jev'), 0))
        from usage_p),
      'jev', (
        select jsonb_build_object('calls', coalesce(sum(j.calls), 0), 'users', count(distinct j.user_id))
        from public.jev_usage j where j.day >= (since at time zone 'utc')::date),
      'organizations', jsonb_build_object(
        'total', (select count(*) from public.organizations),
        'members', (select count(*) from public.organization_members),
        'repositories', (select count(*) from public.organization_repositories)),
      'plans', (
        select coalesce(jsonb_agg(jsonb_build_object('key', x.plan_key, 'name', p.name, 'users', x.users) order by x.users desc, x.plan_key), '[]'::jsonb)
        from (select public.plan_of(u.id) as plan_key, count(*) as users from auth.users u group by 1) x
        left join public.plans p on p.key = x.plan_key),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'day', d.day,
            'signups', (select count(*) from signups_p s where s.day = d.day),
            'sessions', (select count(*) from sessions_p s where s.day = d.day),
            'active', (select count(distinct t.user_id) from turns_p t where t.day = d.day),
            'requests', (select count(*) from turns_p t where t.day = d.day),
            'tokens', (select coalesce(sum(u.tokens), 0) from usage_p u where u.day = d.day),
            'cost_usd', (select coalesce(sum(u.cost), 0) from usage_p u where u.day = d.day)
          ) order by d.day), '[]'::jsonb)
        from (select first_day + g as day from generate_series(0, span - 1) g) d),
      'top_users', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', x.user_id, 'email', u.email, 'username', pr.username, 'display_name', pr.display_name, 'avatar_url', pr.avatar_url,
            'requests', x.requests, 'tokens', x.tokens, 'cost_usd', x.cost, 'last_sign_in_at', u.last_sign_in_at
          ) order by x.requests desc, x.cost desc, x.user_id), '[]'::jsonb)
        from (select * from per_user order by requests desc, cost desc, user_id limit 8) x
        join auth.users u on u.id = x.user_id
        left join public.profiles pr on pr.user_id = x.user_id),
      'models', (
        select coalesce(jsonb_agg(jsonb_build_object('model', model, 'calls', calls, 'tokens', tokens, 'cost_usd', cost) order by calls desc, model), '[]'::jsonb)
        from (select model, count(*) as calls, sum(tokens) as tokens, sum(cost) as cost from usage_p group by model order by count(*) desc, model limit 8) top),
      'recent_users', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', u.id, 'email', u.email, 'username', pr.username, 'display_name', pr.display_name, 'avatar_url', pr.avatar_url,
            'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at
          ) order by u.created_at desc), '[]'::jsonb)
        from (select * from auth.users order by created_at desc limit 6) u
        left join public.profiles pr on pr.user_id = u.id)
    )
  );
end;
$$;
revoke execute on function public.admin_dashboard(int) from public, anon;
grant execute on function public.admin_dashboard(int) to authenticated;
