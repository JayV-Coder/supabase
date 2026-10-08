-- Ambientes: o pessoal e um por organização. Um ambiente é só um texto em
-- `environment_id` nas linhas do dono — `personal` ou o id da organização —,
-- então a RLS não muda: toda linha continua sendo do `user_id`. O app abre um
-- banco local por ambiente e sincroniza só as linhas dele.
--
-- O ambiente de um projeto é o do `org_id` dele ou, sem ele, o do banco de
-- onde o app o mandou; as linhas que dependem do projeto (chats, turnos,
-- mensagens, verificações, perguntas, uso, notas) seguem o projeto, decidido
-- aqui no banco: um app antigo, que não manda o ambiente, não tem como
-- misturá-los. Configurações (agentes, modelos e a
-- conta) não têm projeto: o que o cliente manda vale, e sem nada vale
-- `personal`. A cota (`quota_snapshots`) é da conta do provedor, igual em todo
-- ambiente, e fica de fora.

create function public.environment_valid(env text) returns boolean language sql immutable set search_path = '' as $$
  select env = 'personal'
      or env ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
$$;

do $$
declare
  name text;
begin
  foreach name in array array[
    'projects', 'chats', 'turns', 'messages', 'entry_checks', 'exit_checks', 'turn_events', 'questions',
    'usage_records', 'jev_records', 'project_notes', 'llm_agents', 'llm_models', 'account_settings'
  ] loop
    execute format(
      'alter table public.%I add column environment_id text not null default ''personal'' check (public.environment_valid(environment_id))',
      name);
    execute format(
      'create index %I on public.%I (user_id, environment_id, synced_at)',
      name || '_user_env_synced', name);
  end loop;
end
$$;

-- O ambiente que o projeto diz, ou `personal`.
create function public.environment_of_org(org uuid) returns text language sql immutable set search_path = '' as $$
  select coalesce(org::text, 'personal');
$$;

-- Quem decide o ambiente de cada linha que depende de um projeto. O pai tem
-- de ser do mesmo dono: o id de outro usuário não revela nada.
create function public.environment_stamp() returns trigger language plpgsql set search_path = '' as $$
declare
  env text;
begin
  case tg_table_name
    when 'projects' then
      -- O projeto de uma organização (`org_id`) é sempre do ambiente dela; os
      -- outros ficam no ambiente do banco de onde o app os mandou. Ambiente de
      -- organização só vale para quem é membro.
      env := coalesce(new.org_id::text, new.environment_id);
      if env <> 'personal' and not exists (
        select 1 from public.organization_members m where m.org_id::text = env and m.user_id = new.user_id
      ) then
        -- Dizer o `org_id` sem ser membro nunca deu vínculo (ver
        -- `project_organization`): o projeto fica no pessoal. Pedir o ambiente
        -- da organização sem ser membro é recusado.
        if new.org_id is not null then env := 'personal'; else raise exception 'environment.forbidden' using errcode = '42501'; end if;
      end if;
    when 'chats', 'project_notes' then
      select p.environment_id into env from public.projects p where p.id = new.project_id and p.user_id = new.user_id;
    when 'usage_records', 'jev_records' then
      select p.environment_id into env from public.projects p where p.id = new.project_id and p.user_id = new.user_id;
    when 'turns', 'messages' then
      select c.environment_id into env from public.chats c where c.id = new.chat_id and c.user_id = new.user_id;
    else
      -- entry_checks, exit_checks, turn_events, questions
      select t.environment_id into env from public.turns t where t.id = new.turn_id and t.user_id = new.user_id;
  end case;
  if env is not null then new.environment_id := env; end if;
  return new;
end
$$;

do $$
declare
  name text;
begin
  foreach name in array array[
    'projects', 'chats', 'turns', 'messages', 'entry_checks', 'exit_checks', 'turn_events', 'questions',
    'usage_records', 'jev_records', 'project_notes'
  ] loop
    execute format(
      'create trigger a_environment_stamp before insert or update on public.%I for each row execute function public.environment_stamp()',
      name);
  end loop;
