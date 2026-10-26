-- v0.109.0: política de validação da organização. O dono ou mantenedor pode
-- exigir, no site, que os builds dos projetos da organização sejam validados
-- (testes, lint, typecheck e build) com ponto de volta salvo antes, e pode
-- reter `git commit` e `git push` no chat enquanto a última validação falhou.
-- A política chega ao app por `my_project_policies` (chaves
-- `validation_required`, `hold_commits` e `validation_sources`) e o app a
-- aplica por cima das configurações de quem usa.
--
-- Vale para a organização inteira. O projeto roda sob a união das
-- organizações dele: basta uma exigir. Leitura por RLS (membro lê); escrita
-- só pela RPC, que confere o papel.

create table public.organization_validation (
  org_id uuid primary key references public.organizations on delete cascade,
  required boolean not null default false,
  hold_commits boolean not null default false,
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now(),
  -- Reter commit só faz sentido com a validação exigida.
  check (required or not hold_commits)
);

alter table public.organization_validation enable row level security;
create policy "membro lê" on public.organization_validation for select to authenticated
  using ((select public.org_role(org_id)) is not null);

-- Grava a política de validação da organização. Sem exigir, a linha é apagada.
create function public.set_validation_policy(org uuid, required boolean, hold_commits boolean default false) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if hold_commits and not required then raise exception 'policy.invalid'; end if;
  delete from public.organization_validation v where v.org_id = org;
  if not required then return; end if;
  insert into public.organization_validation (org_id, required, hold_commits, updated_by) values (org, true, hold_commits, auth.uid());
end;
$$;
revoke all on function public.set_validation_policy(uuid, boolean, boolean) from public, anon;
grant execute on function public.set_validation_policy(uuid, boolean, boolean) to authenticated;

-- A política de uma organização no formato da política do projeto; `{}` quando
-- ela não exige nada. Interna: não confere papel.
create function public.validation_of(org uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((
    select jsonb_build_object('validation_required', true, 'hold_commits', v.hold_commits, 'validation_sources', jsonb_build_array(o.slug))
    from public.organization_validation v
    join public.organizations o on o.id = v.org_id
    where v.org_id = org and v.required
  ), '{}'::jsonb);
$$;
revoke all on function public.validation_of(uuid) from public, anon, authenticated;

-- Une as políticas de várias organizações: exige quem qualquer uma exige, retém
-- commit se qualquer uma reter, e lista quem exige.
create function public.validation_merge(a jsonb, b jsonb) returns jsonb language sql immutable set search_path = '' as $$
  select case
    when a = '{}'::jsonb then b
    when b = '{}'::jsonb then a
    else jsonb_build_object(
      'validation_required', true,
      'hold_commits', coalesce((a->>'hold_commits')::boolean, false) or coalesce((b->>'hold_commits')::boolean, false),
      'validation_sources', (select coalesce(jsonb_agg(distinct s), '[]'::jsonb) from jsonb_array_elements_text((a->'validation_sources') || (b->'validation_sources')) s))
  end;
$$;
create aggregate public.validation_merge_all(jsonb) (sfunc = public.validation_merge, stype = jsonb, initcond = '{}');

-- A mesma `my_project_policies` da v0.101.0, com as chaves da validação na
-- política do projeto. Projeto que só tem validação exigida também aparece.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy,
           public.command_sources_of(pr.org_id, null, true) as sources,
           public.grant_sources_of(pr.org_id) as grants,
           public.grant_defaults_of(pr.org_id) as defaults,
           public.validation_of(pr.org_id) as validation, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = pr.org_id::text
    union all
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), public.command_sources_of(r.org_id, r.id, false),
           public.grant_sources_of(r.org_id), public.grant_defaults_of(r.org_id), public.validation_of(r.org_id), false
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
           public.command_sources_merge_all(l.sources order by l.own desc, o.slug) as sources,
           public.command_sources_merge_all(l.grants order by l.own desc, o.slug) as grants,
           public.command_sources_merge_all(l.defaults order by l.own desc, o.slug) as defaults,
           public.validation_merge_all(l.validation order by l.own desc, o.slug) as validation
    from linked l
    join public.organizations o on o.id = l.org_id
    group by l.project_id
  )
  select m.project_id, m.org_id, m.org_slug,
         coalesce(m.policy, '{}'::jsonb)
         || case
           when m.sources = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_commands', (select jsonb_agg(k order by k) from jsonb_object_keys(m.sources) k),
             'command_sources', m.sources)
         end
         || case
           when m.grants = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_grants', (select jsonb_agg(k order by k) from jsonb_object_keys(m.grants) k),
             'grant_sources', m.grants)
         end
         || case
           when m.defaults = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'enabled_grants', (select jsonb_agg(k order by k) from jsonb_object_keys(m.defaults) k),
             'grant_defaults', m.defaults)
         end
         || m.validation
  from merged m
  where m.policy is not null or m.sources <> '{}'::jsonb or m.grants <> '{}'::jsonb or m.defaults <> '{}'::jsonb
    or m.validation <> '{}'::jsonb;
$$;
