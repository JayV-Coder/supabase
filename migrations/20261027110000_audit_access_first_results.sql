-- App 0.111.0 e site 2.27.0 (Fase 3 do roadmap): o log de auditoria da
-- organização, o que cada membro pode fazer pelo plano dele e o tempo até o
-- primeiro resultado comprovado.

-- 1. Log de auditoria --------------------------------------------------------

-- Os pedidos feitos nos projetos da organização entre dois dias (inclusive,
-- no fuso de quem pede, no máximo 366 dias e 5000 pedidos, os mais novos):
-- quem pediu, em que projeto, o veredito da portaria, o agente e o modelo, o
-- modo, os comandos que o JayV validou e as ferramentas que o agente relatou,
-- o resultado da validação, os reparos, tokens e custo. O texto do pedido não
-- sai daqui: a auditoria diz quem fez o quê, não o que cada um escreveu.
-- Só owner e maintainer.
create function public.org_audit(org uuid, from_day date, to_day date) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  env text := org::text;
  zone text;
  since timestamptz;
  until timestamptz;
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if from_day is null or to_day is null or to_day < from_day or to_day - from_day > 366 then
    raise exception 'org.auditRange';
  end if;
  zone := public.dashboard_zone((select auth.uid()));
  since := from_day::timestamp at time zone zone;
  until := (to_day + 1)::timestamp at time zone zone;
  return (
    with t as (
      select t.id, t.user_id, t.chat_id, t.status, public.dashboard_time(t.created_at) as at
      from public.turns t
      where t.environment_id = env and t.row_deleted_at is null
        and public.dashboard_time(t.created_at) >= since and public.dashboard_time(t.created_at) < until
      order by public.dashboard_time(t.created_at) desc
      limit 5000
    ),
    e as (
      select e.user_id, e.turn_id, e.kind, e.seq, e.detail::jsonb as d
      from public.turn_events e join t on t.id = e.turn_id and t.user_id = e.user_id
      where e.row_deleted_at is null
        and e.kind in ('route', 'validate_step', 'validate_end', 'repair', 'agent')
        and e.detail ~ '^\s*\{'
    ),
    u as (
      select r.user_id, r.turn_id, sum(r.input_tokens + r.output_tokens) as tokens,
             sum(public.usage_money(r.model, r.cost_usd, r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens)) as money
      from public.usage_records r join t on t.id = r.turn_id and t.user_id = r.user_id
      where r.row_deleted_at is null and split_part(r.source, ':', 1) <> 'jev'
      group by r.user_id, r.turn_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'at', t.at,
      'turn_id', t.id,
      'chat_id', t.chat_id,
      'user_id', t.user_id,
      'member', coalesce(pr.display_name, us.email),
      'project', p.name,
      'status', t.status,
      'gate', ec.verdict,
      'agent', (select e.d->>'provider' from e where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'route' order by e.seq desc limit 1),
      'model', (select e.d->>'model' from e where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'route' order by e.seq desc limit 1),
      'mode', (select e.d->>'mode' from e where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'route' order by e.seq desc limit 1),
      'commands', coalesce((select jsonb_agg(distinct e.d->>'command') from e
                            where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'validate_step' and coalesce(e.d->>'command', '') <> ''), '[]'::jsonb),
      'tools', coalesce((select jsonb_agg(distinct btrim(split_part(e.d->>'line', ':', 2))) from e
                         where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'agent' and position(':' in coalesce(e.d->>'line', '')) > 0
                           and btrim(split_part(e.d->>'line', ':', 2)) <> ''), '[]'::jsonb),
      'validation', (select e.d->>'verdict' from e where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'validate_end' order by e.seq desc limit 1),
      'repairs', coalesce((select max((e.d->>'attempt')::int) from e where e.turn_id = t.id and e.user_id = t.user_id and e.kind = 'repair' and e.d->>'attempt' ~ '^\d+$'), 0),
      'tokens', coalesce(u.tokens, 0),
      'cost_usd', u.money
    ) order by t.at desc), '[]'::jsonb)
    from t
    left join public.chats c on c.id = t.chat_id and c.user_id = t.user_id
    left join public.projects p on p.id = c.project_id and p.user_id = t.user_id
    left join public.entry_checks ec on ec.turn_id = t.id and ec.user_id = t.user_id and ec.row_deleted_at is null
    left join public.profiles pr on pr.user_id = t.user_id
    left join auth.users us on us.id = t.user_id
    left join u on u.turn_id = t.id and u.user_id = t.user_id
  );
