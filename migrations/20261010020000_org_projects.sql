-- Site 2.11.0: os projetos da organização, na aba Projetos do site. O app
-- deixa de excluir projeto dentro de uma organização; excluir passa a ser só
-- aqui, pelo owner ou por um maintainer, e vale para o projeto de todos os
-- membros que têm aquele repositório.
--
-- Não há tabela de projetos da organização: cada membro tem a própria linha em
-- `projects` (ids diferentes) para o mesmo repositório. Um projeto é da
-- organização quando mora no ambiente dela (`environment_id` = id da
-- organização, o banco que o app abre para ela), não é o projeto geral do chat
-- da organização (`org_id`), o dono ainda é membro e um remote dele
-- (`repo_keys`) casa com um repositório dela. O repositório do projeto é o do
-- primeiro remote que casa (o `origin` vem primeiro), com o cadastro mais
-- antigo desempatando — a regra de `project_repository`, só que entre os
-- repositórios desta organização. O projeto que a pessoa abriu no ambiente
-- pessoal com o mesmo remote é dela e fica de fora: nem aparece na lista, nem
-- é excluído.
--
-- Excluir é a mesma marca que o app grava (`row_deleted_at`, com o
-- `row_updated_at` que nunca recua, senão o `sync_row` a descartaria como
-- escrita atrasada). O `sync_row` dá o `synced_at` novo, o
-- `cascade_row_deletion` desce para chats, turnos, mensagens e notas, e o app
-- de cada membro baixa a exclusão (ele baixa por `synced_at`, no ambiente da
-- organização) e apaga a cópia local na próxima volta da sincronização. O
-- repositório continua na organização: quem quiser clona de novo.

-- Os projetos vivos da organização e o repositório de cada um. Interna: não
-- confere papel; as duas RPCs abaixo conferem.
create function public.org_project_links(org uuid)
returns table (project_id text, user_id uuid, repository_id uuid)
language sql stable security definer set search_path = '' as $$
  select pr.id, pr.user_id, linked.id
  from public.projects pr
  join public.organization_members m on m.org_id = org and m.user_id = pr.user_id
  cross join lateral (
    select r.id
    from jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) with ordinality as k(repo_key, position)
    join public.organization_repositories r on r.org_id = org and r.repo_key = k.repo_key
    order by k.position, r.created_at
    limit 1
  ) linked
  where pr.environment_id = org::text
    and pr.org_id is null
    and pr.row_deleted_at is null;
$$;

-- 1. Um repositório da organização por linha, quando ao menos um membro o tem
-- como projeto: quantos membros, quantos chats vivos nesses projetos e a
-- última atividade (o chat mais recente ou, sem chat, o projeto mais novo).
-- As datas do app são texto ISO; `dashboard_time` as lê e ignora o que não
-- for data. Só owner e maintainer.
create function public.org_projects(org uuid)
returns table (
  repository_id uuid, provider text, path text, repo_key text, web_url text,
  members bigint, chats bigint, last_activity timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  return query
    select r.id, r.provider, r.path, r.repo_key, r.web_url,
           count(distinct l.user_id),
           coalesce(sum(activity.chats), 0)::bigint,
           greatest(max(public.dashboard_time(pr.created_at)), max(activity.touched))
    from public.org_project_links(org) l
    join public.organization_repositories r on r.id = l.repository_id
    join public.projects pr on pr.id = l.project_id
    cross join lateral (
      select count(*) as chats, max(public.dashboard_time(c.updated_at)) as touched
      from public.chats c
      where c.project_id = l.project_id and c.user_id = l.user_id and c.row_deleted_at is null
    ) activity
    group by r.id
    order by r.repo_key;
end;
$$;

-- 2. Exclui o projeto de um repositório da organização no app de todos os
-- membros que o têm (a mesma regra da lista acima). Devolve quantos projetos
-- foram excluídos. O repositório fica na organização. Só owner e maintainer;
-- o papel é conferido antes do repositório, para quem é de fora não descobrir
-- nada.
create function public.delete_org_project(org uuid, repository uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  moment timestamptz := now();
  deleted integer;
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if not exists (select 1 from public.organization_repositories r where r.id = repository and r.org_id = org) then
    raise exception 'org.repoGone';
  end if;
  update public.projects pr
    set row_deleted_at = moment, row_updated_at = greatest(pr.row_updated_at, moment)
    where pr.id in (select l.project_id from public.org_project_links(org) l where l.repository_id = repository)
      and pr.row_deleted_at is null;
  get diagnostics deleted = row_count;
  return deleted;
end;
$$;

revoke execute on function public.org_project_links(uuid) from public, anon, authenticated;
revoke execute on function public.org_projects(uuid), public.delete_org_project(uuid, uuid) from public, anon;
grant execute on function public.org_projects(uuid), public.delete_org_project(uuid, uuid) to authenticated;
