-- Os repositórios da organização passam a ser associados no painel do site,
-- pelo login (OAuth) do owner no GitHub, no GitLab ou no Bitbucket. O app
-- deixa de ter o campo para colar a URL: ele só lê o que o site configurou e
-- clona.
--
-- O token do provedor nunca chega ao banco: o site o usa na hora, para listar
-- e conferir os repositórios que o owner alcança, e o descarta. Aqui fica só
-- qual conta foi conectada e os dados públicos de cada repositório.

-- 1. O provedor conectado de cada organização: qual conta o owner usou.
create table public.organization_git_connections (
  org_id uuid not null references public.organizations on delete cascade,
  provider text not null check (provider in ('github', 'gitlab', 'bitbucket')),
  account text not null check (char_length(btrim(account)) between 1 and 100),
  connected_by uuid references auth.users on delete set null,
  connected_at timestamptz not null default now(),
  primary key (org_id, provider)
);

alter table public.organization_git_connections enable row level security;
create policy "membro lê" on public.organization_git_connections for select to authenticated
  using ((select public.org_role(org_id)) is not null);
-- Como toda tabela com RLS (migração `second_factor`).
create policy "segundo fator" on public.organization_git_connections as restrictive to authenticated
  using ((select public.second_factor_ok())) with check ((select public.second_factor_ok()));
revoke insert, update, delete, truncate on public.organization_git_connections from anon, authenticated;
revoke all on public.organization_git_connections from anon;

-- 2. O que o provedor diz de cada repositório, para o site e o app
-- mostrarem: privado, branch padrão, descrição e o endereço da página.
-- `linked_via` separa o que veio do provedor do que foi colado como URL
-- antes desta migração.
alter table public.organization_repositories
  add column external_id text check (char_length(external_id) <= 100),
  add column default_branch text check (char_length(default_branch) <= 200),
  add column private boolean,
  add column description text check (char_length(description) <= 300),
  add column web_url text check (web_url ~ '^https://' and char_length(web_url) <= 500),
  add column linked_via text not null default 'url' check (linked_via in ('url', 'provider'));

-- 3. Conectar e desconectar o provedor: só o owner.
create function public.org_connect_git(org uuid, provider text, account text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner']);
  if provider not in ('github', 'gitlab', 'bitbucket') or char_length(btrim(coalesce(account, ''))) not between 1 and 100 then
    raise exception 'org.repoInvalid';
  end if;
  insert into public.organization_git_connections (org_id, provider, account, connected_by)
    values (org, provider, btrim(account), auth.uid())
  on conflict on constraint organization_git_connections_pkey do update
    set account = excluded.account, connected_by = excluded.connected_by, connected_at = now();
end;
$$;

-- Desconectar não tira os repositórios: eles continuam na organização até o
-- owner removê-los.
create function public.org_disconnect_git(org uuid, provider text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner']);
  delete from public.organization_git_connections c where c.org_id = org and c.provider = org_disconnect_git.provider;
end;
$$;

-- 4. Associa os repositórios escolhidos pelo owner na lista do provedor. O
-- site confere cada um com o token antes de chamar; aqui vale a regra do
-- banco: owner, provedor conectado e caminho válido. Um repositório que já
-- estava (inclusive colado por URL) ganha os dados do provedor.
create function public.org_link_repositories(org uuid, provider text, repositories jsonb) returns integer language plpgsql security definer set search_path = '' as $$
declare
  item jsonb;
  linked integer := 0;
  clean text;
begin
  perform public.org_require(org, array['owner']);
  if not exists (select 1 from public.organization_git_connections c where c.org_id = org and c.provider = org_link_repositories.provider) then
    raise exception 'org.gitNotConnected';
  end if;
  if jsonb_typeof(repositories) <> 'array' or jsonb_array_length(repositories) > 200 then
    raise exception 'org.repoInvalid';
  end if;
  for item in select value from jsonb_array_elements(repositories) loop
    clean := regexp_replace(lower(btrim(coalesce(item->>'path', ''), ' /')), '\.git$', '');
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

-- 5. Adicionar por URL (o app antigo) e remover passam a ser só do owner,
-- como associar pelo provedor.
create or replace function public.add_repository(org uuid, provider text, path text) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  repository uuid;
begin
  perform public.org_require(org, array['owner']);
  begin
    insert into public.organization_repositories (org_id, provider, path, added_by)
      values (org, provider, regexp_replace(lower(btrim(path, ' /')), '\.git$', ''), auth.uid())
      returning id into repository;
  exception
    when unique_violation then raise exception 'org.repoTaken';
    when check_violation then raise exception 'org.repoInvalid';
  end;
  return repository;
end;
$$;

create or replace function public.remove_repository(repository uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
begin
  select org_id into org from public.organization_repositories where id = repository;
  if org is null then raise exception 'org.forbidden'; end if;
  perform public.org_require(org, array['owner']);
  delete from public.organization_repositories where id = repository;
end;
$$;

revoke execute on function public.org_connect_git(uuid, text, text), public.org_disconnect_git(uuid, text),
  public.org_link_repositories(uuid, text, jsonb) from public, anon;
grant execute on function public.org_connect_git(uuid, text, text), public.org_disconnect_git(uuid, text),
  public.org_link_repositories(uuid, text, jsonb) to authenticated;

-- 6. O app recebe ao vivo o que o owner muda no site. O registro inteiro vai
-- no evento para o filtro por organização valer também na remoção.
alter table public.organization_repositories replica identity full;
alter table public.organization_git_connections replica identity full;
-- Cada tabela entra só se ainda não estiver (pode ter sido ligada pelo painel).
do $$
declare
  name text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach name in array array['organization_repositories', 'organization_git_connections'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = name) then
        execute format('alter publication supabase_realtime add table public.%I', name);
      end if;
    end loop;
  end if;
end
$$;
