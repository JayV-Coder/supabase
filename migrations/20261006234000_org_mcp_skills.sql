-- Servidores MCP e skills da organização: o owner e os maintainers configuram
-- no site, e os membros recebem no app (`my_org_extensions`), somados aos que
-- cada um já tem. No app aparecem como "da organização", sem editar nem
-- remover.
--
-- O servidor MCP pode levar segredos (variáveis de ambiente, cabeçalhos): por
-- isso a tabela só é lida por owner e maintainer, e os membros a recebem pela
-- RPC, que só devolve o que está ligado. A skill não tem segredo e é lida por
-- qualquer membro. Escrita só pelas RPCs, que conferem o papel.

-- Um servidor no formato do app (`McpServer`, em camelCase): nome de 1 a 40
-- caracteres (`jayv` é reservado), transporte `stdio` com comando ou `http`
-- com URL.
create function public.org_mcp_config_ok(config jsonb) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(config) = 'object'
    and (config->>'name') ~ '^[A-Za-z0-9_-]{1,40}$'
    and (config->>'name') <> 'jayv'
    and octet_length(config::text) <= 20000
    and case config->>'transport'
      when 'stdio' then btrim(coalesce(config->>'command', '')) <> ''
      when 'http' then (config->>'url') ~ '^https?://'
      else false
    end,
    false
  );
$$;

create table public.organization_mcp_servers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9_-]{1,40}$'),
  config jsonb not null check (public.org_mcp_config_ok(config)),
  enabled boolean not null default true,
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);

create table public.organization_skills (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9_-]{1,64}$'),
  description text not null check (char_length(description) between 1 and 1024),
  body text not null check (char_length(btrim(body)) > 0 and char_length(body) <= 100000),
  enabled boolean not null default true,
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);

alter table public.organization_mcp_servers enable row level security;
alter table public.organization_skills enable row level security;

create policy "owner e maintainer leem" on public.organization_mcp_servers for select to authenticated
  using ((select public.org_role(org_id)) in ('owner', 'maintainer'));
create policy "membro lê" on public.organization_skills for select to authenticated
  using ((select public.org_role(org_id)) is not null);

-- Como toda tabela com RLS (migração `second_factor`); a escrita é só das RPCs.
do $$
declare
  t text;
begin
  foreach t in array array['organization_mcp_servers', 'organization_skills'] loop
    execute format('create policy "segundo fator" on public.%I as restrictive to authenticated using ((select public.second_factor_ok())) with check ((select public.second_factor_ok()))', t);
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end;
$$;

-- Grava (ou troca) o servidor de mesmo nome. Até 30 por organização.
create function public.set_org_mcp_server(org uuid, server jsonb, enabled boolean default true) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if not public.org_mcp_config_ok(server) then raise exception 'mcp.invalid'; end if;
  if not exists (select 1 from public.organization_mcp_servers s where s.org_id = org and s.name = server->>'name')
     and (select count(*) from public.organization_mcp_servers s where s.org_id = org) >= 30 then
    raise exception 'mcp.limit';
  end if;
  insert into public.organization_mcp_servers (org_id, name, config, enabled, updated_by)
  values (org, server->>'name', server, coalesce(enabled, true), auth.uid())
  on conflict (org_id, name) do update
    set config = excluded.config, enabled = excluded.enabled, updated_by = excluded.updated_by, updated_at = now();
end;
$$;

create function public.remove_org_mcp_server(org uuid, server_name text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  delete from public.organization_mcp_servers s where s.org_id = org and s.name = server_name;
end;
$$;

-- Grava (ou troca) a skill de mesmo nome. Até 50 por organização.
create function public.set_org_skill(org uuid, skill text, description text, body text, enabled boolean default true) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if skill is null or skill !~ '^[A-Za-z0-9_-]{1,64}$'
     or description is null or char_length(description) not between 1 and 1024
     or body is null or char_length(btrim(body)) = 0 or char_length(body) > 100000 then
    raise exception 'skill.invalid';
  end if;
  if not exists (select 1 from public.organization_skills s where s.org_id = org and s.name = skill)
     and (select count(*) from public.organization_skills s where s.org_id = org) >= 50 then
    raise exception 'skill.limit';
  end if;
  insert into public.organization_skills (org_id, name, description, body, enabled, updated_by)
  values (org, skill, description, body, coalesce(enabled, true), auth.uid())
  on conflict (org_id, name) do update
    set description = excluded.description, body = excluded.body, enabled = excluded.enabled, updated_by = excluded.updated_by, updated_at = now();
end;
$$;

create function public.remove_org_skill(org uuid, skill text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  delete from public.organization_skills s where s.org_id = org and s.name = skill;
end;
$$;

-- O que as organizações de quem chama dão a cada projeto dele: os servidores
-- MCP e as skills ligados da organização do projeto e das dos repositórios
-- dele (o mesmo vínculo da política de LLM). Mais uma linha por organização
-- de quem chama com `project_id` vazio, que não vale para chat nenhum e só
-- serve para a tela listar o que a organização dá. `own` é a organização do
-- próprio projeto, que ganha quando dois nomes coincidem.
create function public.my_org_extensions()
returns table (project_id text, org_slug text, own boolean, mcp jsonb, skills jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    select pr.id as project_id, pr.org_id, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    select pr.id, r.org_id, false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    select '', m.org_id, false from public.organization_members m where m.user_id = auth.uid()
  ),
  picked as (
    select distinct on (l.project_id, l.org_id) l.project_id, l.org_id, l.own
    from linked l
    order by l.project_id, l.org_id, l.own desc
  )
  select p.project_id, o.slug, p.own,
    coalesce((select jsonb_agg(s.config || jsonb_build_object('enabled', true) order by s.name)
              from public.organization_mcp_servers s where s.org_id = p.org_id and s.enabled), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('name', k.name, 'description', k.description, 'body', k.body) order by k.name)
              from public.organization_skills k where k.org_id = p.org_id and k.enabled), '[]'::jsonb)
  from picked p
  join public.organizations o on o.id = p.org_id
  order by p.project_id, p.own desc, o.slug;
$$;

do $$
declare
  fn text;
begin
  execute 'revoke execute on function public.org_mcp_config_ok(jsonb) from public, anon, authenticated';
  foreach fn in array array[
    'set_org_mcp_server(uuid, jsonb, boolean)', 'remove_org_mcp_server(uuid, text)',
    'set_org_skill(uuid, text, text, text, boolean)', 'remove_org_skill(uuid, text)', 'my_org_extensions()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end;
$$;
