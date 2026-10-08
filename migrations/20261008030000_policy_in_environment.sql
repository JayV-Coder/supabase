-- App 0.87.0: a política da organização vale só no ambiente dela. Um projeto
-- do ambiente pessoal não recebe mais a política de uma organização só porque
-- tem o mesmo repositório; o projeto da organização (ou movido para o ambiente
-- dela) continua recebendo. Mesma `my_project_policies` de antes, com o filtro
-- do ambiente nos dois ramos.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    -- A organização do projeto, quando quem chama é membro dela: valem as
    -- regras dela e as de todos os repositórios dela.
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy,
           public.command_sources_of(pr.org_id, null, true) as sources, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = pr.org_id::text
    union all
    -- Cada repositório do projeto que uma organização de quem chama
    -- cadastrou, não só o primeiro.
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), public.command_sources_of(r.org_id, r.id, false), false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = r.org_id::text
  ), merged as (
    select l.project_id,
           (array_agg(l.org_id order by l.own desc, o.slug))[1] as org_id,
           string_agg(distinct o.slug, ', ') as org_slug,
           public.policy_merge_all(l.policy order by l.own desc, o.slug) as policy,
           public.command_sources_merge_all(l.sources order by l.own desc, o.slug) as sources
    from linked l
    join public.organizations o on o.id = l.org_id
    group by l.project_id
  )
  select m.project_id, m.org_id, m.org_slug,
         coalesce(m.policy, '{}'::jsonb) || case
           when m.sources = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_commands', (select jsonb_agg(k order by k) from jsonb_object_keys(m.sources) k),
             'command_sources', m.sources)
         end
  from merged m
  where m.policy is not null or m.sources <> '{}'::jsonb;
$$;