end
$$;

-- Um projeto que muda de organização leva tudo que depende dele.
create function public.environment_follow() returns trigger language plpgsql set search_path = '' as $$
begin
  update public.chats set environment_id = new.environment_id where project_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.project_notes set environment_id = new.environment_id where project_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.usage_records set environment_id = new.environment_id where project_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.jev_records set environment_id = new.environment_id where project_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  return null;
end
$$;
create trigger environment_follow after update on public.projects
  for each row when (old.environment_id is distinct from new.environment_id) execute function public.environment_follow();

create function public.environment_follow_chat() returns trigger language plpgsql set search_path = '' as $$
begin
  update public.turns set environment_id = new.environment_id where chat_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.messages set environment_id = new.environment_id where chat_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  return null;
end
$$;
create trigger environment_follow after update on public.chats
  for each row when (old.environment_id is distinct from new.environment_id) execute function public.environment_follow_chat();

create function public.environment_follow_turn() returns trigger language plpgsql set search_path = '' as $$
begin
  update public.entry_checks set environment_id = new.environment_id where turn_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.exit_checks set environment_id = new.environment_id where turn_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.turn_events set environment_id = new.environment_id where turn_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  update public.questions set environment_id = new.environment_id where turn_id = new.id and user_id = new.user_id and environment_id is distinct from new.environment_id;
  return null;
end
$$;
create trigger environment_follow after update on public.turns
  for each row when (old.environment_id is distinct from new.environment_id) execute function public.environment_follow_turn();

-- O que existe hoje. O projeto que diz a organização em `org_id` vai para ela,
-- e o que só casa com um repositório dela por `repo_keys` também, como a lista
-- de Projetos já o mostrava; o resto fica no pessoal. Roda como dono do banco,
-- sem `auth.uid()`, então repete a regra de `project_organization` com o
-- dono do projeto no lugar dele.
update public.projects p
set environment_id = public.environment_of_org(
  coalesce(
    (select p.org_id from public.organization_members m where m.org_id = p.org_id and m.user_id = p.user_id),
    (
      select r.org_id
      from jsonb_array_elements_text(case when p.repo_keys ~ '^\s*\[' then p.repo_keys::jsonb else '[]'::jsonb end) with ordinality as k(repo_key, position)
      join public.organization_repositories r on r.repo_key = k.repo_key
      join public.organization_members m on m.org_id = r.org_id and m.user_id = p.user_id
      order by k.position, r.created_at
      limit 1
    )
  ))
where p.row_deleted_at is null;

-- `environment_follow` roda sozinho a cada linha acima e leva chats, notas e
-- uso; os turnos e mensagens vêm do gatilho dos chats, e as verificações do
-- gatilho dos turnos.

-- Os ambientes de quem chama: o pessoal e um por organização de que é membro.
create function public.my_environments() returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(row order by position, name), '[]'::jsonb)
  from (
    select 0 as position, '' as name,
           jsonb_build_object('id', 'personal', 'kind', 'personal', 'name', null, 'slug', null, 'role', null) as row
    where auth.uid() is not null
    union all
    select 1, o.name,
           jsonb_build_object('id', o.id::text, 'kind', 'organization', 'name', o.name, 'slug', o.slug, 'role', m.role)
    from public.organization_members m
    join public.organizations o on o.id = m.org_id
    where m.user_id = auth.uid()
  ) environments;
$$;
revoke execute on function public.my_environments() from public, anon;
grant execute on function public.my_environments() to authenticated;

-- As configurações são de cada ambiente: a chave inclui o ambiente, e o mesmo
-- agente, modelo ou ajuste pode existir no pessoal e em cada organização. O
-- app novo manda `environment_id` e usa o alvo do upsert com ele; o app
-- antigo (alvo `user_id,id`) deixa de gravar estas três tabelas até
-- atualizar, o que o app faz sozinho ao abrir.
alter table public.llm_models drop constraint llm_models_user_id_agent_fkey;
alter table public.llm_agents drop constraint llm_agents_pkey, add primary key (user_id, environment_id, id);
alter table public.llm_models drop constraint llm_models_pkey, add primary key (user_id, environment_id, agent, model);
alter table public.llm_models add foreign key (user_id, environment_id, agent) references public.llm_agents (user_id, environment_id, id) on delete cascade;
alter table public.account_settings drop constraint account_settings_pkey, add primary key (user_id, environment_id, key);

