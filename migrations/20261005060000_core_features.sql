-- v0.60.0: recursos de núcleo, recursos travados por plano e limites do plano.
--
-- Até aqui o plano só sabia tirar um recurso: o que estava nele o usuário
-- podia desligar. Alguns recursos protegem o usuário ou o custo dele e não
-- podem ser desligados por ninguém — são de núcleo. E o admin passa a poder
-- travar ligado um recurso opcional num plano.
--
-- - `features.core`: recurso de núcleo. Está em todo plano, travado, e o admin
--   não o desliga (`admin.error.coreFeature`).
-- - `plan_features.mode`: `optional` (o usuário liga e desliga) ou `locked`
--   (ligado, sem interruptor). `default_on` é o valor de partida do opcional.
-- - `plans.jev_daily_limit` e `plans.max_concurrent_turns`: os limites do plano.
-- - `my_features()` ganha `locked`, `defaults` e `limits`; `features` continua
--   com o mesmo formato, agora sempre com os de núcleo — o app antigo segue
--   lendo como antes.
--
-- Os recursos novos entram em todo plano que já existe, para ninguém perder no
-- dia da migração o que já usava; o admin os tira dos planos que quiser.

-- 1. O catálogo novo.
alter table public.features add column core boolean not null default false;

insert into public.features (key, position, core) values
  ('entryGate', 1, true),
  ('exitGate', 2, true),
  ('secretRedaction', 3, true),
  ('sensitiveFiles', 4, true),
  ('agentSessions', 5, true),
  ('contextCache', 6, true),
  ('answerRecall', 65, false),
  ('leanCode', 75, false),
  ('symbolIndex', 115, false)
on conflict (key) do update set core = excluded.core;
update public.features set core = true where key = 'adaptiveRouting';
-- Recurso de núcleo nunca fica desligado, nem pelo SQL Editor.
update public.features set enabled = true where core;
alter table public.features add constraint features_core_enabled check (enabled or not core);

-- 2. Como o recurso entra no plano.
alter table public.plan_features
  add column mode text not null default 'optional' check (mode in ('optional', 'locked')),
  add column default_on boolean not null default true;

-- 3. Os limites do plano. Sem limite do Jev, vale o da função (`JEV_DAILY_LIMIT`).
alter table public.plans
  add column jev_daily_limit integer check (jev_daily_limit is null or jev_daily_limit > 0),
  add column max_concurrent_turns integer not null default 1 check (max_concurrent_turns between 1 and 8);

-- 4. Os planos que já existem: núcleo travado; os opcionais novos, como o
-- usuário tem hoje (o índice de símbolos vem desligado, como na tela).
insert into public.plan_features (plan_key, feature_key, mode, default_on)
select p.key, f.key, 'locked', true from public.plans p cross join public.features f where f.core
on conflict (plan_key, feature_key) do update set mode = 'locked', default_on = true;
insert into public.plan_features (plan_key, feature_key, mode, default_on)
select p.key, f.key, 'optional', f.key <> 'symbolIndex' from public.plans p cross join public.features f
where f.key in ('answerRecall', 'leanCode', 'symbolIndex')
on conflict (plan_key, feature_key) do nothing;

-- 5. Plano novo nasce com o núcleo travado, venha de onde vier.
create function public.plan_core_features() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select new.key, f.key, 'locked', true from public.features f where f.core
  on conflict (plan_key, feature_key) do update set mode = 'locked', default_on = true;
  return new;
end;
$$;
create trigger plans_core_features after insert on public.plans for each row execute function public.plan_core_features();