end;
$$;
revoke all on function public.org_audit(uuid, date, date) from public, anon;
grant execute on function public.org_audit(uuid, date, date) to authenticated;

-- 2. O plano de cada membro ---------------------------------------------------

-- Para a tela "o que esta pessoa pode fazer, e por quê": o plano de cada
-- membro (a assinatura ativa ou o plano padrão), os recursos que ele traz e
-- os que o admin do sistema desligou para todos. Só owner e maintainer; o
-- membro vê o dele pelo `my_features()`.
create function public.org_member_plans(org uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  return (
    with m as (
      select om.user_id, om.role,
             coalesce((select s.plan_key from public.subscriptions s join public.plans p on p.key = s.plan_key
                       where s.user_id = om.user_id and s.status in ('active', 'trialing', 'past_due') limit 1),
                      (select p.key from public.plans p where p.is_default)) as plan_key,
             exists (select 1 from public.admins a where a.user_id = om.user_id) as admin
      from public.organization_members om where om.org_id = org
    )
    select jsonb_build_object(
      'off', coalesce((select jsonb_agg(f.key order by f.position, f.key) from public.features f where not f.enabled), '[]'::jsonb),
      'members', coalesce(jsonb_agg(jsonb_build_object(
        'user_id', m.user_id,
        'role', m.role,
        'admin', m.admin,
        'plan', m.plan_key,
        'plan_name', p.name,
        'features', coalesce((select jsonb_agg(pf.feature_key order by f.position, f.key) from public.plan_features pf join public.features f on f.key = pf.feature_key
                              where pf.plan_key = m.plan_key), '[]'::jsonb),
        'jev_daily_requests', p.jev_daily_requests
      )), '[]'::jsonb)
    )
    from m left join public.plans p on p.key = m.plan_key
  );
end;
$$;
revoke all on function public.org_member_plans(uuid) from public, anon;
grant execute on function public.org_member_plans(uuid) to authenticated;

-- 3. Tempo até o primeiro resultado comprovado ------------------------------

-- Uma linha por conta, só com a telemetria ligada: quantos segundos do
-- primeiro uso do app até a primeira validação que passou.
create table public.first_results (
  user_id uuid primary key references auth.users on delete cascade,
  seconds integer not null check (seconds between 0 and 2592000),
  recorded_at timestamptz not null default now()
);
alter table public.first_results enable row level security;
create policy "first_results: a conta lê a sua" on public.first_results for select to authenticated using (user_id = (select auth.uid()));

create function public.record_first_result(seconds integer) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then raise exception 'sem sessão' using errcode = '28000'; end if;
  if not exists (select 1 from public.usage_telemetry where user_id = me) then return false; end if;
  if seconds is null or seconds < 0 or seconds > 2592000 then raise exception 'telemetry.invalid'; end if;
  insert into public.first_results (user_id, seconds) values (me, record_first_result.seconds) on conflict (user_id) do nothing;
  return true;
end;
$$;
revoke all on function public.record_first_result(integer) from public, anon;
grant execute on function public.record_first_result(integer) to authenticated;

-- Desligar a telemetria apaga também o tempo enviado.
create function public.usage_telemetry_forget() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.first_results where user_id = old.user_id;
  return old;
end;
$$;
create trigger usage_telemetry_forget after delete on public.usage_telemetry for each row execute function public.usage_telemetry_forget();

-- Para o admin: quantas contas chegaram ao primeiro resultado, a mediana e
-- quantas chegaram em menos de 10 minutos (a meta do roadmap).
create function public.admin_first_results() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_require();
  return (
    select jsonb_build_object(
      'count', count(*),
      'median_seconds', percentile_cont(0.5) within group (order by seconds),
      'under_10_min', count(*) filter (where seconds < 600)
    )
    from public.first_results
  );
end;
$$;
revoke all on function public.admin_first_results() from public, anon;
grant execute on function public.admin_first_results() to authenticated;