-- A conta de um usuário mostra o nível do ambiente pessoal.
-- e o que os admins já fizeram com ela.
create or replace function public.admin_user(target uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  since text := to_char(now() - interval '30 days', 'YYYY-MM-DD');
begin
  perform public.admin_target(target);
  return (
    select jsonb_build_object(
      'user_id', u.id,
      'email', u.email,
      'created_at', u.created_at,
      'last_sign_in_at', u.last_sign_in_at,
      'email_confirmed_at', u.email_confirmed_at,
      'banned_until', u.banned_until,
      'has_password', coalesce(u.encrypted_password, '') <> '',
      'has_mfa', exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'),
      'is_admin', exists (select 1 from public.admins a where a.user_id = u.id),
      'sessions', (select count(*) from auth.sessions s where s.user_id = u.id),
      'last_provider', coalesce(u.raw_app_meta_data->>'provider', 'email'),
      'expertise', (select a.value from public.account_settings a where a.user_id = u.id and a.key = 'expertise_level' and a.environment_id = 'personal' and a.row_deleted_at is null),
      'providers', coalesce((select jsonb_agg(jsonb_build_object('provider', i.provider, 'email', i.email, 'created_at', i.created_at) order by i.provider)
        from auth.identities i where i.user_id = u.id), '[]'::jsonb),
      'profile', (select to_jsonb(p) - 'user_id' from public.profiles p where p.user_id = u.id),
      'plan_key', public.plan_of(u.id),
      'subscription', (select jsonb_build_object('plan_key', s.plan_key, 'status', s.status, 'current_period_end', s.current_period_end,
          'cancel_at_period_end', s.cancel_at_period_end, 'stripe_subscription_id', s.stripe_subscription_id, 'updated_at', s.updated_at)
        from public.subscriptions s where s.user_id = u.id),
      'stripe_customer_id', (select b.stripe_customer_id from public.billing_customers b where b.user_id = u.id),
      'organizations', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug, 'role', m.role,
          'members', (select count(*) from public.organization_members x where x.org_id = o.id)) order by o.name)
        from public.organization_members m join public.organizations o on o.id = m.org_id where m.user_id = u.id), '[]'::jsonb),
      'usage', jsonb_build_object(
        'projects', (select count(*) from public.projects pr where pr.user_id = u.id and pr.row_deleted_at is null),
        'chats', (select count(*) from public.chats c where c.user_id = u.id and c.row_deleted_at is null),
        'calls_30d', (select count(*) from public.usage_records r where r.user_id = u.id and r.row_deleted_at is null and r.created_at >= since),
        'tokens_30d', (select coalesce(sum(r.input_tokens + r.output_tokens), 0) from public.usage_records r where r.user_id = u.id and r.row_deleted_at is null and r.created_at >= since),
        'cost_30d', (select coalesce(sum(r.cost_usd), 0) from public.usage_records r where r.user_id = u.id and r.row_deleted_at is null and r.created_at >= since),
        'cost_total', (select coalesce(sum(r.cost_usd), 0) from public.usage_records r where r.user_id = u.id and r.row_deleted_at is null)
      ),
      'audit', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'detail', a.detail, 'created_at', a.created_at,
          'admin', coalesce((select p.username from public.profiles p where p.user_id = a.admin_id), '')) order by a.created_at desc)
        from (select * from public.admin_audit x where x.target_id = u.id order by x.created_at desc limit 50) a), '[]'::jsonb)
    )
    from auth.users u where u.id = target
  );
end;
$$;
revoke execute on function public.admin_user(uuid) from public, anon;
grant execute on function public.admin_user(uuid) to authenticated;
