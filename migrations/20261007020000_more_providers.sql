-- v0.75.0: Kilo Code, OpenRouter e LiteLLM como agentes. A política de LLM da
-- organização passa a reconhecê-los: na lista de agentes permitidos, nos
-- modelos bloqueados (`kilo/<modelo>`) e nos mecanismos.
--
-- Quem já tinha uma lista de agentes (`agents` não nulo) continua só com os
-- que listou: os três novos ficam de fora até a organização incluí-los. Sem
-- lista (nulo, "todos"), eles entram junto com os outros.

create or replace function public.policy_models_ok(models text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(models) <= 100
    and not exists (select 1 from unnest(models) m where m is null or m !~ '^(claude|codex|copilot|cursor|kilo|openrouter|litellm)/[A-Za-z0-9._:/@\[\]-]{1,120}$');
$$;

create or replace function public.policy_mechanisms_ok(mechanisms text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(mechanisms) <= 50
    and not exists (select 1 from unnest(mechanisms) m where m is null or m !~ '^(claude|codex|copilot|cursor|kilo|openrouter|litellm)/[A-Za-z]{1,40}$');
$$;

alter table public.organization_llm_policies drop constraint organization_llm_policies_agents_check;
alter table public.organization_llm_policies add constraint organization_llm_policies_agents_check check (
  agents is null
  or (cardinality(agents) between 1 and 7 and agents <@ array['claude', 'codex', 'copilot', 'cursor', 'kilo', 'openrouter', 'litellm'])
);

create or replace function public.set_llm_policy(org uuid, repository uuid, policy jsonb) returns void language plpgsql security definer set search_path = '' as $$
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
    agents := array(select a from unnest(array['claude', 'codex', 'copilot', 'cursor', 'kilo', 'openrouter', 'litellm']) a where a = any (public.policy_list(policy->'agents')));
    if cardinality(agents) <> cardinality(public.policy_list(policy->'agents')) then raise exception 'policy.invalid'; end if;
  end if;
  delete from public.organization_llm_policies p where p.org_id = org and p.repository_id is not distinct from repository;
  begin
    insert into public.organization_llm_policies
      (org_id, repository_id, agents, blocked_models, blocked_mechanisms, deny, local_only, safe_agents, redact_secrets, min_read, min_write, min_shell, updated_by)
    values (
      org, repository, agents,
      public.policy_list(policy->'blocked_models'), public.policy_list(policy->'blocked_mechanisms'),
      public.policy_list(policy->'deny'), public.policy_list(policy->'local_only'),
      coalesce((policy->>'safe_agents')::boolean, false), coalesce((policy->>'redact_secrets')::boolean, false),
      coalesce(policy->>'min_read', 'allow'), coalesce(policy->>'min_write', 'allow'), coalesce(policy->>'min_shell', 'allow'),
      auth.uid()
    );
  exception
    when check_violation or invalid_text_representation then raise exception 'policy.invalid';
  end;
end;
$$;
