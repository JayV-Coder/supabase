-- Política de LLM: o que a organização diz sobre os agentes e modelos dos
-- projetos dela, e o que nunca sai da máquina. Uma política vale para a
-- organização inteira (`repository_id` nulo) e outra, opcional, para cada
-- repositório; o projeto roda sob a junção das duas, pela mais rígida. A
-- política só aperta: o app a aplica por cima das configurações de quem usa.
--
-- Leitura por RLS (membro lê); escrita só pelas RPCs, que conferem o papel.

-- Até 50 padrões glob, de 1 a 200 caracteres, sem espaço nas pontas.
create function public.policy_patterns_ok(patterns text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(patterns) <= 50
    and not exists (select 1 from unnest(patterns) p where p is null or char_length(p) not between 1 and 200 or p <> btrim(p));
$$;

-- Até 100 modelos no formato `agente/modelo`, com os caracteres que o app
-- aceita num id de modelo.
create function public.policy_models_ok(models text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(models) <= 100
    and not exists (select 1 from unnest(models) m where m is null or m !~ '^(claude|codex|copilot|cursor)/[A-Za-z0-9._:/@\[\]-]{1,120}$');
$$;

create table public.organization_llm_policies (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  repository_id uuid references public.organization_repositories on delete cascade,
  agents text[] check (
    agents is null
    or (cardinality(agents) between 1 and 4 and agents <@ array['claude', 'codex', 'copilot', 'cursor'])
  ),
  blocked_models text[] not null default '{}' check (public.policy_models_ok(blocked_models)),
  deny text[] not null default '{}' check (public.policy_patterns_ok(deny)),
  local_only text[] not null default '{}' check (public.policy_patterns_ok(local_only)),
  safe_agents boolean not null default false,
  redact_secrets boolean not null default false,
  min_read text not null default 'allow' check (min_read in ('allow', 'ask', 'deny')),
  min_write text not null default 'allow' check (min_write in ('allow', 'ask', 'deny')),
  min_shell text not null default 'allow' check (min_shell in ('allow', 'ask', 'deny')),
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now()
);
create unique index organization_llm_policies_org on public.organization_llm_policies (org_id) where repository_id is null;
create unique index organization_llm_policies_repository on public.organization_llm_policies (repository_id) where repository_id is not null;

alter table public.organization_llm_policies enable row level security;
create policy "membro lê" on public.organization_llm_policies for select to authenticated
  using ((select public.org_role(org_id)) is not null);

-- A lista de um campo do JSON: aparada, sem vazio e sem repetição, na ordem em
-- que veio. Campo ausente é lista vazia; o que não for lista é inválido.
create function public.policy_list(value jsonb) returns text[] language plpgsql immutable set search_path = '' as $$
begin
  if value is null or jsonb_typeof(value) = 'null' then return '{}'; end if;
  if jsonb_typeof(value) <> 'array' then raise exception 'policy.invalid'; end if;
  return coalesce((
    select array_agg(item order by first)
    from (
      select btrim(e.item) as item, min(e.position) as first
      from jsonb_array_elements_text(value) with ordinality as e(item, position)
      where btrim(e.item) <> ''
      group by btrim(e.item)
    ) kept
  ), '{}');
end;
$$;

-- `a` seguida do que `b` tem a mais.
create function public.policy_union(a text[], b text[]) returns text[] language sql immutable set search_path = '' as $$
  select coalesce(a, '{}') || coalesce(array(select x from unnest(b) x where not (x = any (coalesce(a, '{}')))), '{}');
$$;

-- A regra de saída mais rígida: `allow` < `ask` < `deny`.
create function public.policy_strictest(a text, b text) returns text language sql immutable set search_path = '' as $$
  select (array['allow', 'ask', 'deny'])[greatest(array_position(array['allow', 'ask', 'deny'], a), array_position(array['allow', 'ask', 'deny'], b))];
$$;

-- Grava a política da organização (`repository` nulo) ou de um repositório
-- dela, trocando a que houver.
create function public.set_llm_policy(org uuid, repository uuid, policy jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  agents text[];
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if repository is not null and not exists (select 1 from public.organization_repositories where id = repository and org_id = org) then
    raise exception 'policy.repository';
  end if;
  if jsonb_typeof(policy) is distinct from 'object' then raise exception 'policy.invalid'; end if;
  if coalesce(jsonb_typeof(policy->'agents'), 'null') <> 'null' then
    -- Na ordem do app, para a mesma escolha gravar sempre igual.
    agents := array(select a from unnest(array['claude', 'codex', 'copilot', 'cursor']) a where a = any (public.policy_list(policy->'agents')));
    if cardinality(agents) <> cardinality(public.policy_list(policy->'agents')) then raise exception 'policy.invalid'; end if;
  end if;
  delete from public.organization_llm_policies p where p.org_id = org and p.repository_id is not distinct from repository;
  begin
    insert into public.organization_llm_policies
      (org_id, repository_id, agents, blocked_models, deny, local_only, safe_agents, redact_secrets, min_read, min_write, min_shell, updated_by)
    values (
      org, repository, agents,
      public.policy_list(policy->'blocked_models'), public.policy_list(policy->'deny'), public.policy_list(policy->'local_only'),
      coalesce((policy->>'safe_agents')::boolean, false), coalesce((policy->>'redact_secrets')::boolean, false),
      coalesce(policy->>'min_read', 'allow'), coalesce(policy->>'min_write', 'allow'), coalesce(policy->>'min_shell', 'allow'),
      auth.uid()
    );
  exception
    when check_violation or invalid_text_representation then raise exception 'policy.invalid';
  end;
end;
$$;

create function public.clear_llm_policy(org uuid, repository uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  delete from public.organization_llm_policies p where p.org_id = org and p.repository_id is not distinct from repository;
end;
$$;

-- A política efetiva: a da organização junto com a do repositório, pela mais
-- rígida. Nulo quando nenhuma das duas existe. Interna: não confere papel.
create function public.llm_policy_of(org uuid, repository uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  o public.organization_llm_policies;
  r public.organization_llm_policies;
begin
  select * into o from public.organization_llm_policies p where p.org_id = org and p.repository_id is null;
  if repository is not null then
    select * into r from public.organization_llm_policies p where p.org_id = org and p.repository_id = repository;
  end if;
  if o.id is null and r.id is null then return null; end if;
  return jsonb_build_object(
    -- Nulo é "todos": a interseção só corta quando as duas listam.
    'agents', case
      when o.agents is null then to_jsonb(r.agents)
      when r.agents is null then to_jsonb(o.agents)
      else to_jsonb(array(select a from unnest(o.agents) a where a = any (r.agents)))
    end,
    'blocked_models', to_jsonb(public.policy_union(o.blocked_models, r.blocked_models)),
    'deny', to_jsonb(public.policy_union(o.deny, r.deny)),
    'local_only', to_jsonb(public.policy_union(o.local_only, r.local_only)),
    'safe_agents', coalesce(o.safe_agents, false) or coalesce(r.safe_agents, false),
    'redact_secrets', coalesce(o.redact_secrets, false) or coalesce(r.redact_secrets, false),
    'min_read', public.policy_strictest(o.min_read, r.min_read),
    'min_write', public.policy_strictest(o.min_write, r.min_write),
    'min_shell', public.policy_strictest(o.min_shell, r.min_shell)
  );
end;
$$;

-- O repositório que associa o projeto à organização: a mesma regra de
-- `project_organization` (primeiro remote que casa, cadastro mais antigo).
create function public.project_repository(project text) returns uuid language sql stable security definer set search_path = '' as $$
  select r.id
  from public.projects pr
  cross join lateral jsonb_array_elements_text(
    case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
  ) with ordinality as k(repo_key, position)
  join public.organization_repositories r on r.repo_key = k.repo_key
  join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
  where pr.id = project and pr.row_deleted_at is null
    and (pr.user_id = auth.uid() or public.org_role(r.org_id) is not null)
  order by k.position, r.created_at
  limit 1;
$$;

-- Os projetos de quem chama que rodam sob uma política, com a efetiva.
create function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  select linked.project_id, linked.org_id, o.slug, linked.policy
  from (
    select pr.id as project_id, r.org_id, public.llm_policy_of(r.org_id, r.id) as policy
    from public.projects pr
    join public.organization_repositories r on r.id = public.project_repository(pr.id)
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
  ) linked
  join public.organizations o on o.id = linked.org_id
  where linked.policy is not null;
$$;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'policy_patterns_ok(text[])', 'policy_models_ok(text[])', 'policy_list(jsonb)', 'policy_union(text[], text[])',
    'policy_strictest(text, text)', 'llm_policy_of(uuid, uuid)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
  foreach fn in array array[
    'set_llm_policy(uuid, uuid, jsonb)', 'clear_llm_policy(uuid, uuid)', 'project_repository(text)', 'my_project_policies()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end;
$$;

-- A aba Política de LLM, os erros das RPCs e as orientações do chat (as de
-- antes desta etapa não tinham tradução), nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'org.tab.policy', $json$"Política de LLM"$json$::jsonb),
  ('pt-BR', 'policy.title', $json$"Política de LLM"$json$::jsonb),
  ('pt-BR', 'policy.description', $json$"O que os projetos da organização podem usar. A política só aperta: as configurações de cada pessoa continuam valendo por cima dela."$json$::jsonb),
  ('pt-BR', 'policy.scope', $json$"Vale para"$json$::jsonb),
  ('pt-BR', 'policy.scope.org', $json$"Toda a organização"$json$::jsonb),
  ('pt-BR', 'policy.scope.set', $json$"com política"$json$::jsonb),
  ('pt-BR', 'policy.scope.unset', $json$"sem política"$json$::jsonb),
  ('pt-BR', 'policy.scope.repoNote', $json$"A política do repositório vale junto com a da organização, e a regra mais rígida vence."$json$::jsonb),
  ('pt-BR', 'policy.none', $json$"Ainda não há política aqui. Os projetos seguem as configurações de cada pessoa."$json$::jsonb),
  ('pt-BR', 'policy.readOnly', $json$"Só owners e maintainers mudam a política."$json$::jsonb),
  ('pt-BR', 'policy.agents.title', $json$"Agentes e modelos"$json$::jsonb),
  ('pt-BR', 'policy.agents.all', $json$"Todos os agentes"$json$::jsonb),
  ('pt-BR', 'policy.agents.all.hint', $json$"Desligue para escolher quais agentes os projetos podem rodar."$json$::jsonb),
  ('pt-BR', 'policy.agents.invalid', $json$"Escolha pelo menos um agente."$json$::jsonb),
  ('pt-BR', 'policy.models', $json$"Modelos bloqueados"$json$::jsonb),
  ('pt-BR', 'policy.models.hint', $json$"Um por linha, como agente/modelo (claude/opus)."$json$::jsonb),
  ('pt-BR', 'policy.models.invalid', $json$"Use agente/modelo, com o agente entre claude, codex, copilot e cursor."$json$::jsonb),
  ('pt-BR', 'policy.safe', $json$"Desligar os modos sem trava"$json$::jsonb),
  ('pt-BR', 'policy.safe.hint', $json$"Nada de bypassPermissions no Claude Code, danger-full-access no Codex, todas as ferramentas no Copilot nem --force no Cursor."$json$::jsonb),
  ('pt-BR', 'policy.privacy.title', $json$"Privacidade"$json$::jsonb),
  ('pt-BR', 'policy.privacy.description', $json$"Somados aos padrões de cada pessoa. Um padrão glob por linha."$json$::jsonb),
  ('pt-BR', 'policy.redact.hint', $json$"Liga a remoção de segredos para todos; desligado, cada pessoa decide."$json$::jsonb),
  ('pt-BR', 'policy.patterns.invalid', $json$"Até 50 padrões de até 200 caracteres."$json$::jsonb),
  ('pt-BR', 'policy.exit.title', $json$"Portaria de saída"$json$::jsonb),
  ('pt-BR', 'policy.exit.description', $json$"O mínimo de cada regra: a escolha mais rígida de cada pessoa continua valendo."$json$::jsonb),
  ('pt-BR', 'policy.save', $json$"Salvar política"$json$::jsonb),
  ('pt-BR', 'policy.saved', $json$"Política salva."$json$::jsonb),
  ('pt-BR', 'policy.clear', $json$"Remover política"$json$::jsonb),
  ('pt-BR', 'policy.clear.title', $json$"Remover esta política?"$json$::jsonb),
  ('pt-BR', 'policy.clear.description', $json$"Os projetos deixam de segui-la na próxima sincronização de cada pessoa."$json$::jsonb),
  ('pt-BR', 'policy.cleared', $json$"Política removida."$json$::jsonb),
  ('pt-BR', 'policy.badge', $json$"Política de LLM"$json$::jsonb),
  ('pt-BR', 'policy.badge.hint', $json$"Os pedidos deste projeto seguem a política de LLM de @{slug}."$json$::jsonb),
  ('pt-BR', 'policy.invalid', $json$"A política tem um valor que o servidor recusou."$json$::jsonb),
  ('pt-BR', 'policy.repository', $json$"Esse repositório é de outra organização."$json$::jsonb),
  ('pt-BR', 'guidance.failed', $json$"O pedido não rodou porque {problem}."$json$::jsonb),
  ('pt-BR', 'guidance.fix', $json$"Abra Configurações, ligue um agente e deixe pelo menos um modelo dele ativo."$json$::jsonb),
  ('pt-BR', 'guidance.nothingConfigured', $json$"não há agente nem modelo configurado"$json$::jsonb),
  ('pt-BR', 'guidance.noModels', $json$"há agentes, mas nenhum modelo configurado"$json$::jsonb),
  ('pt-BR', 'guidance.noAgent', $json$"nenhum agente está ligado"$json$::jsonb),
  ('pt-BR', 'guidance.noFittingModel', $json$"nenhum modelo configurado serve para este pedido"$json$::jsonb),
  ('pt-BR', 'guidance.unknownProvider', $json$"o modelo escolhido aponta para o agente `{provider}`, que não existe"$json$::jsonb),
  ('pt-BR', 'guidance.policyBlocked', $json$"a política de LLM de @{org} não deixa nenhum agente ou modelo permitido para ele"$json$::jsonb),
  ('pt-BR', 'guidance.policyFix', $json$"Ligue, em Configurações, um agente e um modelo que @{org} permite, ou peça a um owner ou maintainer da organização para permitir os que você usa."$json$::jsonb),
  ('en', 'org.tab.policy', $json$"LLM policy"$json$::jsonb),
  ('en', 'policy.title', $json$"LLM policy"$json$::jsonb),
  ('en', 'policy.description', $json$"What the organization's projects may use. It only tightens: each person's own settings still apply on top of it."$json$::jsonb),
  ('en', 'policy.scope', $json$"Applies to"$json$::jsonb),
  ('en', 'policy.scope.org', $json$"The whole organization"$json$::jsonb),
  ('en', 'policy.scope.set', $json$"has a policy"$json$::jsonb),
  ('en', 'policy.scope.unset', $json$"no policy"$json$::jsonb),
  ('en', 'policy.scope.repoNote', $json$"A repository policy applies together with the organization's, and the stricter rule wins."$json$::jsonb),
  ('en', 'policy.none', $json$"No policy here yet. Projects follow each person's settings."$json$::jsonb),
  ('en', 'policy.readOnly', $json$"Only owners and maintainers change the policy."$json$::jsonb),
  ('en', 'policy.agents.title', $json$"Agents and models"$json$::jsonb),
  ('en', 'policy.agents.all', $json$"Every agent"$json$::jsonb),
  ('en', 'policy.agents.all.hint', $json$"Turn off to pick which agents the projects may run."$json$::jsonb),
  ('en', 'policy.agents.invalid', $json$"Pick at least one agent."$json$::jsonb),
  ('en', 'policy.models', $json$"Blocked models"$json$::jsonb),
  ('en', 'policy.models.hint', $json$"One per line, as agent/model (claude/opus)."$json$::jsonb),
  ('en', 'policy.models.invalid', $json$"Use agent/model, with the agent among claude, codex, copilot and cursor."$json$::jsonb),
  ('en', 'policy.safe', $json$"Turn off the unguarded modes"$json$::jsonb),
  ('en', 'policy.safe.hint', $json$"No bypassPermissions in Claude Code, no danger-full-access in Codex, no all-tools access in Copilot and no --force in Cursor."$json$::jsonb),
  ('en', 'policy.privacy.title', $json$"Privacy"$json$::jsonb),
  ('en', 'policy.privacy.description', $json$"Added to each person's own patterns. One glob pattern per line."$json$::jsonb),
  ('en', 'policy.redact.hint', $json$"Turns secret redaction on for everyone; when off, each person decides."$json$::jsonb),
  ('en', 'policy.patterns.invalid', $json$"Up to 50 patterns of up to 200 characters."$json$::jsonb),
  ('en', 'policy.exit.title', $json$"Exit gate"$json$::jsonb),
  ('en', 'policy.exit.description', $json$"The minimum for each rule: a person's stricter choice still wins."$json$::jsonb),
  ('en', 'policy.save', $json$"Save policy"$json$::jsonb),
  ('en', 'policy.saved', $json$"Policy saved."$json$::jsonb),
  ('en', 'policy.clear', $json$"Remove policy"$json$::jsonb),
  ('en', 'policy.clear.title', $json$"Remove this policy?"$json$::jsonb),
  ('en', 'policy.clear.description', $json$"Projects stop following it at each person's next sync."$json$::jsonb),
  ('en', 'policy.cleared', $json$"Policy removed."$json$::jsonb),
  ('en', 'policy.badge', $json$"LLM policy"$json$::jsonb),
  ('en', 'policy.badge.hint', $json$"Requests in this project follow the LLM policy of @{slug}."$json$::jsonb),
  ('en', 'policy.invalid', $json$"The policy has a value the server refused."$json$::jsonb),
  ('en', 'policy.repository', $json$"That repository belongs to another organization."$json$::jsonb),
  ('en', 'guidance.failed', $json$"The request could not run because {problem}."$json$::jsonb),
  ('en', 'guidance.fix', $json$"Open Settings, turn an agent on and keep at least one of its models active."$json$::jsonb),
  ('en', 'guidance.nothingConfigured', $json$"no LLM provider or model is configured"$json$::jsonb),
  ('en', 'guidance.noModels', $json$"providers are declared but no model is configured"$json$::jsonb),
  ('en', 'guidance.noAgent', $json$"no agent is on"$json$::jsonb),
  ('en', 'guidance.noFittingModel', $json$"no configured model fits this request"$json$::jsonb),
  ('en', 'guidance.unknownProvider', $json$"the selected model points to the provider `{provider}`, which does not exist"$json$::jsonb),
  ('en', 'guidance.policyBlocked', $json$"the LLM policy of @{org} leaves no allowed agent or model for it"$json$::jsonb),
  ('en', 'guidance.policyFix', $json$"Turn on, in Settings, an agent and a model that @{org} allows, or ask one of its owners or maintainers to allow the ones you use."$json$::jsonb),
  ('es', 'org.tab.policy', $json$"Política de LLM"$json$::jsonb),
  ('es', 'policy.title', $json$"Política de LLM"$json$::jsonb),
  ('es', 'policy.description', $json$"Lo que pueden usar los proyectos de la organización. La política solo restringe: la configuración de cada persona sigue aplicándose encima."$json$::jsonb),
  ('es', 'policy.scope', $json$"Se aplica a"$json$::jsonb),
  ('es', 'policy.scope.org', $json$"Toda la organización"$json$::jsonb),
  ('es', 'policy.scope.set', $json$"con política"$json$::jsonb),
  ('es', 'policy.scope.unset', $json$"sin política"$json$::jsonb),
  ('es', 'policy.scope.repoNote', $json$"La política del repositorio se aplica junto con la de la organización, y gana la regla más estricta."$json$::jsonb),
  ('es', 'policy.none', $json$"Todavía no hay política aquí. Los proyectos siguen la configuración de cada persona."$json$::jsonb),
  ('es', 'policy.readOnly', $json$"Solo los owners y maintainers cambian la política."$json$::jsonb),
  ('es', 'policy.agents.title', $json$"Agentes y modelos"$json$::jsonb),
  ('es', 'policy.agents.all', $json$"Todos los agentes"$json$::jsonb),
  ('es', 'policy.agents.all.hint', $json$"Desactívalo para elegir qué agentes pueden ejecutar los proyectos."$json$::jsonb),
  ('es', 'policy.agents.invalid', $json$"Elige al menos un agente."$json$::jsonb),
  ('es', 'policy.models', $json$"Modelos bloqueados"$json$::jsonb),
  ('es', 'policy.models.hint', $json$"Uno por línea, como agente/modelo (claude/opus)."$json$::jsonb),
  ('es', 'policy.models.invalid', $json$"Usa agente/modelo, con el agente entre claude, codex, copilot y cursor."$json$::jsonb),
  ('es', 'policy.safe', $json$"Desactivar los modos sin protección"$json$::jsonb),
  ('es', 'policy.safe.hint', $json$"Nada de bypassPermissions en Claude Code, danger-full-access en Codex, todas las herramientas en Copilot ni --force en Cursor."$json$::jsonb),
  ('es', 'policy.privacy.title', $json$"Privacidad"$json$::jsonb),
  ('es', 'policy.privacy.description', $json$"Se suman a los patrones de cada persona. Un patrón glob por línea."$json$::jsonb),
  ('es', 'policy.redact.hint', $json$"Activa la eliminación de secretos para todos; desactivado, decide cada persona."$json$::jsonb),
  ('es', 'policy.patterns.invalid', $json$"Hasta 50 patrones de hasta 200 caracteres."$json$::jsonb),
  ('es', 'policy.exit.title', $json$"Portería de salida"$json$::jsonb),
  ('es', 'policy.exit.description', $json$"El mínimo de cada regla: la elección más estricta de cada persona sigue valiendo."$json$::jsonb),
  ('es', 'policy.save', $json$"Guardar política"$json$::jsonb),
  ('es', 'policy.saved', $json$"Política guardada."$json$::jsonb),
  ('es', 'policy.clear', $json$"Quitar política"$json$::jsonb),
  ('es', 'policy.clear.title', $json$"¿Quitar esta política?"$json$::jsonb),
  ('es', 'policy.clear.description', $json$"Los proyectos dejan de seguirla en la próxima sincronización de cada persona."$json$::jsonb),
  ('es', 'policy.cleared', $json$"Política quitada."$json$::jsonb),
  ('es', 'policy.badge', $json$"Política de LLM"$json$::jsonb),
  ('es', 'policy.badge.hint', $json$"Las solicitudes de este proyecto siguen la política de LLM de @{slug}."$json$::jsonb),
  ('es', 'policy.invalid', $json$"La política tiene un valor que el servidor rechazó."$json$::jsonb),
  ('es', 'policy.repository', $json$"Ese repositorio pertenece a otra organización."$json$::jsonb),
  ('es', 'guidance.failed', $json$"La solicitud no se ejecutó porque {problem}."$json$::jsonb),
  ('es', 'guidance.fix', $json$"Abre Configuración, activa un agente y deja al menos uno de sus modelos activo."$json$::jsonb),
  ('es', 'guidance.nothingConfigured', $json$"no hay agente ni modelo configurado"$json$::jsonb),
  ('es', 'guidance.noModels', $json$"hay agentes, pero ningún modelo configurado"$json$::jsonb),
  ('es', 'guidance.noAgent', $json$"ningún agente está activado"$json$::jsonb),
  ('es', 'guidance.noFittingModel', $json$"ningún modelo configurado sirve para esta solicitud"$json$::jsonb),
  ('es', 'guidance.unknownProvider', $json$"el modelo elegido apunta al agente `{provider}`, que no existe"$json$::jsonb),
  ('es', 'guidance.policyBlocked', $json$"la política de LLM de @{org} no deja ningún agente o modelo permitido para ella"$json$::jsonb),
  ('es', 'guidance.policyFix', $json$"Activa en Configuración un agente y un modelo que @{org} permita, o pide a un owner o maintainer de la organización que permita los que usas."$json$::jsonb),
  ('zh-CN', 'org.tab.policy', $json$"LLM 策略"$json$::jsonb),
  ('zh-CN', 'policy.title', $json$"LLM 策略"$json$::jsonb),
  ('zh-CN', 'policy.description', $json$"组织的项目可以使用什么。策略只会收紧：每个人自己的设置仍然在其之上生效。"$json$::jsonb),
  ('zh-CN', 'policy.scope', $json$"适用于"$json$::jsonb),
  ('zh-CN', 'policy.scope.org', $json$"整个组织"$json$::jsonb),
  ('zh-CN', 'policy.scope.set', $json$"已有策略"$json$::jsonb),
  ('zh-CN', 'policy.scope.unset', $json$"无策略"$json$::jsonb),
  ('zh-CN', 'policy.scope.repoNote', $json$"仓库策略与组织策略同时生效，以更严格的规则为准。"$json$::jsonb),
  ('zh-CN', 'policy.none', $json$"这里还没有策略。项目遵循每个人自己的设置。"$json$::jsonb),
  ('zh-CN', 'policy.readOnly', $json$"只有 owner 和 maintainer 可以修改策略。"$json$::jsonb),
  ('zh-CN', 'policy.agents.title', $json$"代理和模型"$json$::jsonb),
  ('zh-CN', 'policy.agents.all', $json$"所有代理"$json$::jsonb),
  ('zh-CN', 'policy.agents.all.hint', $json$"关闭后可选择项目能运行哪些代理。"$json$::jsonb),
  ('zh-CN', 'policy.agents.invalid', $json$"请至少选择一个代理。"$json$::jsonb),
  ('zh-CN', 'policy.models', $json$"禁用的模型"$json$::jsonb),
  ('zh-CN', 'policy.models.hint', $json$"每行一个，格式为 代理/模型（claude/opus）。"$json$::jsonb),
  ('zh-CN', 'policy.models.invalid', $json$"请使用 代理/模型 格式，代理为 claude、codex、copilot 或 cursor。"$json$::jsonb),
  ('zh-CN', 'policy.safe', $json$"关闭无防护模式"$json$::jsonb),
  ('zh-CN', 'policy.safe.hint', $json$"Claude Code 不用 bypassPermissions，Codex 不用 danger-full-access，Copilot 不开放全部工具，Cursor 不用 --force。"$json$::jsonb),
  ('zh-CN', 'policy.privacy.title', $json$"隐私"$json$::jsonb),
  ('zh-CN', 'policy.privacy.description', $json$"会加到每个人自己的规则上。每行一个 glob 模式。"$json$::jsonb),
  ('zh-CN', 'policy.redact.hint', $json$"为所有人开启密钥脱敏；关闭时由每个人自己决定。"$json$::jsonb),
  ('zh-CN', 'policy.patterns.invalid', $json$"最多 50 个模式，每个最多 200 个字符。"$json$::jsonb),
  ('zh-CN', 'policy.exit.title', $json$"出口关卡"$json$::jsonb),
  ('zh-CN', 'policy.exit.description', $json$"每条规则的下限：个人更严格的选择仍然有效。"$json$::jsonb),
  ('zh-CN', 'policy.save', $json$"保存策略"$json$::jsonb),
  ('zh-CN', 'policy.saved', $json$"策略已保存。"$json$::jsonb),
  ('zh-CN', 'policy.clear', $json$"移除策略"$json$::jsonb),
  ('zh-CN', 'policy.clear.title', $json$"移除此策略？"$json$::jsonb),
  ('zh-CN', 'policy.clear.description', $json$"每个人下次同步后，项目将不再遵循它。"$json$::jsonb),
  ('zh-CN', 'policy.cleared', $json$"策略已移除。"$json$::jsonb),
  ('zh-CN', 'policy.badge', $json$"LLM 策略"$json$::jsonb),
  ('zh-CN', 'policy.badge.hint', $json$"此项目的请求遵循 @{slug} 的 LLM 策略。"$json$::jsonb),
  ('zh-CN', 'policy.invalid', $json$"策略中有服务器拒绝的值。"$json$::jsonb),
  ('zh-CN', 'policy.repository', $json$"该仓库属于另一个组织。"$json$::jsonb),
  ('zh-CN', 'guidance.failed', $json$"请求未能运行，因为{problem}。"$json$::jsonb),
  ('zh-CN', 'guidance.fix', $json$"打开设置，启用一个代理，并至少保留它的一个模型处于启用状态。"$json$::jsonb),
  ('zh-CN', 'guidance.nothingConfigured', $json$"没有配置任何代理或模型"$json$::jsonb),
  ('zh-CN', 'guidance.noModels', $json$"有代理，但没有配置模型"$json$::jsonb),
  ('zh-CN', 'guidance.noAgent', $json$"没有启用的代理"$json$::jsonb),
  ('zh-CN', 'guidance.noFittingModel', $json$"没有适合此请求的已配置模型"$json$::jsonb),
  ('zh-CN', 'guidance.unknownProvider', $json$"所选模型指向不存在的代理 `{provider}`"$json$::jsonb),
  ('zh-CN', 'guidance.policyBlocked', $json$"@{org} 的 LLM 策略没有为它留下任何允许的代理或模型"$json$::jsonb),
  ('zh-CN', 'guidance.policyFix', $json$"在设置中启用 @{org} 允许的代理和模型，或请组织的 owner 或 maintainer 允许你使用的那些。"$json$::jsonb),
  ('hi', 'org.tab.policy', $json$"LLM नीति"$json$::jsonb),
  ('hi', 'policy.title', $json$"LLM नीति"$json$::jsonb),
  ('hi', 'policy.description', $json$"संगठन के प्रोजेक्ट क्या इस्तेमाल कर सकते हैं। नीति सिर्फ़ सख़्त करती है: हर व्यक्ति की अपनी सेटिंग्स उसके ऊपर लागू रहती हैं।"$json$::jsonb),
  ('hi', 'policy.scope', $json$"किस पर लागू"$json$::jsonb),
  ('hi', 'policy.scope.org', $json$"पूरा संगठन"$json$::jsonb),
  ('hi', 'policy.scope.set', $json$"नीति है"$json$::jsonb),
  ('hi', 'policy.scope.unset', $json$"कोई नीति नहीं"$json$::jsonb),
  ('hi', 'policy.scope.repoNote', $json$"रिपॉज़िटरी की नीति संगठन की नीति के साथ लागू होती है, और ज़्यादा सख़्त नियम जीतता है।"$json$::jsonb),
  ('hi', 'policy.none', $json$"यहाँ अभी कोई नीति नहीं है। प्रोजेक्ट हर व्यक्ति की सेटिंग्स का पालन करते हैं।"$json$::jsonb),
  ('hi', 'policy.readOnly', $json$"सिर्फ़ owner और maintainer नीति बदल सकते हैं।"$json$::jsonb),
  ('hi', 'policy.agents.title', $json$"एजेंट और मॉडल"$json$::jsonb),
  ('hi', 'policy.agents.all', $json$"सभी एजेंट"$json$::jsonb),
  ('hi', 'policy.agents.all.hint', $json$"बंद करें और चुनें कि प्रोजेक्ट कौन-से एजेंट चला सकते हैं।"$json$::jsonb),
  ('hi', 'policy.agents.invalid', $json$"कम से कम एक एजेंट चुनें।"$json$::jsonb),
  ('hi', 'policy.models', $json$"रोके गए मॉडल"$json$::jsonb),
  ('hi', 'policy.models.hint', $json$"हर पंक्ति में एक, एजेंट/मॉडल के रूप में (claude/opus)।"$json$::jsonb),
  ('hi', 'policy.models.invalid', $json$"एजेंट/मॉडल लिखें, एजेंट claude, codex, copilot या cursor में से हो।"$json$::jsonb),
  ('hi', 'policy.safe', $json$"बिना सुरक्षा वाले मोड बंद करें"$json$::jsonb),
  ('hi', 'policy.safe.hint', $json$"Claude Code में bypassPermissions नहीं, Codex में danger-full-access नहीं, Copilot में सारे टूल नहीं और Cursor में --force नहीं।"$json$::jsonb),
  ('hi', 'policy.privacy.title', $json$"गोपनीयता"$json$::jsonb),
  ('hi', 'policy.privacy.description', $json$"हर व्यक्ति के अपने पैटर्न में जोड़े जाते हैं। हर पंक्ति में एक glob पैटर्न।"$json$::jsonb),
  ('hi', 'policy.redact.hint', $json$"सबके लिए सीक्रेट हटाना चालू करता है; बंद होने पर हर व्यक्ति तय करता है।"$json$::jsonb),
  ('hi', 'policy.patterns.invalid', $json$"अधिकतम 50 पैटर्न, हर एक अधिकतम 200 अक्षर।"$json$::jsonb),
  ('hi', 'policy.exit.title', $json$"निकास गेट"$json$::jsonb),
  ('hi', 'policy.exit.description', $json$"हर नियम का न्यूनतम स्तर: किसी व्यक्ति का ज़्यादा सख़्त चुनाव फिर भी लागू रहता है।"$json$::jsonb),
  ('hi', 'policy.save', $json$"नीति सहेजें"$json$::jsonb),
  ('hi', 'policy.saved', $json$"नीति सहेजी गई।"$json$::jsonb),
  ('hi', 'policy.clear', $json$"नीति हटाएँ"$json$::jsonb),
  ('hi', 'policy.clear.title', $json$"यह नीति हटाएँ?"$json$::jsonb),
  ('hi', 'policy.clear.description', $json$"हर व्यक्ति के अगले सिंक पर प्रोजेक्ट इसका पालन करना बंद कर देंगे।"$json$::jsonb),
  ('hi', 'policy.cleared', $json$"नीति हटा दी गई।"$json$::jsonb),
  ('hi', 'policy.badge', $json$"LLM नीति"$json$::jsonb),
  ('hi', 'policy.badge.hint', $json$"इस प्रोजेक्ट के अनुरोध @{slug} की LLM नीति का पालन करते हैं।"$json$::jsonb),
  ('hi', 'policy.invalid', $json$"नीति में ऐसा मान है जिसे सर्वर ने अस्वीकार किया।"$json$::jsonb),
  ('hi', 'policy.repository', $json$"यह रिपॉज़िटरी किसी दूसरे संगठन की है।"$json$::jsonb),
  ('hi', 'guidance.failed', $json$"अनुरोध नहीं चला क्योंकि {problem}।"$json$::jsonb),
  ('hi', 'guidance.fix', $json$"सेटिंग्स खोलें, एक एजेंट चालू करें और उसका कम से कम एक मॉडल सक्रिय रखें।"$json$::jsonb),
  ('hi', 'guidance.nothingConfigured', $json$"कोई एजेंट या मॉडल कॉन्फ़िगर नहीं है"$json$::jsonb),
  ('hi', 'guidance.noModels', $json$"एजेंट हैं, पर कोई मॉडल कॉन्फ़िगर नहीं है"$json$::jsonb),
  ('hi', 'guidance.noAgent', $json$"कोई एजेंट चालू नहीं है"$json$::jsonb),
  ('hi', 'guidance.noFittingModel', $json$"कोई कॉन्फ़िगर किया गया मॉडल इस अनुरोध के लायक नहीं है"$json$::jsonb),
  ('hi', 'guidance.unknownProvider', $json$"चुना गया मॉडल `{provider}` एजेंट की ओर इशारा करता है, जो मौजूद नहीं है"$json$::jsonb),
  ('hi', 'guidance.policyBlocked', $json$"@{org} की LLM नीति इसके लिए कोई अनुमत एजेंट या मॉडल नहीं छोड़ती"$json$::jsonb),
  ('hi', 'guidance.policyFix', $json$"सेटिंग्स में ऐसा एजेंट और मॉडल चालू करें जिसकी @{org} अनुमति देता है, या संगठन के किसी owner या maintainer से अपने इस्तेमाल वालों की अनुमति माँगें।"$json$::jsonb),
  ('ar', 'org.tab.policy', $json$"سياسة LLM"$json$::jsonb),
  ('ar', 'policy.title', $json$"سياسة LLM"$json$::jsonb),
  ('ar', 'policy.description', $json$"ما يمكن لمشاريع المؤسسة استخدامه. السياسة تشدّد فقط: تبقى إعدادات كل شخص سارية فوقها."$json$::jsonb),
  ('ar', 'policy.scope', $json$"تنطبق على"$json$::jsonb),
  ('ar', 'policy.scope.org', $json$"المؤسسة بأكملها"$json$::jsonb),
  ('ar', 'policy.scope.set', $json$"لها سياسة"$json$::jsonb),
  ('ar', 'policy.scope.unset', $json$"بلا سياسة"$json$::jsonb),
  ('ar', 'policy.scope.repoNote', $json$"تنطبق سياسة المستودع مع سياسة المؤسسة، والقاعدة الأشد هي التي تسري."$json$::jsonb),
  ('ar', 'policy.none', $json$"لا توجد سياسة هنا بعد. تتبع المشاريع إعدادات كل شخص."$json$::jsonb),
  ('ar', 'policy.readOnly', $json$"يغيّر السياسة المالكون والمشرفون فقط."$json$::jsonb),
  ('ar', 'policy.agents.title', $json$"الوكلاء والنماذج"$json$::jsonb),
  ('ar', 'policy.agents.all', $json$"جميع الوكلاء"$json$::jsonb),
  ('ar', 'policy.agents.all.hint', $json$"أوقفه لتختار الوكلاء الذين يمكن للمشاريع تشغيلهم."$json$::jsonb),
  ('ar', 'policy.agents.invalid', $json$"اختر وكيلًا واحدًا على الأقل."$json$::jsonb),
  ('ar', 'policy.models', $json$"النماذج المحظورة"$json$::jsonb),
  ('ar', 'policy.models.hint', $json$"واحد في كل سطر، بصيغة وكيل/نموذج (claude/opus)."$json$::jsonb),
  ('ar', 'policy.models.invalid', $json$"استخدم وكيل/نموذج، على أن يكون الوكيل من claude أو codex أو copilot أو cursor."$json$::jsonb),
  ('ar', 'policy.safe', $json$"إيقاف الأوضاع غير المحمية"$json$::jsonb),
  ('ar', 'policy.safe.hint', $json$"لا bypassPermissions في Claude Code، ولا danger-full-access في Codex، ولا كل الأدوات في Copilot، ولا --force في Cursor."$json$::jsonb),
  ('ar', 'policy.privacy.title', $json$"الخصوصية"$json$::jsonb),
  ('ar', 'policy.privacy.description', $json$"تُضاف إلى أنماط كل شخص. نمط glob واحد في كل سطر."$json$::jsonb),
  ('ar', 'policy.redact.hint', $json$"يفعّل حجب الأسرار للجميع؛ وعند إيقافه يقرّر كل شخص."$json$::jsonb),
  ('ar', 'policy.patterns.invalid', $json$"حتى 50 نمطًا، كل منها حتى 200 حرف."$json$::jsonb),
  ('ar', 'policy.exit.title', $json$"بوابة الخروج"$json$::jsonb),
  ('ar', 'policy.exit.description', $json$"الحد الأدنى لكل قاعدة: يبقى اختيار الشخص الأشد ساريًا."$json$::jsonb),
  ('ar', 'policy.save', $json$"حفظ السياسة"$json$::jsonb),
  ('ar', 'policy.saved', $json$"تم حفظ السياسة."$json$::jsonb),
  ('ar', 'policy.clear', $json$"إزالة السياسة"$json$::jsonb),
  ('ar', 'policy.clear.title', $json$"إزالة هذه السياسة؟"$json$::jsonb),
  ('ar', 'policy.clear.description', $json$"تتوقف المشاريع عن اتباعها عند المزامنة التالية لكل شخص."$json$::jsonb),
  ('ar', 'policy.cleared', $json$"تمت إزالة السياسة."$json$::jsonb),
  ('ar', 'policy.badge', $json$"سياسة LLM"$json$::jsonb),
  ('ar', 'policy.badge.hint', $json$"تتبع طلبات هذا المشروع سياسة LLM الخاصة بـ @{slug}."$json$::jsonb),
  ('ar', 'policy.invalid', $json$"تحتوي السياسة على قيمة رفضها الخادم."$json$::jsonb),
  ('ar', 'policy.repository', $json$"هذا المستودع تابع لمؤسسة أخرى."$json$::jsonb),
  ('ar', 'guidance.failed', $json$"تعذّر تشغيل الطلب لأن {problem}."$json$::jsonb),
  ('ar', 'guidance.fix', $json$"افتح الإعدادات، وشغّل وكيلًا، وأبقِ نموذجًا واحدًا على الأقل من نماذجه مفعّلًا."$json$::jsonb),
  ('ar', 'guidance.nothingConfigured', $json$"لا يوجد وكيل أو نموذج مُعدّ"$json$::jsonb),
  ('ar', 'guidance.noModels', $json$"توجد وكلاء لكن لا يوجد نموذج مُعدّ"$json$::jsonb),
  ('ar', 'guidance.noAgent', $json$"لا يوجد وكيل مفعّل"$json$::jsonb),
  ('ar', 'guidance.noFittingModel', $json$"لا يناسب أي نموذج مُعدّ هذا الطلب"$json$::jsonb),
  ('ar', 'guidance.unknownProvider', $json$"النموذج المختار يشير إلى الوكيل `{provider}` غير الموجود"$json$::jsonb),
  ('ar', 'guidance.policyBlocked', $json$"سياسة LLM الخاصة بـ @{org} لا تترك له أي وكيل أو نموذج مسموح"$json$::jsonb),
  ('ar', 'guidance.policyFix', $json$"شغّل من الإعدادات وكيلًا ونموذجًا تسمح بهما @{org}، أو اطلب من أحد المالكين أو المشرفين السماح بما تستخدمه."$json$::jsonb),
  ('fr', 'org.tab.policy', $json$"Politique LLM"$json$::jsonb),
  ('fr', 'policy.title', $json$"Politique LLM"$json$::jsonb),
  ('fr', 'policy.description', $json$"Ce que les projets de l'organisation peuvent utiliser. La politique ne fait que restreindre : les réglages de chacun s'appliquent toujours par-dessus."$json$::jsonb),
  ('fr', 'policy.scope', $json$"S'applique à"$json$::jsonb),
  ('fr', 'policy.scope.org', $json$"Toute l'organisation"$json$::jsonb),
  ('fr', 'policy.scope.set', $json$"avec politique"$json$::jsonb),
  ('fr', 'policy.scope.unset', $json$"sans politique"$json$::jsonb),
  ('fr', 'policy.scope.repoNote', $json$"La politique du dépôt s'applique avec celle de l'organisation, et la règle la plus stricte l'emporte."$json$::jsonb),
  ('fr', 'policy.none', $json$"Pas encore de politique ici. Les projets suivent les réglages de chacun."$json$::jsonb),
  ('fr', 'policy.readOnly', $json$"Seuls les owners et maintainers modifient la politique."$json$::jsonb),
  ('fr', 'policy.agents.title', $json$"Agents et modèles"$json$::jsonb),
  ('fr', 'policy.agents.all', $json$"Tous les agents"$json$::jsonb),
  ('fr', 'policy.agents.all.hint', $json$"Désactivez pour choisir les agents que les projets peuvent lancer."$json$::jsonb),
  ('fr', 'policy.agents.invalid', $json$"Choisissez au moins un agent."$json$::jsonb),
  ('fr', 'policy.models', $json$"Modèles bloqués"$json$::jsonb),
  ('fr', 'policy.models.hint', $json$"Un par ligne, sous la forme agent/modèle (claude/opus)."$json$::jsonb),
  ('fr', 'policy.models.invalid', $json$"Utilisez agent/modèle, avec un agent parmi claude, codex, copilot et cursor."$json$::jsonb),
  ('fr', 'policy.safe', $json$"Désactiver les modes sans garde-fou"$json$::jsonb),
  ('fr', 'policy.safe.hint', $json$"Pas de bypassPermissions dans Claude Code, pas de danger-full-access dans Codex, pas tous les outils dans Copilot ni de --force dans Cursor."$json$::jsonb),
  ('fr', 'policy.privacy.title', $json$"Confidentialité"$json$::jsonb),
  ('fr', 'policy.privacy.description', $json$"Ajoutés aux motifs de chacun. Un motif glob par ligne."$json$::jsonb),
  ('fr', 'policy.redact.hint', $json$"Active le masquage des secrets pour tous ; désactivé, chacun décide."$json$::jsonb),
  ('fr', 'policy.patterns.invalid', $json$"Jusqu'à 50 motifs de 200 caractères au plus."$json$::jsonb),
  ('fr', 'policy.exit.title', $json$"Contrôle de sortie"$json$::jsonb),
  ('fr', 'policy.exit.description', $json$"Le minimum de chaque règle : le choix plus strict de chacun l'emporte toujours."$json$::jsonb),
  ('fr', 'policy.save', $json$"Enregistrer la politique"$json$::jsonb),
  ('fr', 'policy.saved', $json$"Politique enregistrée."$json$::jsonb),
  ('fr', 'policy.clear', $json$"Supprimer la politique"$json$::jsonb),
  ('fr', 'policy.clear.title', $json$"Supprimer cette politique ?"$json$::jsonb),
  ('fr', 'policy.clear.description', $json$"Les projets cessent de la suivre à la prochaine synchronisation de chacun."$json$::jsonb),
  ('fr', 'policy.cleared', $json$"Politique supprimée."$json$::jsonb),
  ('fr', 'policy.badge', $json$"Politique LLM"$json$::jsonb),
  ('fr', 'policy.badge.hint', $json$"Les requêtes de ce projet suivent la politique LLM de @{slug}."$json$::jsonb),
  ('fr', 'policy.invalid', $json$"La politique contient une valeur refusée par le serveur."$json$::jsonb),
  ('fr', 'policy.repository', $json$"Ce dépôt appartient à une autre organisation."$json$::jsonb),
  ('fr', 'guidance.failed', $json$"La requête n'a pas pu s'exécuter car {problem}."$json$::jsonb),
  ('fr', 'guidance.fix', $json$"Ouvrez les Réglages, activez un agent et gardez au moins un de ses modèles actif."$json$::jsonb),
  ('fr', 'guidance.nothingConfigured', $json$"aucun agent ni modèle n'est configuré"$json$::jsonb),
  ('fr', 'guidance.noModels', $json$"des agents existent mais aucun modèle n'est configuré"$json$::jsonb),
  ('fr', 'guidance.noAgent', $json$"aucun agent n'est activé"$json$::jsonb),
  ('fr', 'guidance.noFittingModel', $json$"aucun modèle configuré ne convient à cette requête"$json$::jsonb),
  ('fr', 'guidance.unknownProvider', $json$"le modèle choisi pointe vers l'agent `{provider}`, qui n'existe pas"$json$::jsonb),
  ('fr', 'guidance.policyBlocked', $json$"la politique LLM de @{org} ne lui laisse aucun agent ou modèle autorisé"$json$::jsonb),
  ('fr', 'guidance.policyFix', $json$"Activez dans les Réglages un agent et un modèle que @{org} autorise, ou demandez à un owner ou maintainer de l'organisation d'autoriser ceux que vous utilisez."$json$::jsonb),
  ('ru', 'org.tab.policy', $json$"Политика LLM"$json$::jsonb),
  ('ru', 'policy.title', $json$"Политика LLM"$json$::jsonb),
  ('ru', 'policy.description', $json$"Что могут использовать проекты организации. Политика только ужесточает: личные настройки каждого продолжают действовать поверх неё."$json$::jsonb),
  ('ru', 'policy.scope', $json$"Действует для"$json$::jsonb),
  ('ru', 'policy.scope.org', $json$"Вся организация"$json$::jsonb),
  ('ru', 'policy.scope.set', $json$"есть политика"$json$::jsonb),
  ('ru', 'policy.scope.unset', $json$"нет политики"$json$::jsonb),
  ('ru', 'policy.scope.repoNote', $json$"Политика репозитория действует вместе с политикой организации, и побеждает более строгое правило."$json$::jsonb),
  ('ru', 'policy.none', $json$"Здесь пока нет политики. Проекты следуют личным настройкам каждого."$json$::jsonb),
  ('ru', 'policy.readOnly', $json$"Менять политику могут только owner и maintainer."$json$::jsonb),
  ('ru', 'policy.agents.title', $json$"Агенты и модели"$json$::jsonb),
  ('ru', 'policy.agents.all', $json$"Все агенты"$json$::jsonb),
  ('ru', 'policy.agents.all.hint', $json$"Выключите, чтобы выбрать, каких агентов могут запускать проекты."$json$::jsonb),
  ('ru', 'policy.agents.invalid', $json$"Выберите хотя бы одного агента."$json$::jsonb),
  ('ru', 'policy.models', $json$"Заблокированные модели"$json$::jsonb),
  ('ru', 'policy.models.hint', $json$"По одной в строке, в виде агент/модель (claude/opus)."$json$::jsonb),
  ('ru', 'policy.models.invalid', $json$"Используйте агент/модель, где агент — claude, codex, copilot или cursor."$json$::jsonb),
  ('ru', 'policy.safe', $json$"Отключить режимы без защиты"$json$::jsonb),
  ('ru', 'policy.safe.hint', $json$"Без bypassPermissions в Claude Code, danger-full-access в Codex, всех инструментов в Copilot и --force в Cursor."$json$::jsonb),
  ('ru', 'policy.privacy.title', $json$"Конфиденциальность"$json$::jsonb),
  ('ru', 'policy.privacy.description', $json$"Добавляются к личным шаблонам каждого. Один glob-шаблон в строке."$json$::jsonb),
  ('ru', 'policy.redact.hint', $json$"Включает удаление секретов для всех; если выключено, решает каждый сам."$json$::jsonb),
  ('ru', 'policy.patterns.invalid', $json$"До 50 шаблонов длиной до 200 символов."$json$::jsonb),
  ('ru', 'policy.exit.title', $json$"Выходной контроль"$json$::jsonb),
  ('ru', 'policy.exit.description', $json$"Минимум для каждого правила: более строгий выбор человека всё равно действует."$json$::jsonb),
  ('ru', 'policy.save', $json$"Сохранить политику"$json$::jsonb),
  ('ru', 'policy.saved', $json$"Политика сохранена."$json$::jsonb),
  ('ru', 'policy.clear', $json$"Удалить политику"$json$::jsonb),
  ('ru', 'policy.clear.title', $json$"Удалить эту политику?"$json$::jsonb),
  ('ru', 'policy.clear.description', $json$"Проекты перестанут ей следовать при следующей синхронизации у каждого."$json$::jsonb),
  ('ru', 'policy.cleared', $json$"Политика удалена."$json$::jsonb),
  ('ru', 'policy.badge', $json$"Политика LLM"$json$::jsonb),
  ('ru', 'policy.badge.hint', $json$"Запросы этого проекта следуют политике LLM @{slug}."$json$::jsonb),
  ('ru', 'policy.invalid', $json$"В политике есть значение, которое сервер отклонил."$json$::jsonb),
  ('ru', 'policy.repository', $json$"Этот репозиторий принадлежит другой организации."$json$::jsonb),
  ('ru', 'guidance.failed', $json$"Запрос не выполнен, потому что {problem}."$json$::jsonb),
  ('ru', 'guidance.fix', $json$"Откройте Настройки, включите агента и оставьте активной хотя бы одну его модель."$json$::jsonb),
  ('ru', 'guidance.nothingConfigured', $json$"не настроено ни одного агента или модели"$json$::jsonb),
  ('ru', 'guidance.noModels', $json$"агенты есть, но ни одна модель не настроена"$json$::jsonb),
  ('ru', 'guidance.noAgent', $json$"ни один агент не включён"$json$::jsonb),
  ('ru', 'guidance.noFittingModel', $json$"ни одна настроенная модель не подходит для этого запроса"$json$::jsonb),
  ('ru', 'guidance.unknownProvider', $json$"выбранная модель указывает на несуществующего агента `{provider}`"$json$::jsonb),
  ('ru', 'guidance.policyBlocked', $json$"политика LLM @{org} не оставляет для него ни одного разрешённого агента или модели"$json$::jsonb),
  ('ru', 'guidance.policyFix', $json$"Включите в Настройках агента и модель, которые разрешает @{org}, или попросите owner или maintainer организации разрешить те, что вы используете."$json$::jsonb),
  ('ja', 'org.tab.policy', $json$"LLM ポリシー"$json$::jsonb),
  ('ja', 'policy.title', $json$"LLM ポリシー"$json$::jsonb),
  ('ja', 'policy.description', $json$"組織のプロジェクトが使えるもの。ポリシーは制限を強めるだけで、各自の設定はその上で引き続き有効です。"$json$::jsonb),
  ('ja', 'policy.scope', $json$"適用先"$json$::jsonb),
  ('ja', 'policy.scope.org', $json$"組織全体"$json$::jsonb),
  ('ja', 'policy.scope.set', $json$"ポリシーあり"$json$::jsonb),
  ('ja', 'policy.scope.unset', $json$"ポリシーなし"$json$::jsonb),
  ('ja', 'policy.scope.repoNote', $json$"リポジトリのポリシーは組織のポリシーと一緒に適用され、より厳しいルールが優先されます。"$json$::jsonb),
  ('ja', 'policy.none', $json$"ここにはまだポリシーがありません。プロジェクトは各自の設定に従います。"$json$::jsonb),
  ('ja', 'policy.readOnly', $json$"ポリシーを変更できるのは owner と maintainer だけです。"$json$::jsonb),
  ('ja', 'policy.agents.title', $json$"エージェントとモデル"$json$::jsonb),
  ('ja', 'policy.agents.all', $json$"すべてのエージェント"$json$::jsonb),
  ('ja', 'policy.agents.all.hint', $json$"オフにすると、プロジェクトが実行できるエージェントを選べます。"$json$::jsonb),
  ('ja', 'policy.agents.invalid', $json$"エージェントを 1 つ以上選んでください。"$json$::jsonb),
  ('ja', 'policy.models', $json$"ブロックするモデル"$json$::jsonb),
  ('ja', 'policy.models.hint', $json$"1 行に 1 つ、エージェント/モデル の形式で（claude/opus）。"$json$::jsonb),
  ('ja', 'policy.models.invalid', $json$"エージェント/モデル の形式で、エージェントは claude・codex・copilot・cursor のいずれかにしてください。"$json$::jsonb),
  ('ja', 'policy.safe', $json$"ガードなしのモードをオフにする"$json$::jsonb),
  ('ja', 'policy.safe.hint', $json$"Claude Code の bypassPermissions、Codex の danger-full-access、Copilot の全ツール許可、Cursor の --force を使いません。"$json$::jsonb),
  ('ja', 'policy.privacy.title', $json$"プライバシー"$json$::jsonb),
  ('ja', 'policy.privacy.description', $json$"各自のパターンに追加されます。1 行に 1 つの glob パターン。"$json$::jsonb),
  ('ja', 'policy.redact.hint', $json$"全員のシークレット除去をオンにします。オフなら各自が決めます。"$json$::jsonb),
  ('ja', 'policy.patterns.invalid', $json$"パターンは 50 個まで、各 200 文字までです。"$json$::jsonb),
  ('ja', 'policy.exit.title', $json$"出口ゲート"$json$::jsonb),
  ('ja', 'policy.exit.description', $json$"各ルールの最低ラインです。各自がより厳しく選んだ場合はそちらが優先されます。"$json$::jsonb),
  ('ja', 'policy.save', $json$"ポリシーを保存"$json$::jsonb),
  ('ja', 'policy.saved', $json$"ポリシーを保存しました。"$json$::jsonb),
  ('ja', 'policy.clear', $json$"ポリシーを削除"$json$::jsonb),
  ('ja', 'policy.clear.title', $json$"このポリシーを削除しますか？"$json$::jsonb),
  ('ja', 'policy.clear.description', $json$"各自の次回の同期から、プロジェクトはこのポリシーに従わなくなります。"$json$::jsonb),
  ('ja', 'policy.cleared', $json$"ポリシーを削除しました。"$json$::jsonb),
  ('ja', 'policy.badge', $json$"LLM ポリシー"$json$::jsonb),
  ('ja', 'policy.badge.hint', $json$"このプロジェクトのリクエストは @{slug} の LLM ポリシーに従います。"$json$::jsonb),
  ('ja', 'policy.invalid', $json$"ポリシーにサーバーが受け付けない値があります。"$json$::jsonb),
  ('ja', 'policy.repository', $json$"そのリポジトリは別の組織のものです。"$json$::jsonb),
  ('ja', 'guidance.failed', $json$"{problem}ため、リクエストを実行できませんでした。"$json$::jsonb),
  ('ja', 'guidance.fix', $json$"設定を開いてエージェントをオンにし、そのモデルを 1 つ以上有効のままにしてください。"$json$::jsonb),
  ('ja', 'guidance.nothingConfigured', $json$"エージェントもモデルも設定されていない"$json$::jsonb),
  ('ja', 'guidance.noModels', $json$"エージェントはあるがモデルが設定されていない"$json$::jsonb),
  ('ja', 'guidance.noAgent', $json$"オンのエージェントがない"$json$::jsonb),
  ('ja', 'guidance.noFittingModel', $json$"このリクエストに合う設定済みモデルがない"$json$::jsonb),
  ('ja', 'guidance.unknownProvider', $json$"選んだモデルが存在しないエージェント `{provider}` を指している"$json$::jsonb),
  ('ja', 'guidance.policyBlocked', $json$"@{org} の LLM ポリシーで許可されたエージェントやモデルが残っていない"$json$::jsonb),
  ('ja', 'guidance.policyFix', $json$"設定で @{org} が許可するエージェントとモデルをオンにするか、組織の owner または maintainer に使っているものを許可するよう依頼してください。"$json$::jsonb),
  ('de', 'org.tab.policy', $json$"LLM-Richtlinie"$json$::jsonb),
  ('de', 'policy.title', $json$"LLM-Richtlinie"$json$::jsonb),
  ('de', 'policy.description', $json$"Was die Projekte der Organisation nutzen dürfen. Die Richtlinie verschärft nur: Die eigenen Einstellungen jeder Person gelten weiterhin zusätzlich."$json$::jsonb),
  ('de', 'policy.scope', $json$"Gilt für"$json$::jsonb),
  ('de', 'policy.scope.org', $json$"Die ganze Organisation"$json$::jsonb),
  ('de', 'policy.scope.set', $json$"mit Richtlinie"$json$::jsonb),
  ('de', 'policy.scope.unset', $json$"ohne Richtlinie"$json$::jsonb),
  ('de', 'policy.scope.repoNote', $json$"Die Richtlinie des Repositorys gilt zusammen mit der der Organisation, und die strengere Regel gewinnt."$json$::jsonb),
  ('de', 'policy.none', $json$"Hier gibt es noch keine Richtlinie. Projekte folgen den Einstellungen jeder Person."$json$::jsonb),
  ('de', 'policy.readOnly', $json$"Nur Owner und Maintainer ändern die Richtlinie."$json$::jsonb),
  ('de', 'policy.agents.title', $json$"Agenten und Modelle"$json$::jsonb),
  ('de', 'policy.agents.all', $json$"Alle Agenten"$json$::jsonb),
  ('de', 'policy.agents.all.hint', $json$"Ausschalten, um auszuwählen, welche Agenten die Projekte ausführen dürfen."$json$::jsonb),
  ('de', 'policy.agents.invalid', $json$"Wähle mindestens einen Agenten."$json$::jsonb),
  ('de', 'policy.models', $json$"Gesperrte Modelle"$json$::jsonb),
  ('de', 'policy.models.hint', $json$"Eins pro Zeile, als Agent/Modell (claude/opus)."$json$::jsonb),
  ('de', 'policy.models.invalid', $json$"Verwende Agent/Modell, mit claude, codex, copilot oder cursor als Agent."$json$::jsonb),
  ('de', 'policy.safe', $json$"Ungesicherte Modi ausschalten"$json$::jsonb),
  ('de', 'policy.safe.hint', $json$"Kein bypassPermissions in Claude Code, kein danger-full-access in Codex, nicht alle Werkzeuge in Copilot und kein --force in Cursor."$json$::jsonb),
  ('de', 'policy.privacy.title', $json$"Datenschutz"$json$::jsonb),
  ('de', 'policy.privacy.description', $json$"Werden zu den eigenen Mustern jeder Person hinzugefügt. Ein Glob-Muster pro Zeile."$json$::jsonb),
  ('de', 'policy.redact.hint', $json$"Schaltet das Entfernen von Geheimnissen für alle ein; aus, entscheidet jede Person selbst."$json$::jsonb),
  ('de', 'policy.patterns.invalid', $json$"Bis zu 50 Muster mit je höchstens 200 Zeichen."$json$::jsonb),
  ('de', 'policy.exit.title', $json$"Ausgangskontrolle"$json$::jsonb),
  ('de', 'policy.exit.description', $json$"Das Minimum je Regel: Die strengere Wahl einer Person gilt weiterhin."$json$::jsonb),
  ('de', 'policy.save', $json$"Richtlinie speichern"$json$::jsonb),
  ('de', 'policy.saved', $json$"Richtlinie gespeichert."$json$::jsonb),
  ('de', 'policy.clear', $json$"Richtlinie entfernen"$json$::jsonb),
  ('de', 'policy.clear.title', $json$"Diese Richtlinie entfernen?"$json$::jsonb),
  ('de', 'policy.clear.description', $json$"Projekte folgen ihr ab der nächsten Synchronisierung jeder Person nicht mehr."$json$::jsonb),
  ('de', 'policy.cleared', $json$"Richtlinie entfernt."$json$::jsonb),
  ('de', 'policy.badge', $json$"LLM-Richtlinie"$json$::jsonb),
  ('de', 'policy.badge.hint', $json$"Anfragen in diesem Projekt folgen der LLM-Richtlinie von @{slug}."$json$::jsonb),
  ('de', 'policy.invalid', $json$"Die Richtlinie enthält einen Wert, den der Server abgelehnt hat."$json$::jsonb),
  ('de', 'policy.repository', $json$"Dieses Repository gehört zu einer anderen Organisation."$json$::jsonb),
  ('de', 'guidance.failed', $json$"Die Anfrage konnte nicht laufen, weil {problem}."$json$::jsonb),
  ('de', 'guidance.fix', $json$"Öffne die Einstellungen, schalte einen Agenten ein und lass mindestens eines seiner Modelle aktiv."$json$::jsonb),
  ('de', 'guidance.nothingConfigured', $json$"kein Agent und kein Modell eingerichtet ist"$json$::jsonb),
  ('de', 'guidance.noModels', $json$"es Agenten gibt, aber kein Modell eingerichtet ist"$json$::jsonb),
  ('de', 'guidance.noAgent', $json$"kein Agent eingeschaltet ist"$json$::jsonb),
  ('de', 'guidance.noFittingModel', $json$"kein eingerichtetes Modell zu dieser Anfrage passt"$json$::jsonb),
  ('de', 'guidance.unknownProvider', $json$"das gewählte Modell auf den Agenten `{provider}` verweist, den es nicht gibt"$json$::jsonb),
  ('de', 'guidance.policyBlocked', $json$"die LLM-Richtlinie von @{org} keinen erlaubten Agenten und kein erlaubtes Modell dafür übrig lässt"$json$::jsonb),
  ('de', 'guidance.policyFix', $json$"Schalte in den Einstellungen einen Agenten und ein Modell ein, die @{org} erlaubt, oder bitte einen Owner oder Maintainer der Organisation, die von dir genutzten zu erlauben."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
