-- Cada organização do JayV fica presa a UMA organização no provedor git: a
-- organização do GitHub, o grupo do GitLab ou o workspace do Bitbucket que o
-- owner escolhe logo depois de conectar. Sem isso, uma conta com acesso a
-- várias organizações no provedor deixava associar, na organização Y do
-- JayV, repositórios da organização do provedor usada na X.
--
-- namespace: o dono no caminho dos repositórios (`acme` em `acme/api`; no
-- GitLab, o grupo com os subgrupos, `grupo/sub`). Nulo até o owner escolher;
-- volta a nulo quando ele conecta outra conta do provedor.

alter table public.organization_git_connections
  add column namespace text check (namespace ~ '^[a-z0-9._-]+(/[a-z0-9._-]+)*$' and char_length(namespace) <= 200);

-- Conectar de novo com a mesma conta mantém a organização escolhida; com
-- outra conta, ela precisa ser escolhida de novo.
create or replace function public.org_connect_git(org uuid, provider text, account text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner']);
  if provider not in ('github', 'gitlab', 'bitbucket') or char_length(btrim(coalesce(account, ''))) not between 1 and 100 then
    raise exception 'org.repoInvalid';
  end if;
  insert into public.organization_git_connections (org_id, provider, account, connected_by)
    values (org, provider, btrim(account), auth.uid())
  on conflict on constraint organization_git_connections_pkey do update
    set account = excluded.account, connected_by = excluded.connected_by, connected_at = now(),
        namespace = case when public.organization_git_connections.account = excluded.account then public.organization_git_connections.namespace end;
end;
$$;

-- A organização do provedor desta organização do JayV. O site confere com o
-- token que a conta conectada alcança essa organização antes de chamar.
create function public.org_choose_git_namespace(org uuid, provider text, namespace text) returns void language plpgsql security definer set search_path = '' as $$
declare
  clean text := lower(btrim(coalesce(namespace, ''), ' /'));
begin
  perform public.org_require(org, array['owner']);
  if clean !~ '^[a-z0-9._-]+(/[a-z0-9._-]+)*$' or char_length(clean) > 200 then
    raise exception 'org.repoInvalid';
  end if;
  update public.organization_git_connections c set namespace = clean
    where c.org_id = org and c.provider = org_choose_git_namespace.provider;
  if not found then raise exception 'org.gitNotConnected'; end if;
end;
$$;

-- Associar exige a organização do provedor escolhida e só aceita repositórios
-- dela.
create or replace function public.org_link_repositories(org uuid, provider text, repositories jsonb) returns integer language plpgsql security definer set search_path = '' as $$
declare
  item jsonb;
  linked integer := 0;
  clean text;
  owner_space text;
begin
  perform public.org_require(org, array['owner']);
  select c.namespace into owner_space from public.organization_git_connections c
    where c.org_id = org and c.provider = org_link_repositories.provider;
  if not found then raise exception 'org.gitNotConnected'; end if;
  if owner_space is null then raise exception 'org.gitNamespaceMissing'; end if;
  if jsonb_typeof(repositories) <> 'array' or jsonb_array_length(repositories) > 200 then
    raise exception 'org.repoInvalid';
  end if;
  for item in select value from jsonb_array_elements(repositories) loop
    clean := regexp_replace(lower(btrim(coalesce(item->>'path', ''), ' /')), '\.git$', '');
    if clean !~ '^[a-z0-9._-]+(/[a-z0-9._-]+)+$' then raise exception 'org.repoInvalid'; end if;
    if left(clean, char_length(owner_space) + 1) <> owner_space || '/' then raise exception 'org.repoOutsideNamespace'; end if;
    begin
      insert into public.organization_repositories as r
        (org_id, provider, path, added_by, external_id, default_branch, private, description, web_url, linked_via)
      values (
        org, provider, clean, auth.uid(),
        left(item->>'external_id', 100), left(item->>'default_branch', 200),
        case when jsonb_typeof(item->'private') = 'boolean' then (item->>'private')::boolean end,
        left(nullif(btrim(item->>'description'), ''), 300),
        case when item->>'web_url' ~ '^https://' then left(item->>'web_url', 500) end,
        'provider'
      )
      on conflict (org_id, repo_key) do update
        set external_id = excluded.external_id, default_branch = excluded.default_branch, private = excluded.private,
            description = excluded.description, web_url = excluded.web_url, linked_via = 'provider';
    exception
      when check_violation then raise exception 'org.repoInvalid';
    end;
    linked := linked + 1;
  end loop;
  return linked;
end;
$$;

revoke execute on function public.org_choose_git_namespace(uuid, text, text) from public, anon;
grant execute on function public.org_choose_git_namespace(uuid, text, text) to authenticated;