-- 6. O admin não desliga recurso de núcleo.
create or replace function public.admin_set_feature(feature text, on_off boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_require();
  if not on_off and exists (select 1 from public.features where key = feature and core) then
    raise exception 'admin.error.coreFeature';
  end if;
  update public.features set enabled = on_off, updated_by = auth.uid(), updated_at = now() where key = feature;
  if not found then raise exception 'admin.error.unknownFeature'; end if;
end;
$$;

-- 7. Cria ou troca um plano inteiro. `plan.features` aceita a lista de chaves
-- de antes (tudo opcional, ligado) ou objetos `{key, mode, default_on}`. Os
-- recursos de núcleo entram sempre, travados, mesmo que não venham na lista.
-- `jev_daily_limit` vazio é "sem limite próprio"; `max_concurrent_turns` vazio
-- é 1.
create or replace function public.admin_save_plan(plan jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  chosen text := plan->>'key';
  item jsonb;
  wanted text[] := '{}';
  modes text[] := '{}';
  defaults boolean[] := '{}';
  mode text;
begin
  perform public.admin_require();
  if jsonb_typeof(plan) is distinct from 'object' or jsonb_typeof(plan->'features') is distinct from 'array' then
    raise exception 'admin.error.planInvalid';
  end if;
  for item in select value from jsonb_array_elements(plan->'features') loop
    if jsonb_typeof(item) = 'string' then
      if not ((item #>> '{}') = any (wanted)) then
        wanted := wanted || (item #>> '{}'); modes := modes || 'optional'::text; defaults := defaults || true;
      end if;
    elsif jsonb_typeof(item) = 'object' and jsonb_typeof(item->'key') = 'string' then
      mode := coalesce(item->>'mode', 'optional');
      if mode not in ('optional', 'locked') or (item ? 'default_on' and jsonb_typeof(item->'default_on') <> 'boolean') then
        raise exception 'admin.error.planInvalid';
      end if;
      if not ((item->>'key') = any (wanted)) then
        wanted := wanted || (item->>'key'); modes := modes || mode; defaults := defaults || coalesce((item->>'default_on')::boolean, true);
      end if;
    else
      raise exception 'admin.error.planInvalid';
    end if;
  end loop;
  if exists (select 1 from unnest(wanted) k where not exists (select 1 from public.features f where f.key = k)) then
    raise exception 'admin.error.unknownFeature';
  end if;
  begin
    -- Um padrão novo tira o posto do antigo antes de a linha nova entrar.
    if coalesce((plan->>'is_default')::boolean, false) then
      update public.plans set is_default = false where is_default and key <> chosen;
    end if;
    insert into public.plans (key, name, description, position, active, is_default, stripe_price_id, price_cents, currency, billing_interval, jev_daily_limit, max_concurrent_turns, updated_by, updated_at)
    values (
      chosen, btrim(plan->>'name'), coalesce(plan->>'description', ''), coalesce((plan->>'position')::integer, 0),
      coalesce((plan->>'active')::boolean, true), coalesce((plan->>'is_default')::boolean, false),
      nullif(btrim(plan->>'stripe_price_id'), ''), (plan->>'price_cents')::integer, nullif(lower(btrim(plan->>'currency')), ''),
      nullif(plan->>'billing_interval', ''), nullif(plan->>'jev_daily_limit', '')::integer,
      coalesce(nullif(plan->>'max_concurrent_turns', '')::integer, 1), auth.uid(), now()
    )
    on conflict (key) do update set
      name = excluded.name, description = excluded.description, position = excluded.position, active = excluded.active,
      is_default = excluded.is_default, stripe_price_id = excluded.stripe_price_id, price_cents = excluded.price_cents,
      currency = excluded.currency, billing_interval = excluded.billing_interval, jev_daily_limit = excluded.jev_daily_limit,
      max_concurrent_turns = excluded.max_concurrent_turns, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  exception
    when check_violation or not_null_violation or invalid_text_representation then raise exception 'admin.error.planInvalid';
    when unique_violation then raise exception 'admin.error.priceTaken';
  end;
  if not exists (select 1 from public.plans where is_default) then raise exception 'admin.error.default'; end if;
  delete from public.plan_features pf
  where pf.plan_key = chosen and not (pf.feature_key = any (wanted))
    and not exists (select 1 from public.features f where f.key = pf.feature_key and f.core);
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select chosen, w.k, w.m, w.d from unnest(wanted, modes, defaults) as w(k, m, d)
  on conflict (plan_key, feature_key) do update set mode = excluded.mode, default_on = excluded.default_on;
  -- O núcleo é travado, diga a lista o que disser.
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select chosen, f.key, 'locked', true from public.features f where f.core
  on conflict (plan_key, feature_key) do update set mode = 'locked', default_on = true;
end;
$$;

-- 8. O que vale para quem chama. `features` sempre traz o núcleo; `locked` é
-- o que não se desliga; `defaults` o valor de partida dos opcionais; `limits`
-- os números do plano.
create or replace function public.my_features() returns jsonb language sql stable security definer set search_path = '' as $$
  with mine as (select public.my_plan() as plan_key),
  included as (
    select f.key, f.position, f.core, pf.mode, pf.default_on
    from public.features f
    left join public.plan_features pf on pf.feature_key = f.key and pf.plan_key = (select plan_key from mine)
    where f.core or (f.enabled and pf.feature_key is not null)
  )
  select jsonb_build_object(
    'plan', (select plan_key from mine),
    'admin', coalesce(public.is_admin(), false),
    'features', coalesce((select jsonb_agg(key order by position, key) from included), '[]'::jsonb),
    'locked', coalesce((select jsonb_agg(key order by position, key) from included where core or mode = 'locked'), '[]'::jsonb),
    'defaults', coalesce((select jsonb_object_agg(key, coalesce(default_on, true)) from included where not core and mode is distinct from 'locked'), '{}'::jsonb),
    'limits', (select jsonb_build_object('jevDailyLimit', p.jev_daily_limit, 'maxConcurrentTurns', p.max_concurrent_turns)
               from public.plans p where p.key = (select plan_key from mine))
  );
$$;

-- 9. O limite do Jev do plano de quem chama, para a função `jev`. Nulo: o da
-- função.
create function public.my_jev_daily_limit() returns integer language sql stable security definer set search_path = '' as $$
  select p.jev_daily_limit from public.plans p where p.key = public.my_plan();
$$;
revoke execute on function public.my_jev_daily_limit() from public, anon;
grant execute on function public.my_jev_daily_limit() to authenticated;
