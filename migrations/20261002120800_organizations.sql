-- Organizações: membros com papel, convites e repositórios do GitHub, GitLab e
-- Bitbucket. A leitura é por RLS (só quem é membro vê); toda escrita passa por
-- uma RPC que confere o papel aqui no banco. Um projeto pertence a uma
-- organização quando um remote do git da pasta casa com um repositório dela e
-- o dono do projeto é membro: o app sobe só as chaves dos remotes
-- (`projects.repo_keys`), nunca a pasta.
--
-- As RPCs falham com uma chave estável (`org.forbidden`, `org.lastOwner`...)
-- que a tela traduz.

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  created_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now()
);

create table public.organization_members (
  org_id uuid not null references public.organizations on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role text not null check (role in ('owner', 'maintainer', 'member')),
  joined_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index organization_members_user on public.organization_members (user_id);

create table public.organization_invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  invited_user_id uuid references auth.users on delete cascade,
  email text check (email = lower(email) and email like '%_@_%'),
  role text not null check (role in ('maintainer', 'member')),
  invited_by uuid references auth.users on delete set null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'revoked')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days',
  check ((invited_user_id is null) <> (email is null))
);
create unique index organization_invites_user_pending on public.organization_invites (org_id, invited_user_id) where status = 'pending' and invited_user_id is not null;
create unique index organization_invites_email_pending on public.organization_invites (org_id, email) where status = 'pending' and email is not null;
create index organization_invites_invited on public.organization_invites (invited_user_id);
create index organization_invites_email on public.organization_invites (email);

create table public.organization_repositories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  provider text not null check (provider in ('github', 'gitlab', 'bitbucket')),
  path text not null check (path ~ '^[a-z0-9._-]+(/[a-z0-9._-]+)+$' and path !~ '\.git$'),
  repo_key text generated always as (
    case provider when 'github' then 'github.com/' when 'gitlab' then 'gitlab.com/' else 'bitbucket.org/' end || path
  ) stored,
  added_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, repo_key)
);
create index organization_repositories_key on public.organization_repositories (repo_key);

-- A foto do provedor, para a lista de membros (o perfil completo segue privado).
alter table public.profiles add column avatar_url text check (char_length(avatar_url) <= 500);

create function public.profile_avatar(meta jsonb) returns text language sql immutable set search_path = '' as $$
  select left(coalesce(nullif(meta->>'avatar_url', ''), nullif(meta->>'picture', '')), 500);
$$;

-- O perfil nasce já com a foto; depois, a foto acompanha o provedor.
create or replace function public.profiles_create() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name, username, avatar_url)
  values (new.id, public.profile_name(new.raw_user_meta_data, new.email),
          public.username_free(public.username_base(new.raw_user_meta_data, new.email)),
          public.profile_avatar(new.raw_user_meta_data))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create function public.profiles_avatar() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set avatar_url = public.profile_avatar(new.raw_user_meta_data) where user_id = new.id;
  return new;
end;
$$;
update public.profiles p set avatar_url = public.profile_avatar(u.raw_user_meta_data) from auth.users u where u.id = p.user_id;
create trigger profiles_avatar after update of raw_user_meta_data on auth.users for each row execute function public.profiles_avatar();

-- As chaves dos remotes do projeto (`["github.com/acme/api", ...]`), com o
-- `origin` primeiro. Espelha o SQLite como as outras colunas: texto.
alter table public.projects add column repo_keys text not null default '[]';

-- Papel de quem chama, ou nulo.
create function public.org_role(org uuid) returns text language sql stable security definer set search_path = '' as $$
  select role from public.organization_members where org_id = org and user_id = auth.uid();
$$;

create function public.org_require(org uuid, allowed text[]) returns text language plpgsql stable security definer set search_path = '' as $$
declare
  mine text := public.org_role(org);
begin
  if mine is null or not (mine = any (allowed)) then raise exception 'org.forbidden'; end if;
  return mine;
end;
$$;

-- A organização nunca fica sem owner.
create function public.organization_members_keep_owner() returns trigger language plpgsql set search_path = '' as $$
begin
  -- Excluir a organização ou a conta leva a linha junto: aí não há o que
  -- guardar.
  if not exists (select 1 from public.organizations where id = old.org_id)
     or not exists (select 1 from auth.users where id = old.user_id) then
    return coalesce(new, old);
  end if;
  if old.role = 'owner' and (tg_op = 'DELETE' or new.role <> 'owner')
     and not exists (select 1 from public.organization_members where org_id = old.org_id and role = 'owner' and user_id <> old.user_id) then
    raise exception 'org.lastOwner';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger keep_owner before update of role or delete on public.organization_members
  for each row execute function public.organization_members_keep_owner();

-- O e-mail confirmado de quem chama, para os convites por e-mail.
create function public.my_confirmed_email() returns text language sql stable security definer set search_path = '' as $$
  select lower(email) from auth.users where id = auth.uid() and email_confirmed_at is not null;
$$;

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.organization_invites enable row level security;
alter table public.organization_repositories enable row level security;

create policy "membro lê" on public.organizations for select to authenticated
  using ((select public.org_role(id)) is not null);
create policy "membro lê" on public.organization_members for select to authenticated
  using ((select public.org_role(org_id)) is not null);
create policy "membro lê" on public.organization_repositories for select to authenticated
  using ((select public.org_role(org_id)) is not null);
create policy "quem gere ou foi convidado lê" on public.organization_invites for select to authenticated
  using ((select public.org_role(org_id)) in ('owner', 'maintainer')
         or invited_user_id = (select auth.uid())
         or (email is not null and email = (select public.my_confirmed_email())));

-- Ninguém escreve direto: só pelas RPCs abaixo.
revoke insert, update, delete, truncate on public.organizations, public.organization_members, public.organization_invites, public.organization_repositories from anon, authenticated;
revoke all on public.organizations, public.organization_members, public.organization_invites, public.organization_repositories from anon;

create function public.create_organization(name text, slug text) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
begin
  if auth.uid() is null then raise exception 'org.forbidden'; end if;
  if exists (select 1 from public.organizations o where o.slug = lower(btrim(create_organization.slug))) then raise exception 'org.slugTaken'; end if;
  insert into public.organizations (name, slug, created_by) values (btrim(name), lower(btrim(slug)), auth.uid()) returning id into org;
  insert into public.organization_members (org_id, user_id, role) values (org, auth.uid(), 'owner');
  return org;
end;
$$;

create function public.rename_organization(org uuid, name text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  update public.organizations set name = btrim(rename_organization.name) where id = org;
end;
$$;

create function public.delete_organization(org uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner']);
  delete from public.organizations where id = org;
end;
$$;

-- `target` é um `@usuário` (com ou sem @) ou um e-mail.
create function public.invite_member(org uuid, target text, role text) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  wanted text := lower(btrim(target));
  person uuid;
  invite uuid;
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if role not in ('maintainer', 'member') then raise exception 'org.forbidden'; end if;
  if wanted like '%@%' and wanted !~ '^@' then
    if exists (select 1 from public.organization_members m join auth.users u on u.id = m.user_id where m.org_id = org and lower(u.email) = wanted) then
      raise exception 'org.alreadyMember';
    end if;
    if exists (select 1 from public.organization_invites i where i.org_id = org and i.email = wanted and i.status = 'pending' and i.expires_at > now()) then
      raise exception 'org.alreadyInvited';
    end if;
    -- O pendente vencido sai do caminho do índice único.
    update public.organization_invites i set status = 'revoked' where i.org_id = org and i.email = wanted and i.status = 'pending';
    insert into public.organization_invites (org_id, email, role, invited_by) values (org, wanted, role, auth.uid()) returning id into invite;
  else
    select p.user_id into person from public.profiles p where p.username = ltrim(wanted, '@');
    if person is null then raise exception 'org.userNotFound'; end if;
    if exists (select 1 from public.organization_members m where m.org_id = org and m.user_id = person) then raise exception 'org.alreadyMember'; end if;
    if exists (select 1 from public.organization_invites i where i.org_id = org and i.invited_user_id = person and i.status = 'pending' and i.expires_at > now()) then
      raise exception 'org.alreadyInvited';
    end if;
    update public.organization_invites i set status = 'revoked' where i.org_id = org and i.invited_user_id = person and i.status = 'pending';
    insert into public.organization_invites (org_id, invited_user_id, role, invited_by) values (org, person, role, auth.uid()) returning id into invite;
  end if;
  return invite;
end;
$$;

create function public.revoke_invite(invite uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
begin
  select org_id into org from public.organization_invites where id = invite and status = 'pending';
  if org is null then raise exception 'org.inviteGone'; end if;
  perform public.org_require(org, array['owner', 'maintainer']);
  update public.organization_invites set status = 'revoked' where id = invite;
end;
$$;

-- O convite pendente endereçado a quem chama, já conferido.
create function public.my_invite(invite uuid) returns public.organization_invites language plpgsql stable security definer set search_path = '' as $$
declare
  found_invite public.organization_invites;
begin
  select * into found_invite from public.organization_invites i where i.id = invite and i.status = 'pending';
  if found_invite.id is null then raise exception 'org.inviteGone'; end if;
  if found_invite.invited_user_id is not null and found_invite.invited_user_id <> auth.uid() then raise exception 'org.forbidden'; end if;
  if found_invite.email is not null then
    if not exists (select 1 from auth.users u where u.id = auth.uid() and lower(u.email) = found_invite.email) then raise exception 'org.forbidden'; end if;
    if public.my_confirmed_email() is null then raise exception 'org.emailUnconfirmed'; end if;
  end if;
  if found_invite.expires_at <= now() then raise exception 'org.inviteExpired'; end if;
  return found_invite;
end;
$$;

create function public.accept_invite(invite uuid) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  pending public.organization_invites := public.my_invite(invite);
begin
  insert into public.organization_members (org_id, user_id, role) values (pending.org_id, auth.uid(), pending.role)
    on conflict (org_id, user_id) do nothing;
  update public.organization_invites i set status = 'accepted' where i.id = pending.id;
  return pending.org_id;
end;
$$;

create function public.decline_invite(invite uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  pending public.organization_invites := public.my_invite(invite);
begin
  update public.organization_invites i set status = 'declined' where i.id = pending.id;
end;
$$;

create function public.set_member_role(org uuid, member uuid, role text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner']);
  if role not in ('owner', 'maintainer', 'member') then raise exception 'org.forbidden'; end if;
  update public.organization_members m set role = set_member_role.role where m.org_id = org and m.user_id = member;
  if not found then raise exception 'org.notMember'; end if;
end;
$$;

create function public.remove_member(org uuid, member uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  mine text := public.org_require(org, array['owner', 'maintainer']);
  theirs text;
begin
  select m.role into theirs from public.organization_members m where m.org_id = org and m.user_id = member;
  if theirs is null then raise exception 'org.notMember'; end if;
  if mine = 'maintainer' and theirs <> 'member' then raise exception 'org.forbidden'; end if;
  delete from public.organization_members m where m.org_id = org and m.user_id = member;
end;
$$;

create function public.leave_organization(org uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer', 'member']);
  delete from public.organization_members where org_id = org and user_id = auth.uid();
end;
$$;

create function public.add_repository(org uuid, provider text, path text) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  repository uuid;
begin
  perform public.org_require(org, array['owner', 'maintainer']);
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

create function public.remove_repository(repository uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
begin
  select org_id into org from public.organization_repositories where id = repository;
  if org is null then raise exception 'org.forbidden'; end if;
  perform public.org_require(org, array['owner', 'maintainer']);
  delete from public.organization_repositories where id = repository;
end;
$$;

-- Os membros como a organização os mostra: sem o perfil completo.
create function public.organization_members_view(org uuid)
returns table (user_id uuid, username text, display_name text, avatar_url text, role text, joined_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer', 'member']);
  return query
    select m.user_id, p.username, p.display_name, p.avatar_url, m.role, m.joined_at
    from public.organization_members m join public.profiles p on p.user_id = m.user_id
    where m.org_id = org
    order by case m.role when 'owner' then 0 when 'maintainer' then 1 else 2 end, p.username;
end;
$$;

-- Os convites que chegaram para quem chama, com o nome da organização (que
-- ainda não é dele para ler pela RLS).
create function public.my_invites()
returns table (id uuid, org_id uuid, org_name text, org_slug text, role text, invited_by_username text, created_at timestamptz, expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, o.id, o.name, o.slug, i.role, p.username, i.created_at, i.expires_at
  from public.organization_invites i
  join public.organizations o on o.id = i.org_id
  left join public.profiles p on p.user_id = i.invited_by
  where i.status = 'pending' and i.expires_at > now()
    and (i.invited_user_id = auth.uid() or (i.email is not null and i.email = public.my_confirmed_email()))
  order by i.created_at desc;
$$;

-- Os convites pendentes de uma organização, para quem a gere.
create function public.organization_invites_view(org uuid)
returns table (id uuid, username text, email text, role text, invited_by_username text, created_at timestamptz, expires_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  return query
    select i.id, p.username, i.email, i.role, b.username, i.created_at, i.expires_at
    from public.organization_invites i
    left join public.profiles p on p.user_id = i.invited_user_id
    left join public.profiles b on b.user_id = i.invited_by
    where i.org_id = org and i.status = 'pending'
    order by i.created_at desc;
end;
$$;

-- A busca para convidar: prefixo do `@usuário`, poucos resultados, nada além
-- do que a lista de membros já mostraria.
create function public.find_users(query text)
returns table (user_id uuid, username text, display_name text, avatar_url text)
language plpgsql stable security definer set search_path = '' as $$
declare
  wanted text := ltrim(lower(btrim(query)), '@');
begin
  if auth.uid() is null or char_length(wanted) < 2 then return; end if;
  return query
    select p.user_id, p.username, p.display_name, p.avatar_url
    from public.profiles p
    where p.username like replace(replace(replace(wanted, '\', '\\'), '%', '\%'), '_', '\_') || '%'
    order by char_length(p.username), p.username
    limit 8;
end;
$$;

-- A organização de um projeto: a do primeiro remote que casa com um
-- repositório de uma organização da qual o dono do projeto é membro; o
-- cadastro mais antigo desempata.
create function public.project_organization(project text) returns uuid language sql stable security definer set search_path = '' as $$
  select r.org_id
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

create function public.my_project_organizations()
returns table (project_id text, org_id uuid, org_slug text, org_name text)
language sql stable security definer set search_path = '' as $$
  select pr.id, o.id, o.slug, o.name
  from public.projects pr
  join public.organizations o on o.id = public.project_organization(pr.id)
  where pr.user_id = auth.uid() and pr.row_deleted_at is null;
$$;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'org_require(uuid, text[])', 'my_invite(uuid)', 'organization_members_keep_owner()',
    'profiles_avatar()', 'profile_avatar(jsonb)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
  foreach fn in array array[
    'create_organization(text, text)', 'rename_organization(uuid, text)', 'delete_organization(uuid)',
    'invite_member(uuid, text, text)', 'revoke_invite(uuid)', 'accept_invite(uuid)', 'decline_invite(uuid)',
    'set_member_role(uuid, uuid, text)', 'remove_member(uuid, uuid)', 'leave_organization(uuid)',
    'add_repository(uuid, text, text)', 'remove_repository(uuid)', 'organization_members_view(uuid)',
    'my_invites()', 'organization_invites_view(uuid)', 'find_users(text)', 'project_organization(text)',
    'my_project_organizations()',
    -- As políticas de leitura chamam estas duas com o papel de quem lê; elas
    -- só falam de quem chama.
    'org_role(uuid)', 'my_confirmed_email()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end;
$$;

-- Organizações, convites, repositórios e erros das RPCs, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'nav.organizations', $json$"Organizações"$json$::jsonb),
  ('pt-BR', 'org.list.description', $json$"Equipes que compartilham repositórios. Um projeto entra numa organização quando o git remote dele casa com um repositório dela."$json$::jsonb),
  ('pt-BR', 'org.list.empty', $json$"Você ainda não está em nenhuma organização. Crie uma ou aceite um convite."$json$::jsonb),
  ('pt-BR', 'org.open', $json$"Abrir"$json$::jsonb),
  ('pt-BR', 'org.back', $json$"Todas as organizações"$json$::jsonb),
  ('pt-BR', 'org.count.members', $json${"one": "{count} membro", "other": "{count} membros"}$json$::jsonb),
  ('pt-BR', 'org.count.repositories', $json${"one": "{count} repositório", "other": "{count} repositórios"}$json$::jsonb),
  ('pt-BR', 'org.role.owner', $json$"Owner"$json$::jsonb),
  ('pt-BR', 'org.role.maintainer', $json$"Maintainer"$json$::jsonb),
  ('pt-BR', 'org.role.member', $json$"Membro"$json$::jsonb),
  ('pt-BR', 'org.project.badge', $json$"Faz parte de {name}"$json$::jsonb),
  ('pt-BR', 'org.new.title', $json$"Nova organização"$json$::jsonb),
  ('pt-BR', 'org.new.description', $json$"Você vira owner dela. Convide pessoas e adicione repositórios depois."$json$::jsonb),
  ('pt-BR', 'org.new.create', $json$"Criar organização"$json$::jsonb),
  ('pt-BR', 'org.field.name', $json$"Nome"$json$::jsonb),
  ('pt-BR', 'org.field.slug', $json$"Identificador"$json$::jsonb),
  ('pt-BR', 'org.field.slug.hint', $json$"Único, usado para encontrar a organização."$json$::jsonb),
  ('pt-BR', 'org.field.slug.invalid', $json$"Use de 3 a {max} letras minúsculas, dígitos ou -, começando e terminando com letra ou dígito."$json$::jsonb),
  ('pt-BR', 'org.invites.title', $json$"Convites para você"$json$::jsonb),
  ('pt-BR', 'org.invites.description', $json$"Aceite para entrar. Os convites vencem em 14 dias."$json$::jsonb),
  ('pt-BR', 'org.invites.count', $json${"one": "{count} convite pendente", "other": "{count} convites pendentes"}$json$::jsonb),
  ('pt-BR', 'org.invites.from', $json$"Como {role} · convite de {user} · vence em {date}"$json$::jsonb),
  ('pt-BR', 'org.invites.accept', $json$"Aceitar"$json$::jsonb),
  ('pt-BR', 'org.invites.decline', $json$"Recusar"$json$::jsonb),
  ('pt-BR', 'org.tab.members', $json$"Membros"$json$::jsonb),
  ('pt-BR', 'org.tab.repositories', $json$"Repositórios"$json$::jsonb),
  ('pt-BR', 'org.tab.settings', $json$"Configurações"$json$::jsonb),
  ('pt-BR', 'org.invite.title', $json$"Convidar pessoas"$json$::jsonb),
  ('pt-BR', 'org.invite.description', $json$"Por @usuário ou e-mail. O convite aparece no JayV da pessoa e vence em 14 dias."$json$::jsonb),
  ('pt-BR', 'org.invite.target', $json$"@usuário ou e-mail"$json$::jsonb),
  ('pt-BR', 'org.invite.placeholder', $json$"@usuário ou e-mail"$json$::jsonb),
  ('pt-BR', 'org.invite.role', $json$"Papel"$json$::jsonb),
  ('pt-BR', 'org.invite.send', $json$"Convidar"$json$::jsonb),
  ('pt-BR', 'org.invite.sent', $json$"Convite enviado para {target}."$json$::jsonb),
  ('pt-BR', 'org.invite.hint', $json$"Digite ao menos 2 caracteres do nome de usuário para buscar."$json$::jsonb),
  ('pt-BR', 'org.invite.emailNote', $json$"O JayV não envia e-mail: avise a pessoa. O convite aparece quando ela entrar com este e-mail confirmado."$json$::jsonb),
  ('pt-BR', 'org.invite.expires', $json$"vence em {date}"$json$::jsonb),
  ('pt-BR', 'org.invite.revoke', $json$"Revogar"$json$::jsonb),
  ('pt-BR', 'org.members.title', $json$"Membros"$json$::jsonb),
  ('pt-BR', 'org.members.you', $json$"(você)"$json$::jsonb),
  ('pt-BR', 'org.members.role', $json$"Papel de @{user}"$json$::jsonb),
  ('pt-BR', 'org.members.remove', $json$"Remover"$json$::jsonb),
  ('pt-BR', 'org.members.remove.title', $json$"Remover membro"$json$::jsonb),
  ('pt-BR', 'org.members.remove.description', $json$"@{user} perde o acesso à organização."$json$::jsonb),
  ('pt-BR', 'org.repos.title', $json$"Repositórios"$json$::jsonb),
  ('pt-BR', 'org.repos.description', $json$"GitHub, GitLab e Bitbucket. O projeto local de um membro entra na organização quando um dos git remotes dele casa com um repositório daqui."$json$::jsonb),
  ('pt-BR', 'org.repos.url', $json$"URL do repositório"$json$::jsonb),
  ('pt-BR', 'org.repos.add', $json$"Adicionar"$json$::jsonb),
  ('pt-BR', 'org.repos.hint', $json$"Cole a URL HTTPS ou SSH."$json$::jsonb),
  ('pt-BR', 'org.repos.invalid', $json$"Não é a URL de um repositório do GitHub, GitLab ou Bitbucket."$json$::jsonb),
  ('pt-BR', 'org.repos.empty', $json$"Nenhum repositório ainda."$json$::jsonb),
  ('pt-BR', 'org.repos.remove', $json$"Remover"$json$::jsonb),
  ('pt-BR', 'org.repos.remove.title', $json$"Remover repositório"$json$::jsonb),
  ('pt-BR', 'org.repos.remove.description', $json$"Os projetos que casam com {repo} saem da organização."$json$::jsonb),
  ('pt-BR', 'org.settings.rename', $json$"Renomear"$json$::jsonb),
  ('pt-BR', 'org.settings.renamed', $json$"Organização renomeada."$json$::jsonb),
  ('pt-BR', 'org.settings.leave', $json$"Sair da organização"$json$::jsonb),
  ('pt-BR', 'org.settings.leave.description', $json$"Você perde o acesso aos membros e repositórios. O último owner não pode sair."$json$::jsonb),
  ('pt-BR', 'org.settings.leave.confirm', $json$"Sair de {name}?"$json$::jsonb),
  ('pt-BR', 'org.settings.delete', $json$"Excluir organização"$json$::jsonb),
  ('pt-BR', 'org.settings.delete.description', $json$"Remove membros, convites e repositórios de vez. Os projetos locais continuam."$json$::jsonb),
  ('pt-BR', 'org.settings.delete.type', $json$"Digite {slug} para confirmar"$json$::jsonb),
  ('pt-BR', 'org.forbidden', $json$"Seu papel nesta organização não permite isso."$json$::jsonb),
  ('pt-BR', 'org.lastOwner', $json$"A organização precisa de ao menos um owner. Promova alguém antes."$json$::jsonb),
  ('pt-BR', 'org.slugTaken', $json$"Este identificador já está em uso."$json$::jsonb),
  ('pt-BR', 'org.alreadyMember', $json$"Esta pessoa já é membro."$json$::jsonb),
  ('pt-BR', 'org.alreadyInvited', $json$"Esta pessoa já tem um convite pendente."$json$::jsonb),
  ('pt-BR', 'org.userNotFound', $json$"Nenhum usuário do JayV com este nome de usuário."$json$::jsonb),
  ('pt-BR', 'org.inviteGone', $json$"Este convite não está mais pendente."$json$::jsonb),
  ('pt-BR', 'org.inviteExpired', $json$"Este convite venceu. Peça um novo."$json$::jsonb),
  ('pt-BR', 'org.emailUnconfirmed', $json$"Confirme seu e-mail para aceitar este convite."$json$::jsonb),
  ('pt-BR', 'org.notMember', $json$"Esta pessoa não é membro."$json$::jsonb),
  ('pt-BR', 'org.repoTaken', $json$"Este repositório já está na organização."$json$::jsonb),
  ('pt-BR', 'org.repoInvalid', $json$"Caminho de repositório inválido."$json$::jsonb),
  ('en', 'nav.organizations', $json$"Organizations"$json$::jsonb),
  ('en', 'org.list.description', $json$"Teams that share repositories. A project joins an organization when its git remote matches one of the organization's repositories."$json$::jsonb),
  ('en', 'org.list.empty', $json$"You are not in any organization yet. Create one or accept an invite."$json$::jsonb),
  ('en', 'org.open', $json$"Open"$json$::jsonb),
  ('en', 'org.back', $json$"All organizations"$json$::jsonb),
  ('en', 'org.count.members', $json${"one": "{count} member", "other": "{count} members"}$json$::jsonb),
  ('en', 'org.count.repositories', $json${"one": "{count} repository", "other": "{count} repositories"}$json$::jsonb),
  ('en', 'org.role.owner', $json$"Owner"$json$::jsonb),
  ('en', 'org.role.maintainer', $json$"Maintainer"$json$::jsonb),
  ('en', 'org.role.member', $json$"Member"$json$::jsonb),
  ('en', 'org.project.badge', $json$"Part of {name}"$json$::jsonb),
  ('en', 'org.new.title', $json$"New organization"$json$::jsonb),
  ('en', 'org.new.description', $json$"You become its owner. Invite people and add repositories afterwards."$json$::jsonb),
  ('en', 'org.new.create', $json$"Create organization"$json$::jsonb),
  ('en', 'org.field.name', $json$"Name"$json$::jsonb),
  ('en', 'org.field.slug', $json$"Handle"$json$::jsonb),
  ('en', 'org.field.slug.hint', $json$"Unique, used to find the organization."$json$::jsonb),
  ('en', 'org.field.slug.invalid', $json$"Use 3 to {max} lowercase letters, digits or -, starting and ending with a letter or digit."$json$::jsonb),
  ('en', 'org.invites.title', $json$"Invites for you"$json$::jsonb),
  ('en', 'org.invites.description', $json$"Accept to join. Invites expire after 14 days."$json$::jsonb),
  ('en', 'org.invites.count', $json${"one": "{count} pending invite", "other": "{count} pending invites"}$json$::jsonb),
  ('en', 'org.invites.from', $json$"As {role} · invited by {user} · expires {date}"$json$::jsonb),
  ('en', 'org.invites.accept', $json$"Accept"$json$::jsonb),
  ('en', 'org.invites.decline', $json$"Decline"$json$::jsonb),
  ('en', 'org.tab.members', $json$"Members"$json$::jsonb),
  ('en', 'org.tab.repositories', $json$"Repositories"$json$::jsonb),
  ('en', 'org.tab.settings', $json$"Settings"$json$::jsonb),
  ('en', 'org.invite.title', $json$"Invite people"$json$::jsonb),
  ('en', 'org.invite.description', $json$"By @username or email. The invite shows up in the person's JayV and expires in 14 days."$json$::jsonb),
  ('en', 'org.invite.target', $json$"@username or email"$json$::jsonb),
  ('en', 'org.invite.placeholder', $json$"@username or email"$json$::jsonb),
  ('en', 'org.invite.role', $json$"Role"$json$::jsonb),
  ('en', 'org.invite.send', $json$"Invite"$json$::jsonb),
  ('en', 'org.invite.sent', $json$"Invite sent to {target}."$json$::jsonb),
  ('en', 'org.invite.hint', $json$"Type at least 2 characters of the username to search."$json$::jsonb),
  ('en', 'org.invite.emailNote', $json$"JayV does not send an email: let the person know. The invite appears once they sign in with this confirmed email."$json$::jsonb),
  ('en', 'org.invite.expires', $json$"expires {date}"$json$::jsonb),
  ('en', 'org.invite.revoke', $json$"Revoke"$json$::jsonb),
  ('en', 'org.members.title', $json$"Members"$json$::jsonb),
  ('en', 'org.members.you', $json$"(you)"$json$::jsonb),
  ('en', 'org.members.role', $json$"Role of @{user}"$json$::jsonb),
  ('en', 'org.members.remove', $json$"Remove"$json$::jsonb),
  ('en', 'org.members.remove.title', $json$"Remove member"$json$::jsonb),
  ('en', 'org.members.remove.description', $json$"@{user} will lose access to the organization."$json$::jsonb),
  ('en', 'org.repos.title', $json$"Repositories"$json$::jsonb),
  ('en', 'org.repos.description', $json$"GitHub, GitLab and Bitbucket. A member's local project joins the organization when one of its git remotes matches a repository here."$json$::jsonb),
  ('en', 'org.repos.url', $json$"Repository URL"$json$::jsonb),
  ('en', 'org.repos.add', $json$"Add"$json$::jsonb),
  ('en', 'org.repos.hint', $json$"Paste the HTTPS or SSH URL."$json$::jsonb),
  ('en', 'org.repos.invalid', $json$"Not a GitHub, GitLab or Bitbucket repository URL."$json$::jsonb),
  ('en', 'org.repos.empty', $json$"No repositories yet."$json$::jsonb),
  ('en', 'org.repos.remove', $json$"Remove"$json$::jsonb),
  ('en', 'org.repos.remove.title', $json$"Remove repository"$json$::jsonb),
  ('en', 'org.repos.remove.description', $json$"Projects that match {repo} leave the organization."$json$::jsonb),
  ('en', 'org.settings.rename', $json$"Rename"$json$::jsonb),
  ('en', 'org.settings.renamed', $json$"Organization renamed."$json$::jsonb),
  ('en', 'org.settings.leave', $json$"Leave organization"$json$::jsonb),
  ('en', 'org.settings.leave.description', $json$"You lose access to its members and repositories. The last owner cannot leave."$json$::jsonb),
  ('en', 'org.settings.leave.confirm', $json$"Leave {name}?"$json$::jsonb),
  ('en', 'org.settings.delete', $json$"Delete organization"$json$::jsonb),
  ('en', 'org.settings.delete.description', $json$"Removes members, invites and repositories for good. Local projects are kept."$json$::jsonb),
  ('en', 'org.settings.delete.type', $json$"Type {slug} to confirm"$json$::jsonb),
  ('en', 'org.forbidden', $json$"Your role in this organization does not allow that."$json$::jsonb),
  ('en', 'org.lastOwner', $json$"The organization needs at least one owner. Promote someone first."$json$::jsonb),
  ('en', 'org.slugTaken', $json$"This handle is already taken."$json$::jsonb),
  ('en', 'org.alreadyMember', $json$"This person is already a member."$json$::jsonb),
  ('en', 'org.alreadyInvited', $json$"This person already has a pending invite."$json$::jsonb),
  ('en', 'org.userNotFound', $json$"No JayV user with this username."$json$::jsonb),
  ('en', 'org.inviteGone', $json$"This invite is no longer pending."$json$::jsonb),
  ('en', 'org.inviteExpired', $json$"This invite has expired. Ask for a new one."$json$::jsonb),
  ('en', 'org.emailUnconfirmed', $json$"Confirm your email to accept this invite."$json$::jsonb),
  ('en', 'org.notMember', $json$"This person is not a member."$json$::jsonb),
  ('en', 'org.repoTaken', $json$"This repository is already in the organization."$json$::jsonb),
  ('en', 'org.repoInvalid', $json$"Not a valid repository path."$json$::jsonb),
  ('es', 'nav.organizations', $json$"Organizaciones"$json$::jsonb),
  ('es', 'org.list.description', $json$"Equipos que comparten repositorios. Un proyecto entra en una organización cuando su git remote coincide con uno de sus repositorios."$json$::jsonb),
  ('es', 'org.list.empty', $json$"Aún no estás en ninguna organización. Crea una o acepta una invitación."$json$::jsonb),
  ('es', 'org.open', $json$"Abrir"$json$::jsonb),
  ('es', 'org.back', $json$"Todas las organizaciones"$json$::jsonb),
  ('es', 'org.count.members', $json${"one": "{count} miembro", "other": "{count} miembros"}$json$::jsonb),
  ('es', 'org.count.repositories', $json${"one": "{count} repositorio", "other": "{count} repositorios"}$json$::jsonb),
  ('es', 'org.role.owner', $json$"Owner"$json$::jsonb),
  ('es', 'org.role.maintainer', $json$"Maintainer"$json$::jsonb),
  ('es', 'org.role.member', $json$"Miembro"$json$::jsonb),
  ('es', 'org.project.badge', $json$"Forma parte de {name}"$json$::jsonb),
  ('es', 'org.new.title', $json$"Nueva organización"$json$::jsonb),
  ('es', 'org.new.description', $json$"Te conviertes en su owner. Invita a personas y añade repositorios después."$json$::jsonb),
  ('es', 'org.new.create', $json$"Crear organización"$json$::jsonb),
  ('es', 'org.field.name', $json$"Nombre"$json$::jsonb),
  ('es', 'org.field.slug', $json$"Identificador"$json$::jsonb),
  ('es', 'org.field.slug.hint', $json$"Único, sirve para encontrar la organización."$json$::jsonb),
  ('es', 'org.field.slug.invalid', $json$"Usa de 3 a {max} minúsculas, dígitos o -, empezando y terminando con letra o dígito."$json$::jsonb),
  ('es', 'org.invites.title', $json$"Invitaciones para ti"$json$::jsonb),
  ('es', 'org.invites.description', $json$"Acepta para unirte. Las invitaciones caducan a los 14 días."$json$::jsonb),
  ('es', 'org.invites.count', $json${"one": "{count} invitación pendiente", "other": "{count} invitaciones pendientes"}$json$::jsonb),
  ('es', 'org.invites.from', $json$"Como {role} · invitación de {user} · caduca el {date}"$json$::jsonb),
  ('es', 'org.invites.accept', $json$"Aceptar"$json$::jsonb),
  ('es', 'org.invites.decline', $json$"Rechazar"$json$::jsonb),
  ('es', 'org.tab.members', $json$"Miembros"$json$::jsonb),
  ('es', 'org.tab.repositories', $json$"Repositorios"$json$::jsonb),
  ('es', 'org.tab.settings', $json$"Configuración"$json$::jsonb),
  ('es', 'org.invite.title', $json$"Invitar personas"$json$::jsonb),
  ('es', 'org.invite.description', $json$"Por @usuario o correo. La invitación aparece en el JayV de la persona y caduca en 14 días."$json$::jsonb),
  ('es', 'org.invite.target', $json$"@usuario o correo"$json$::jsonb),
  ('es', 'org.invite.placeholder', $json$"@usuario o correo"$json$::jsonb),
  ('es', 'org.invite.role', $json$"Rol"$json$::jsonb),
  ('es', 'org.invite.send', $json$"Invitar"$json$::jsonb),
  ('es', 'org.invite.sent', $json$"Invitación enviada a {target}."$json$::jsonb),
  ('es', 'org.invite.hint', $json$"Escribe al menos 2 caracteres del nombre de usuario para buscar."$json$::jsonb),
  ('es', 'org.invite.emailNote', $json$"JayV no envía correo: avisa a la persona. La invitación aparece cuando entre con este correo confirmado."$json$::jsonb),
  ('es', 'org.invite.expires', $json$"caduca el {date}"$json$::jsonb),
  ('es', 'org.invite.revoke', $json$"Revocar"$json$::jsonb),
  ('es', 'org.members.title', $json$"Miembros"$json$::jsonb),
  ('es', 'org.members.you', $json$"(tú)"$json$::jsonb),
  ('es', 'org.members.role', $json$"Rol de @{user}"$json$::jsonb),
  ('es', 'org.members.remove', $json$"Quitar"$json$::jsonb),
  ('es', 'org.members.remove.title', $json$"Quitar miembro"$json$::jsonb),
  ('es', 'org.members.remove.description', $json$"@{user} perderá el acceso a la organización."$json$::jsonb),
  ('es', 'org.repos.title', $json$"Repositorios"$json$::jsonb),
  ('es', 'org.repos.description', $json$"GitHub, GitLab y Bitbucket. El proyecto local de un miembro entra en la organización cuando uno de sus git remotes coincide con un repositorio de aquí."$json$::jsonb),
  ('es', 'org.repos.url', $json$"URL del repositorio"$json$::jsonb),
  ('es', 'org.repos.add', $json$"Añadir"$json$::jsonb),
  ('es', 'org.repos.hint', $json$"Pega la URL HTTPS o SSH."$json$::jsonb),
  ('es', 'org.repos.invalid', $json$"No es la URL de un repositorio de GitHub, GitLab o Bitbucket."$json$::jsonb),
  ('es', 'org.repos.empty', $json$"Aún no hay repositorios."$json$::jsonb),
  ('es', 'org.repos.remove', $json$"Quitar"$json$::jsonb),
  ('es', 'org.repos.remove.title', $json$"Quitar repositorio"$json$::jsonb),
  ('es', 'org.repos.remove.description', $json$"Los proyectos que coinciden con {repo} salen de la organización."$json$::jsonb),
  ('es', 'org.settings.rename', $json$"Renombrar"$json$::jsonb),
  ('es', 'org.settings.renamed', $json$"Organización renombrada."$json$::jsonb),
  ('es', 'org.settings.leave', $json$"Salir de la organización"$json$::jsonb),
  ('es', 'org.settings.leave.description', $json$"Pierdes el acceso a sus miembros y repositorios. El último owner no puede salir."$json$::jsonb),
  ('es', 'org.settings.leave.confirm', $json$"¿Salir de {name}?"$json$::jsonb),
  ('es', 'org.settings.delete', $json$"Eliminar organización"$json$::jsonb),
  ('es', 'org.settings.delete.description', $json$"Elimina miembros, invitaciones y repositorios para siempre. Los proyectos locales se mantienen."$json$::jsonb),
  ('es', 'org.settings.delete.type', $json$"Escribe {slug} para confirmar"$json$::jsonb),
  ('es', 'org.forbidden', $json$"Tu rol en esta organización no lo permite."$json$::jsonb),
  ('es', 'org.lastOwner', $json$"La organización necesita al menos un owner. Promueve a alguien antes."$json$::jsonb),
  ('es', 'org.slugTaken', $json$"Este identificador ya está en uso."$json$::jsonb),
  ('es', 'org.alreadyMember', $json$"Esta persona ya es miembro."$json$::jsonb),
  ('es', 'org.alreadyInvited', $json$"Esta persona ya tiene una invitación pendiente."$json$::jsonb),
  ('es', 'org.userNotFound', $json$"Ningún usuario de JayV con este nombre de usuario."$json$::jsonb),
  ('es', 'org.inviteGone', $json$"Esta invitación ya no está pendiente."$json$::jsonb),
  ('es', 'org.inviteExpired', $json$"Esta invitación caducó. Pide una nueva."$json$::jsonb),
  ('es', 'org.emailUnconfirmed', $json$"Confirma tu correo para aceptar esta invitación."$json$::jsonb),
  ('es', 'org.notMember', $json$"Esta persona no es miembro."$json$::jsonb),
  ('es', 'org.repoTaken', $json$"Este repositorio ya está en la organización."$json$::jsonb),
  ('es', 'org.repoInvalid', $json$"Ruta de repositorio no válida."$json$::jsonb),
  ('zh-CN', 'nav.organizations', $json$"组织"$json$::jsonb),
  ('zh-CN', 'org.list.description', $json$"共享仓库的团队。项目的 git remote 与组织的某个仓库匹配时，项目即归属该组织。"$json$::jsonb),
  ('zh-CN', 'org.list.empty', $json$"你还没有加入任何组织。创建一个或接受邀请。"$json$::jsonb),
  ('zh-CN', 'org.open', $json$"打开"$json$::jsonb),
  ('zh-CN', 'org.back', $json$"全部组织"$json$::jsonb),
  ('zh-CN', 'org.count.members', $json${"other": "{count} 名成员"}$json$::jsonb),
  ('zh-CN', 'org.count.repositories', $json${"other": "{count} 个仓库"}$json$::jsonb),
  ('zh-CN', 'org.role.owner', $json$"所有者"$json$::jsonb),
  ('zh-CN', 'org.role.maintainer', $json$"维护者"$json$::jsonb),
  ('zh-CN', 'org.role.member', $json$"成员"$json$::jsonb),
  ('zh-CN', 'org.project.badge', $json$"属于 {name}"$json$::jsonb),
  ('zh-CN', 'org.new.title', $json$"新建组织"$json$::jsonb),
  ('zh-CN', 'org.new.description', $json$"你将成为所有者。之后再邀请成员并添加仓库。"$json$::jsonb),
  ('zh-CN', 'org.new.create', $json$"创建组织"$json$::jsonb),
  ('zh-CN', 'org.field.name', $json$"名称"$json$::jsonb),
  ('zh-CN', 'org.field.slug', $json$"标识"$json$::jsonb),
  ('zh-CN', 'org.field.slug.hint', $json$"唯一，用于查找组织。"$json$::jsonb),
  ('zh-CN', 'org.field.slug.invalid', $json$"请使用 3 到 {max} 个小写字母、数字或 -，以字母或数字开头和结尾。"$json$::jsonb),
  ('zh-CN', 'org.invites.title', $json$"给你的邀请"$json$::jsonb),
  ('zh-CN', 'org.invites.description', $json$"接受即可加入。邀请 14 天后过期。"$json$::jsonb),
  ('zh-CN', 'org.invites.count', $json${"other": "{count} 个待处理邀请"}$json$::jsonb),
  ('zh-CN', 'org.invites.from', $json$"角色：{role} · 邀请人 {user} · {date} 过期"$json$::jsonb),
  ('zh-CN', 'org.invites.accept', $json$"接受"$json$::jsonb),
  ('zh-CN', 'org.invites.decline', $json$"拒绝"$json$::jsonb),
  ('zh-CN', 'org.tab.members', $json$"成员"$json$::jsonb),
  ('zh-CN', 'org.tab.repositories', $json$"仓库"$json$::jsonb),
  ('zh-CN', 'org.tab.settings', $json$"设置"$json$::jsonb),
  ('zh-CN', 'org.invite.title', $json$"邀请成员"$json$::jsonb),
  ('zh-CN', 'org.invite.description', $json$"通过 @用户名 或邮箱邀请。邀请会出现在对方的 JayV 中，14 天后过期。"$json$::jsonb),
  ('zh-CN', 'org.invite.target', $json$"@用户名 或邮箱"$json$::jsonb),
  ('zh-CN', 'org.invite.placeholder', $json$"@用户名 或邮箱"$json$::jsonb),
  ('zh-CN', 'org.invite.role', $json$"角色"$json$::jsonb),
  ('zh-CN', 'org.invite.send', $json$"邀请"$json$::jsonb),
  ('zh-CN', 'org.invite.sent', $json$"已向 {target} 发送邀请。"$json$::jsonb),
  ('zh-CN', 'org.invite.hint', $json$"输入用户名的至少 2 个字符即可搜索。"$json$::jsonb),
  ('zh-CN', 'org.invite.emailNote', $json$"JayV 不会发送邮件，请自行通知对方。对方用此已验证邮箱登录后会看到邀请。"$json$::jsonb),
  ('zh-CN', 'org.invite.expires', $json$"{date} 过期"$json$::jsonb),
  ('zh-CN', 'org.invite.revoke', $json$"撤销"$json$::jsonb),
  ('zh-CN', 'org.members.title', $json$"成员"$json$::jsonb),
  ('zh-CN', 'org.members.you', $json$"（你）"$json$::jsonb),
  ('zh-CN', 'org.members.role', $json$"@{user} 的角色"$json$::jsonb),
  ('zh-CN', 'org.members.remove', $json$"移除"$json$::jsonb),
  ('zh-CN', 'org.members.remove.title', $json$"移除成员"$json$::jsonb),
  ('zh-CN', 'org.members.remove.description', $json$"@{user} 将失去对该组织的访问权限。"$json$::jsonb),
  ('zh-CN', 'org.repos.title', $json$"仓库"$json$::jsonb),
  ('zh-CN', 'org.repos.description', $json$"支持 GitHub、GitLab 和 Bitbucket。成员的本地项目只要有一个 git remote 与这里的仓库匹配，就归属该组织。"$json$::jsonb),
  ('zh-CN', 'org.repos.url', $json$"仓库 URL"$json$::jsonb),
  ('zh-CN', 'org.repos.add', $json$"添加"$json$::jsonb),
  ('zh-CN', 'org.repos.hint', $json$"粘贴 HTTPS 或 SSH URL。"$json$::jsonb),
  ('zh-CN', 'org.repos.invalid', $json$"这不是 GitHub、GitLab 或 Bitbucket 的仓库 URL。"$json$::jsonb),
  ('zh-CN', 'org.repos.empty', $json$"还没有仓库。"$json$::jsonb),
  ('zh-CN', 'org.repos.remove', $json$"移除"$json$::jsonb),
  ('zh-CN', 'org.repos.remove.title', $json$"移除仓库"$json$::jsonb),
  ('zh-CN', 'org.repos.remove.description', $json$"与 {repo} 匹配的项目将离开该组织。"$json$::jsonb),
  ('zh-CN', 'org.settings.rename', $json$"重命名"$json$::jsonb),
  ('zh-CN', 'org.settings.renamed', $json$"组织已重命名。"$json$::jsonb),
  ('zh-CN', 'org.settings.leave', $json$"退出组织"$json$::jsonb),
  ('zh-CN', 'org.settings.leave.description', $json$"你将无法再访问其成员和仓库。最后一位所有者不能退出。"$json$::jsonb),
  ('zh-CN', 'org.settings.leave.confirm', $json$"退出 {name}？"$json$::jsonb),
  ('zh-CN', 'org.settings.delete', $json$"删除组织"$json$::jsonb),
  ('zh-CN', 'org.settings.delete.description', $json$"永久删除成员、邀请和仓库。本地项目会保留。"$json$::jsonb),
  ('zh-CN', 'org.settings.delete.type', $json$"输入 {slug} 以确认"$json$::jsonb),
  ('zh-CN', 'org.forbidden', $json$"你在该组织中的角色不允许此操作。"$json$::jsonb),
  ('zh-CN', 'org.lastOwner', $json$"组织至少需要一位所有者。请先提升其他人。"$json$::jsonb),
  ('zh-CN', 'org.slugTaken', $json$"该标识已被占用。"$json$::jsonb),
  ('zh-CN', 'org.alreadyMember', $json$"此人已是成员。"$json$::jsonb),
  ('zh-CN', 'org.alreadyInvited', $json$"此人已有待处理的邀请。"$json$::jsonb),
  ('zh-CN', 'org.userNotFound', $json$"没有使用该用户名的 JayV 用户。"$json$::jsonb),
  ('zh-CN', 'org.inviteGone', $json$"该邀请已不再待处理。"$json$::jsonb),
  ('zh-CN', 'org.inviteExpired', $json$"该邀请已过期，请重新索取。"$json$::jsonb),
  ('zh-CN', 'org.emailUnconfirmed', $json$"请先验证邮箱再接受此邀请。"$json$::jsonb),
  ('zh-CN', 'org.notMember', $json$"此人不是成员。"$json$::jsonb),
  ('zh-CN', 'org.repoTaken', $json$"该仓库已在组织中。"$json$::jsonb),
  ('zh-CN', 'org.repoInvalid', $json$"仓库路径无效。"$json$::jsonb),
  ('hi', 'nav.organizations', $json$"संगठन"$json$::jsonb),
  ('hi', 'org.list.description', $json$"रिपॉज़िटरी साझा करने वाली टीमें। जब किसी प्रोजेक्ट का git remote संगठन की किसी रिपॉज़िटरी से मेल खाता है, तो वह उसमें शामिल हो जाता है।"$json$::jsonb),
  ('hi', 'org.list.empty', $json$"आप अभी किसी संगठन में नहीं हैं। एक बनाएँ या कोई निमंत्रण स्वीकार करें।"$json$::jsonb),
  ('hi', 'org.open', $json$"खोलें"$json$::jsonb),
  ('hi', 'org.back', $json$"सभी संगठन"$json$::jsonb),
  ('hi', 'org.count.members', $json${"one": "{count} सदस्य", "other": "{count} सदस्य"}$json$::jsonb),
  ('hi', 'org.count.repositories', $json${"one": "{count} रिपॉज़िटरी", "other": "{count} रिपॉज़िटरी"}$json$::jsonb),
  ('hi', 'org.role.owner', $json$"ओनर"$json$::jsonb),
  ('hi', 'org.role.maintainer', $json$"मेंटेनर"$json$::jsonb),
  ('hi', 'org.role.member', $json$"सदस्य"$json$::jsonb),
  ('hi', 'org.project.badge', $json$"{name} का हिस्सा"$json$::jsonb),
  ('hi', 'org.new.title', $json$"नया संगठन"$json$::jsonb),
  ('hi', 'org.new.description', $json$"आप इसके ओनर बनेंगे। बाद में लोगों को आमंत्रित करें और रिपॉज़िटरी जोड़ें।"$json$::jsonb),
  ('hi', 'org.new.create', $json$"संगठन बनाएँ"$json$::jsonb),
  ('hi', 'org.field.name', $json$"नाम"$json$::jsonb),
  ('hi', 'org.field.slug', $json$"पहचान"$json$::jsonb),
  ('hi', 'org.field.slug.hint', $json$"अनोखा, संगठन ढूँढने के लिए।"$json$::jsonb),
  ('hi', 'org.field.slug.invalid', $json$"3 से {max} छोटे अक्षर, अंक या - इस्तेमाल करें, शुरू और अंत अक्षर या अंक से हो।"$json$::jsonb),
  ('hi', 'org.invites.title', $json$"आपके लिए निमंत्रण"$json$::jsonb),
  ('hi', 'org.invites.description', $json$"शामिल होने के लिए स्वीकार करें। निमंत्रण 14 दिन बाद समाप्त हो जाते हैं।"$json$::jsonb),
  ('hi', 'org.invites.count', $json${"one": "{count} लंबित निमंत्रण", "other": "{count} लंबित निमंत्रण"}$json$::jsonb),
  ('hi', 'org.invites.from', $json$"{role} के रूप में · {user} ने आमंत्रित किया · {date} तक"$json$::jsonb),
  ('hi', 'org.invites.accept', $json$"स्वीकार करें"$json$::jsonb),
  ('hi', 'org.invites.decline', $json$"अस्वीकार करें"$json$::jsonb),
  ('hi', 'org.tab.members', $json$"सदस्य"$json$::jsonb),
  ('hi', 'org.tab.repositories', $json$"रिपॉज़िटरी"$json$::jsonb),
  ('hi', 'org.tab.settings', $json$"सेटिंग्स"$json$::jsonb),
  ('hi', 'org.invite.title', $json$"लोगों को आमंत्रित करें"$json$::jsonb),
  ('hi', 'org.invite.description', $json$"@उपयोगकर्ता नाम या ईमेल से। निमंत्रण व्यक्ति के JayV में दिखता है और 14 दिन में समाप्त होता है।"$json$::jsonb),
  ('hi', 'org.invite.target', $json$"@उपयोगकर्ता नाम या ईमेल"$json$::jsonb),
  ('hi', 'org.invite.placeholder', $json$"@उपयोगकर्ता नाम या ईमेल"$json$::jsonb),
  ('hi', 'org.invite.role', $json$"भूमिका"$json$::jsonb),
  ('hi', 'org.invite.send', $json$"आमंत्रित करें"$json$::jsonb),
  ('hi', 'org.invite.sent', $json$"{target} को निमंत्रण भेजा गया।"$json$::jsonb),
  ('hi', 'org.invite.hint', $json$"खोजने के लिए उपयोगकर्ता नाम के कम से कम 2 अक्षर लिखें।"$json$::jsonb),
  ('hi', 'org.invite.emailNote', $json$"JayV ईमेल नहीं भेजता: व्यक्ति को खुद बताएँ। इस पुष्ट ईमेल से साइन इन करने पर निमंत्रण दिखेगा।"$json$::jsonb),
  ('hi', 'org.invite.expires', $json$"{date} तक"$json$::jsonb),
  ('hi', 'org.invite.revoke', $json$"रद्द करें"$json$::jsonb),
  ('hi', 'org.members.title', $json$"सदस्य"$json$::jsonb),
  ('hi', 'org.members.you', $json$"(आप)"$json$::jsonb),
  ('hi', 'org.members.role', $json$"@{user} की भूमिका"$json$::jsonb),
  ('hi', 'org.members.remove', $json$"हटाएँ"$json$::jsonb),
  ('hi', 'org.members.remove.title', $json$"सदस्य हटाएँ"$json$::jsonb),
  ('hi', 'org.members.remove.description', $json$"@{user} संगठन तक पहुँच खो देगा।"$json$::jsonb),
  ('hi', 'org.repos.title', $json$"रिपॉज़िटरी"$json$::jsonb),
  ('hi', 'org.repos.description', $json$"GitHub, GitLab और Bitbucket। किसी सदस्य का लोकल प्रोजेक्ट तब संगठन में आता है जब उसका कोई git remote यहाँ की किसी रिपॉज़िटरी से मेल खाता है।"$json$::jsonb),
  ('hi', 'org.repos.url', $json$"रिपॉज़िटरी URL"$json$::jsonb),
  ('hi', 'org.repos.add', $json$"जोड़ें"$json$::jsonb),
  ('hi', 'org.repos.hint', $json$"HTTPS या SSH URL चिपकाएँ।"$json$::jsonb),
  ('hi', 'org.repos.invalid', $json$"यह GitHub, GitLab या Bitbucket रिपॉज़िटरी का URL नहीं है।"$json$::jsonb),
  ('hi', 'org.repos.empty', $json$"अभी कोई रिपॉज़िटरी नहीं।"$json$::jsonb),
  ('hi', 'org.repos.remove', $json$"हटाएँ"$json$::jsonb),
  ('hi', 'org.repos.remove.title', $json$"रिपॉज़िटरी हटाएँ"$json$::jsonb),
  ('hi', 'org.repos.remove.description', $json$"{repo} से मेल खाने वाले प्रोजेक्ट संगठन से बाहर हो जाएँगे।"$json$::jsonb),
  ('hi', 'org.settings.rename', $json$"नाम बदलें"$json$::jsonb),
  ('hi', 'org.settings.renamed', $json$"संगठन का नाम बदल दिया गया।"$json$::jsonb),
  ('hi', 'org.settings.leave', $json$"संगठन छोड़ें"$json$::jsonb),
  ('hi', 'org.settings.leave.description', $json$"आप इसके सदस्यों और रिपॉज़िटरी तक पहुँच खो देंगे। आखिरी ओनर नहीं छोड़ सकता।"$json$::jsonb),
  ('hi', 'org.settings.leave.confirm', $json$"{name} छोड़ें?"$json$::jsonb),
  ('hi', 'org.settings.delete', $json$"संगठन हटाएँ"$json$::jsonb),
  ('hi', 'org.settings.delete.description', $json$"सदस्य, निमंत्रण और रिपॉज़िटरी हमेशा के लिए हटा देता है। लोकल प्रोजेक्ट बने रहते हैं।"$json$::jsonb),
  ('hi', 'org.settings.delete.type', $json$"पुष्टि के लिए {slug} लिखें"$json$::jsonb),
  ('hi', 'org.forbidden', $json$"इस संगठन में आपकी भूमिका इसकी अनुमति नहीं देती।"$json$::jsonb),
  ('hi', 'org.lastOwner', $json$"संगठन में कम से कम एक ओनर ज़रूरी है। पहले किसी को प्रमोट करें।"$json$::jsonb),
  ('hi', 'org.slugTaken', $json$"यह पहचान पहले से ली जा चुकी है।"$json$::jsonb),
  ('hi', 'org.alreadyMember', $json$"यह व्यक्ति पहले से सदस्य है।"$json$::jsonb),
  ('hi', 'org.alreadyInvited', $json$"इस व्यक्ति का निमंत्रण पहले से लंबित है।"$json$::jsonb),
  ('hi', 'org.userNotFound', $json$"इस उपयोगकर्ता नाम का कोई JayV उपयोगकर्ता नहीं है।"$json$::jsonb),
  ('hi', 'org.inviteGone', $json$"यह निमंत्रण अब लंबित नहीं है।"$json$::jsonb),
  ('hi', 'org.inviteExpired', $json$"यह निमंत्रण समाप्त हो गया है। नया माँगें।"$json$::jsonb),
  ('hi', 'org.emailUnconfirmed', $json$"यह निमंत्रण स्वीकार करने के लिए अपना ईमेल पुष्टि करें।"$json$::jsonb),
  ('hi', 'org.notMember', $json$"यह व्यक्ति सदस्य नहीं है।"$json$::jsonb),
  ('hi', 'org.repoTaken', $json$"यह रिपॉज़िटरी पहले से संगठन में है।"$json$::jsonb),
  ('hi', 'org.repoInvalid', $json$"रिपॉज़िटरी पथ अमान्य है।"$json$::jsonb),
  ('ar', 'nav.organizations', $json$"المؤسسات"$json$::jsonb),
  ('ar', 'org.list.description', $json$"فرق تتشارك المستودعات. ينضم المشروع إلى مؤسسة عندما يطابق git remote الخاص به أحد مستودعاتها."$json$::jsonb),
  ('ar', 'org.list.empty', $json$"لست في أي مؤسسة بعد. أنشئ واحدة أو اقبل دعوة."$json$::jsonb),
  ('ar', 'org.open', $json$"فتح"$json$::jsonb),
  ('ar', 'org.back', $json$"كل المؤسسات"$json$::jsonb),
  ('ar', 'org.count.members', $json${"zero": "لا أعضاء", "one": "عضو واحد", "two": "عضوان", "few": "{count} أعضاء", "many": "{count} عضوًا", "other": "{count} عضو"}$json$::jsonb),
  ('ar', 'org.count.repositories', $json${"zero": "لا مستودعات", "one": "مستودع واحد", "two": "مستودعان", "few": "{count} مستودعات", "many": "{count} مستودعًا", "other": "{count} مستودع"}$json$::jsonb),
  ('ar', 'org.role.owner', $json$"المالك"$json$::jsonb),
  ('ar', 'org.role.maintainer', $json$"المشرف"$json$::jsonb),
  ('ar', 'org.role.member', $json$"عضو"$json$::jsonb),
  ('ar', 'org.project.badge', $json$"جزء من {name}"$json$::jsonb),
  ('ar', 'org.new.title', $json$"مؤسسة جديدة"$json$::jsonb),
  ('ar', 'org.new.description', $json$"ستصبح مالكها. ادعُ الأشخاص وأضف المستودعات لاحقًا."$json$::jsonb),
  ('ar', 'org.new.create', $json$"إنشاء المؤسسة"$json$::jsonb),
  ('ar', 'org.field.name', $json$"الاسم"$json$::jsonb),
  ('ar', 'org.field.slug', $json$"المعرّف"$json$::jsonb),
  ('ar', 'org.field.slug.hint', $json$"فريد، يُستخدم للعثور على المؤسسة."$json$::jsonb),
  ('ar', 'org.field.slug.invalid', $json$"استخدم من 3 إلى {max} من الأحرف الصغيرة أو الأرقام أو -، مع البدء والانتهاء بحرف أو رقم."$json$::jsonb),
  ('ar', 'org.invites.title', $json$"دعوات لك"$json$::jsonb),
  ('ar', 'org.invites.description', $json$"اقبل للانضمام. تنتهي الدعوات بعد 14 يومًا."$json$::jsonb),
  ('ar', 'org.invites.count', $json${"zero": "لا دعوات معلّقة", "one": "دعوة معلّقة واحدة", "two": "دعوتان معلّقتان", "few": "{count} دعوات معلّقة", "many": "{count} دعوة معلّقة", "other": "{count} دعوة معلّقة"}$json$::jsonb),
  ('ar', 'org.invites.from', $json$"بصفة {role} · دعاك {user} · تنتهي في {date}"$json$::jsonb),
  ('ar', 'org.invites.accept', $json$"قبول"$json$::jsonb),
  ('ar', 'org.invites.decline', $json$"رفض"$json$::jsonb),
  ('ar', 'org.tab.members', $json$"الأعضاء"$json$::jsonb),
  ('ar', 'org.tab.repositories', $json$"المستودعات"$json$::jsonb),
  ('ar', 'org.tab.settings', $json$"الإعدادات"$json$::jsonb),
  ('ar', 'org.invite.title', $json$"دعوة أشخاص"$json$::jsonb),
  ('ar', 'org.invite.description', $json$"عبر @اسم المستخدم أو البريد. تظهر الدعوة في JayV لدى الشخص وتنتهي بعد 14 يومًا."$json$::jsonb),
  ('ar', 'org.invite.target', $json$"@اسم المستخدم أو البريد"$json$::jsonb),
  ('ar', 'org.invite.placeholder', $json$"@اسم المستخدم أو البريد"$json$::jsonb),
  ('ar', 'org.invite.role', $json$"الدور"$json$::jsonb),
  ('ar', 'org.invite.send', $json$"دعوة"$json$::jsonb),
  ('ar', 'org.invite.sent', $json$"أُرسلت الدعوة إلى {target}."$json$::jsonb),
  ('ar', 'org.invite.hint', $json$"اكتب حرفين على الأقل من اسم المستخدم للبحث."$json$::jsonb),
  ('ar', 'org.invite.emailNote', $json$"لا يرسل JayV بريدًا: أبلغ الشخص بنفسك. تظهر الدعوة عندما يسجّل الدخول بهذا البريد المؤكد."$json$::jsonb),
  ('ar', 'org.invite.expires', $json$"تنتهي في {date}"$json$::jsonb),
  ('ar', 'org.invite.revoke', $json$"إلغاء"$json$::jsonb),
  ('ar', 'org.members.title', $json$"الأعضاء"$json$::jsonb),
  ('ar', 'org.members.you', $json$"(أنت)"$json$::jsonb),
  ('ar', 'org.members.role', $json$"دور @{user}"$json$::jsonb),
  ('ar', 'org.members.remove', $json$"إزالة"$json$::jsonb),
  ('ar', 'org.members.remove.title', $json$"إزالة العضو"$json$::jsonb),
  ('ar', 'org.members.remove.description', $json$"سيفقد @{user} الوصول إلى المؤسسة."$json$::jsonb),
  ('ar', 'org.repos.title', $json$"المستودعات"$json$::jsonb),
  ('ar', 'org.repos.description', $json$"GitHub وGitLab وBitbucket. ينضم مشروع العضو المحلي إلى المؤسسة عندما يطابق أحد git remotes الخاصة به مستودعًا هنا."$json$::jsonb),
  ('ar', 'org.repos.url', $json$"رابط المستودع"$json$::jsonb),
  ('ar', 'org.repos.add', $json$"إضافة"$json$::jsonb),
  ('ar', 'org.repos.hint', $json$"الصق رابط HTTPS أو SSH."$json$::jsonb),
  ('ar', 'org.repos.invalid', $json$"ليس رابط مستودع على GitHub أو GitLab أو Bitbucket."$json$::jsonb),
  ('ar', 'org.repos.empty', $json$"لا توجد مستودعات بعد."$json$::jsonb),
  ('ar', 'org.repos.remove', $json$"إزالة"$json$::jsonb),
  ('ar', 'org.repos.remove.title', $json$"إزالة المستودع"$json$::jsonb),
  ('ar', 'org.repos.remove.description', $json$"المشاريع المطابقة لـ {repo} ستخرج من المؤسسة."$json$::jsonb),
  ('ar', 'org.settings.rename', $json$"إعادة التسمية"$json$::jsonb),
  ('ar', 'org.settings.renamed', $json$"تمت إعادة تسمية المؤسسة."$json$::jsonb),
  ('ar', 'org.settings.leave', $json$"مغادرة المؤسسة"$json$::jsonb),
  ('ar', 'org.settings.leave.description', $json$"ستفقد الوصول إلى أعضائها ومستودعاتها. لا يمكن لآخر مالك المغادرة."$json$::jsonb),
  ('ar', 'org.settings.leave.confirm', $json$"مغادرة {name}؟"$json$::jsonb),
  ('ar', 'org.settings.delete', $json$"حذف المؤسسة"$json$::jsonb),
  ('ar', 'org.settings.delete.description', $json$"يحذف الأعضاء والدعوات والمستودعات نهائيًا. تبقى المشاريع المحلية."$json$::jsonb),
  ('ar', 'org.settings.delete.type', $json$"اكتب {slug} للتأكيد"$json$::jsonb),
  ('ar', 'org.forbidden', $json$"دورك في هذه المؤسسة لا يسمح بذلك."$json$::jsonb),
  ('ar', 'org.lastOwner', $json$"تحتاج المؤسسة إلى مالك واحد على الأقل. رقِّ شخصًا أولًا."$json$::jsonb),
  ('ar', 'org.slugTaken', $json$"هذا المعرّف مستخدم بالفعل."$json$::jsonb),
  ('ar', 'org.alreadyMember', $json$"هذا الشخص عضو بالفعل."$json$::jsonb),
  ('ar', 'org.alreadyInvited', $json$"لدى هذا الشخص دعوة معلّقة بالفعل."$json$::jsonb),
  ('ar', 'org.userNotFound', $json$"لا يوجد مستخدم JayV بهذا الاسم."$json$::jsonb),
  ('ar', 'org.inviteGone', $json$"لم تعد هذه الدعوة معلّقة."$json$::jsonb),
  ('ar', 'org.inviteExpired', $json$"انتهت صلاحية هذه الدعوة. اطلب دعوة جديدة."$json$::jsonb),
  ('ar', 'org.emailUnconfirmed', $json$"أكّد بريدك الإلكتروني لقبول هذه الدعوة."$json$::jsonb),
  ('ar', 'org.notMember', $json$"هذا الشخص ليس عضوًا."$json$::jsonb),
  ('ar', 'org.repoTaken', $json$"هذا المستودع موجود بالفعل في المؤسسة."$json$::jsonb),
  ('ar', 'org.repoInvalid', $json$"مسار مستودع غير صالح."$json$::jsonb),
  ('fr', 'nav.organizations', $json$"Organisations"$json$::jsonb),
  ('fr', 'org.list.description', $json$"Des équipes qui partagent des dépôts. Un projet rejoint une organisation quand son git remote correspond à l'un de ses dépôts."$json$::jsonb),
  ('fr', 'org.list.empty', $json$"Vous n'êtes encore dans aucune organisation. Créez-en une ou acceptez une invitation."$json$::jsonb),
  ('fr', 'org.open', $json$"Ouvrir"$json$::jsonb),
  ('fr', 'org.back', $json$"Toutes les organisations"$json$::jsonb),
  ('fr', 'org.count.members', $json${"one": "{count} membre", "other": "{count} membres"}$json$::jsonb),
  ('fr', 'org.count.repositories', $json${"one": "{count} dépôt", "other": "{count} dépôts"}$json$::jsonb),
  ('fr', 'org.role.owner', $json$"Owner"$json$::jsonb),
  ('fr', 'org.role.maintainer', $json$"Maintainer"$json$::jsonb),
  ('fr', 'org.role.member', $json$"Membre"$json$::jsonb),
  ('fr', 'org.project.badge', $json$"Fait partie de {name}"$json$::jsonb),
  ('fr', 'org.new.title', $json$"Nouvelle organisation"$json$::jsonb),
  ('fr', 'org.new.description', $json$"Vous en devenez owner. Invitez des personnes et ajoutez des dépôts ensuite."$json$::jsonb),
  ('fr', 'org.new.create', $json$"Créer l'organisation"$json$::jsonb),
  ('fr', 'org.field.name', $json$"Nom"$json$::jsonb),
  ('fr', 'org.field.slug', $json$"Identifiant"$json$::jsonb),
  ('fr', 'org.field.slug.hint', $json$"Unique, sert à retrouver l'organisation."$json$::jsonb),
  ('fr', 'org.field.slug.invalid', $json$"Utilisez 3 à {max} minuscules, chiffres ou -, en commençant et finissant par une lettre ou un chiffre."$json$::jsonb),
  ('fr', 'org.invites.title', $json$"Invitations pour vous"$json$::jsonb),
  ('fr', 'org.invites.description', $json$"Acceptez pour rejoindre. Les invitations expirent après 14 jours."$json$::jsonb),
  ('fr', 'org.invites.count', $json${"one": "{count} invitation en attente", "other": "{count} invitations en attente"}$json$::jsonb),
  ('fr', 'org.invites.from', $json$"En tant que {role} · invité par {user} · expire le {date}"$json$::jsonb),
  ('fr', 'org.invites.accept', $json$"Accepter"$json$::jsonb),
  ('fr', 'org.invites.decline', $json$"Refuser"$json$::jsonb),
  ('fr', 'org.tab.members', $json$"Membres"$json$::jsonb),
  ('fr', 'org.tab.repositories', $json$"Dépôts"$json$::jsonb),
  ('fr', 'org.tab.settings', $json$"Paramètres"$json$::jsonb),
  ('fr', 'org.invite.title', $json$"Inviter des personnes"$json$::jsonb),
  ('fr', 'org.invite.description', $json$"Par @utilisateur ou e-mail. L'invitation apparaît dans le JayV de la personne et expire dans 14 jours."$json$::jsonb),
  ('fr', 'org.invite.target', $json$"@utilisateur ou e-mail"$json$::jsonb),
  ('fr', 'org.invite.placeholder', $json$"@utilisateur ou e-mail"$json$::jsonb),
  ('fr', 'org.invite.role', $json$"Rôle"$json$::jsonb),
  ('fr', 'org.invite.send', $json$"Inviter"$json$::jsonb),
  ('fr', 'org.invite.sent', $json$"Invitation envoyée à {target}."$json$::jsonb),
  ('fr', 'org.invite.hint', $json$"Tapez au moins 2 caractères du nom d'utilisateur pour chercher."$json$::jsonb),
  ('fr', 'org.invite.emailNote', $json$"JayV n'envoie pas d'e-mail : prévenez la personne. L'invitation apparaît quand elle se connecte avec cet e-mail confirmé."$json$::jsonb),
  ('fr', 'org.invite.expires', $json$"expire le {date}"$json$::jsonb),
  ('fr', 'org.invite.revoke', $json$"Révoquer"$json$::jsonb),
  ('fr', 'org.members.title', $json$"Membres"$json$::jsonb),
  ('fr', 'org.members.you', $json$"(vous)"$json$::jsonb),
  ('fr', 'org.members.role', $json$"Rôle de @{user}"$json$::jsonb),
  ('fr', 'org.members.remove', $json$"Retirer"$json$::jsonb),
  ('fr', 'org.members.remove.title', $json$"Retirer le membre"$json$::jsonb),
  ('fr', 'org.members.remove.description', $json$"@{user} perdra l'accès à l'organisation."$json$::jsonb),
  ('fr', 'org.repos.title', $json$"Dépôts"$json$::jsonb),
  ('fr', 'org.repos.description', $json$"GitHub, GitLab et Bitbucket. Le projet local d'un membre rejoint l'organisation quand l'un de ses git remotes correspond à un dépôt d'ici."$json$::jsonb),
  ('fr', 'org.repos.url', $json$"URL du dépôt"$json$::jsonb),
  ('fr', 'org.repos.add', $json$"Ajouter"$json$::jsonb),
  ('fr', 'org.repos.hint', $json$"Collez l'URL HTTPS ou SSH."$json$::jsonb),
  ('fr', 'org.repos.invalid', $json$"Ce n'est pas l'URL d'un dépôt GitHub, GitLab ou Bitbucket."$json$::jsonb),
  ('fr', 'org.repos.empty', $json$"Aucun dépôt pour l'instant."$json$::jsonb),
  ('fr', 'org.repos.remove', $json$"Retirer"$json$::jsonb),
  ('fr', 'org.repos.remove.title', $json$"Retirer le dépôt"$json$::jsonb),
  ('fr', 'org.repos.remove.description', $json$"Les projets qui correspondent à {repo} quittent l'organisation."$json$::jsonb),
  ('fr', 'org.settings.rename', $json$"Renommer"$json$::jsonb),
  ('fr', 'org.settings.renamed', $json$"Organisation renommée."$json$::jsonb),
  ('fr', 'org.settings.leave', $json$"Quitter l'organisation"$json$::jsonb),
  ('fr', 'org.settings.leave.description', $json$"Vous perdez l'accès à ses membres et dépôts. Le dernier owner ne peut pas partir."$json$::jsonb),
  ('fr', 'org.settings.leave.confirm', $json$"Quitter {name} ?"$json$::jsonb),
  ('fr', 'org.settings.delete', $json$"Supprimer l'organisation"$json$::jsonb),
  ('fr', 'org.settings.delete.description', $json$"Supprime définitivement membres, invitations et dépôts. Les projets locaux restent."$json$::jsonb),
  ('fr', 'org.settings.delete.type', $json$"Tapez {slug} pour confirmer"$json$::jsonb),
  ('fr', 'org.forbidden', $json$"Votre rôle dans cette organisation ne le permet pas."$json$::jsonb),
  ('fr', 'org.lastOwner', $json$"L'organisation a besoin d'au moins un owner. Promouvez quelqu'un d'abord."$json$::jsonb),
  ('fr', 'org.slugTaken', $json$"Cet identifiant est déjà pris."$json$::jsonb),
  ('fr', 'org.alreadyMember', $json$"Cette personne est déjà membre."$json$::jsonb),
  ('fr', 'org.alreadyInvited', $json$"Cette personne a déjà une invitation en attente."$json$::jsonb),
  ('fr', 'org.userNotFound', $json$"Aucun utilisateur JayV avec ce nom d'utilisateur."$json$::jsonb),
  ('fr', 'org.inviteGone', $json$"Cette invitation n'est plus en attente."$json$::jsonb),
  ('fr', 'org.inviteExpired', $json$"Cette invitation a expiré. Demandez-en une nouvelle."$json$::jsonb),
  ('fr', 'org.emailUnconfirmed', $json$"Confirmez votre e-mail pour accepter cette invitation."$json$::jsonb),
  ('fr', 'org.notMember', $json$"Cette personne n'est pas membre."$json$::jsonb),
  ('fr', 'org.repoTaken', $json$"Ce dépôt est déjà dans l'organisation."$json$::jsonb),
  ('fr', 'org.repoInvalid', $json$"Chemin de dépôt invalide."$json$::jsonb),
  ('ru', 'nav.organizations', $json$"Организации"$json$::jsonb),
  ('ru', 'org.list.description', $json$"Команды с общими репозиториями. Проект входит в организацию, когда его git remote совпадает с одним из её репозиториев."$json$::jsonb),
  ('ru', 'org.list.empty', $json$"Вы пока не состоите ни в одной организации. Создайте её или примите приглашение."$json$::jsonb),
  ('ru', 'org.open', $json$"Открыть"$json$::jsonb),
  ('ru', 'org.back', $json$"Все организации"$json$::jsonb),
  ('ru', 'org.count.members', $json${"one": "{count} участник", "few": "{count} участника", "many": "{count} участников", "other": "{count} участника"}$json$::jsonb),
  ('ru', 'org.count.repositories', $json${"one": "{count} репозиторий", "few": "{count} репозитория", "many": "{count} репозиториев", "other": "{count} репозитория"}$json$::jsonb),
  ('ru', 'org.role.owner', $json$"Владелец"$json$::jsonb),
  ('ru', 'org.role.maintainer', $json$"Мейнтейнер"$json$::jsonb),
  ('ru', 'org.role.member', $json$"Участник"$json$::jsonb),
  ('ru', 'org.project.badge', $json$"Входит в {name}"$json$::jsonb),
  ('ru', 'org.new.title', $json$"Новая организация"$json$::jsonb),
  ('ru', 'org.new.description', $json$"Вы станете её владельцем. Пригласите людей и добавьте репозитории позже."$json$::jsonb),
  ('ru', 'org.new.create', $json$"Создать организацию"$json$::jsonb),
  ('ru', 'org.field.name', $json$"Название"$json$::jsonb),
  ('ru', 'org.field.slug', $json$"Идентификатор"$json$::jsonb),
  ('ru', 'org.field.slug.hint', $json$"Уникален, по нему находят организацию."$json$::jsonb),
  ('ru', 'org.field.slug.invalid', $json$"Используйте от 3 до {max} строчных букв, цифр или -; начало и конец — буква или цифра."$json$::jsonb),
  ('ru', 'org.invites.title', $json$"Приглашения для вас"$json$::jsonb),
  ('ru', 'org.invites.description', $json$"Примите, чтобы вступить. Приглашения действуют 14 дней."$json$::jsonb),
  ('ru', 'org.invites.count', $json${"one": "{count} приглашение", "few": "{count} приглашения", "many": "{count} приглашений", "other": "{count} приглашения"}$json$::jsonb),
  ('ru', 'org.invites.from', $json$"Роль: {role} · пригласил {user} · до {date}"$json$::jsonb),
  ('ru', 'org.invites.accept', $json$"Принять"$json$::jsonb),
  ('ru', 'org.invites.decline', $json$"Отклонить"$json$::jsonb),
  ('ru', 'org.tab.members', $json$"Участники"$json$::jsonb),
  ('ru', 'org.tab.repositories', $json$"Репозитории"$json$::jsonb),
  ('ru', 'org.tab.settings', $json$"Настройки"$json$::jsonb),
  ('ru', 'org.invite.title', $json$"Пригласить людей"$json$::jsonb),
  ('ru', 'org.invite.description', $json$"По @имени или почте. Приглашение появится в JayV человека и действует 14 дней."$json$::jsonb),
  ('ru', 'org.invite.target', $json$"@имя или почта"$json$::jsonb),
  ('ru', 'org.invite.placeholder', $json$"@имя или почта"$json$::jsonb),
  ('ru', 'org.invite.role', $json$"Роль"$json$::jsonb),
  ('ru', 'org.invite.send', $json$"Пригласить"$json$::jsonb),
  ('ru', 'org.invite.sent', $json$"Приглашение отправлено: {target}."$json$::jsonb),
  ('ru', 'org.invite.hint', $json$"Введите хотя бы 2 символа имени для поиска."$json$::jsonb),
  ('ru', 'org.invite.emailNote', $json$"JayV не отправляет письмо: предупредите человека. Приглашение появится, когда он войдёт с этой подтверждённой почтой."$json$::jsonb),
  ('ru', 'org.invite.expires', $json$"до {date}"$json$::jsonb),
  ('ru', 'org.invite.revoke', $json$"Отозвать"$json$::jsonb),
  ('ru', 'org.members.title', $json$"Участники"$json$::jsonb),
  ('ru', 'org.members.you', $json$"(вы)"$json$::jsonb),
  ('ru', 'org.members.role', $json$"Роль @{user}"$json$::jsonb),
  ('ru', 'org.members.remove', $json$"Удалить"$json$::jsonb),
  ('ru', 'org.members.remove.title', $json$"Удалить участника"$json$::jsonb),
  ('ru', 'org.members.remove.description', $json$"@{user} потеряет доступ к организации."$json$::jsonb),
  ('ru', 'org.repos.title', $json$"Репозитории"$json$::jsonb),
  ('ru', 'org.repos.description', $json$"GitHub, GitLab и Bitbucket. Локальный проект участника входит в организацию, когда один из его git remote совпадает с репозиторием отсюда."$json$::jsonb),
  ('ru', 'org.repos.url', $json$"URL репозитория"$json$::jsonb),
  ('ru', 'org.repos.add', $json$"Добавить"$json$::jsonb),
  ('ru', 'org.repos.hint', $json$"Вставьте URL HTTPS или SSH."$json$::jsonb),
  ('ru', 'org.repos.invalid', $json$"Это не URL репозитория GitHub, GitLab или Bitbucket."$json$::jsonb),
  ('ru', 'org.repos.empty', $json$"Репозиториев пока нет."$json$::jsonb),
  ('ru', 'org.repos.remove', $json$"Удалить"$json$::jsonb),
  ('ru', 'org.repos.remove.title', $json$"Удалить репозиторий"$json$::jsonb),
  ('ru', 'org.repos.remove.description', $json$"Проекты, совпадающие с {repo}, выйдут из организации."$json$::jsonb),
  ('ru', 'org.settings.rename', $json$"Переименовать"$json$::jsonb),
  ('ru', 'org.settings.renamed', $json$"Организация переименована."$json$::jsonb),
  ('ru', 'org.settings.leave', $json$"Покинуть организацию"$json$::jsonb),
  ('ru', 'org.settings.leave.description', $json$"Вы потеряете доступ к участникам и репозиториям. Последний владелец выйти не может."$json$::jsonb),
  ('ru', 'org.settings.leave.confirm', $json$"Покинуть {name}?"$json$::jsonb),
  ('ru', 'org.settings.delete', $json$"Удалить организацию"$json$::jsonb),
  ('ru', 'org.settings.delete.description', $json$"Навсегда удаляет участников, приглашения и репозитории. Локальные проекты остаются."$json$::jsonb),
  ('ru', 'org.settings.delete.type', $json$"Введите {slug} для подтверждения"$json$::jsonb),
  ('ru', 'org.forbidden', $json$"Ваша роль в этой организации этого не позволяет."$json$::jsonb),
  ('ru', 'org.lastOwner', $json$"В организации должен быть хотя бы один владелец. Сначала назначьте кого-то."$json$::jsonb),
  ('ru', 'org.slugTaken', $json$"Этот идентификатор уже занят."$json$::jsonb),
  ('ru', 'org.alreadyMember', $json$"Этот человек уже участник."$json$::jsonb),
  ('ru', 'org.alreadyInvited', $json$"У этого человека уже есть приглашение."$json$::jsonb),
  ('ru', 'org.userNotFound', $json$"Нет пользователя JayV с таким именем."$json$::jsonb),
  ('ru', 'org.inviteGone', $json$"Это приглашение больше не активно."$json$::jsonb),
  ('ru', 'org.inviteExpired', $json$"Срок приглашения истёк. Попросите новое."$json$::jsonb),
  ('ru', 'org.emailUnconfirmed', $json$"Подтвердите почту, чтобы принять приглашение."$json$::jsonb),
  ('ru', 'org.notMember', $json$"Этот человек не участник."$json$::jsonb),
  ('ru', 'org.repoTaken', $json$"Этот репозиторий уже в организации."$json$::jsonb),
  ('ru', 'org.repoInvalid', $json$"Недопустимый путь репозитория."$json$::jsonb),
  ('ja', 'nav.organizations', $json$"組織"$json$::jsonb),
  ('ja', 'org.list.description', $json$"リポジトリを共有するチームです。プロジェクトの git remote が組織のリポジトリと一致すると、その組織に入ります。"$json$::jsonb),
  ('ja', 'org.list.empty', $json$"まだどの組織にも参加していません。作成するか招待を承諾してください。"$json$::jsonb),
  ('ja', 'org.open', $json$"開く"$json$::jsonb),
  ('ja', 'org.back', $json$"すべての組織"$json$::jsonb),
  ('ja', 'org.count.members', $json${"other": "メンバー {count} 人"}$json$::jsonb),
  ('ja', 'org.count.repositories', $json${"other": "リポジトリ {count} 件"}$json$::jsonb),
  ('ja', 'org.role.owner', $json$"オーナー"$json$::jsonb),
  ('ja', 'org.role.maintainer', $json$"メンテナー"$json$::jsonb),
  ('ja', 'org.role.member', $json$"メンバー"$json$::jsonb),
  ('ja', 'org.project.badge', $json$"{name} に所属"$json$::jsonb),
  ('ja', 'org.new.title', $json$"新しい組織"$json$::jsonb),
  ('ja', 'org.new.description', $json$"あなたがオーナーになります。あとでメンバーを招待し、リポジトリを追加してください。"$json$::jsonb),
  ('ja', 'org.new.create', $json$"組織を作成"$json$::jsonb),
  ('ja', 'org.field.name', $json$"名前"$json$::jsonb),
  ('ja', 'org.field.slug', $json$"ハンドル"$json$::jsonb),
  ('ja', 'org.field.slug.hint', $json$"一意で、組織を探すときに使います。"$json$::jsonb),
  ('ja', 'org.field.slug.invalid', $json$"小文字・数字・- を 3〜{max} 文字で、先頭と末尾は英字か数字にしてください。"$json$::jsonb),
  ('ja', 'org.invites.title', $json$"あなたへの招待"$json$::jsonb),
  ('ja', 'org.invites.description', $json$"承諾すると参加します。招待は 14 日で期限切れになります。"$json$::jsonb),
  ('ja', 'org.invites.count', $json${"other": "保留中の招待 {count} 件"}$json$::jsonb),
  ('ja', 'org.invites.from', $json$"{role} として · {user} から招待 · {date} まで"$json$::jsonb),
  ('ja', 'org.invites.accept', $json$"承諾"$json$::jsonb),
  ('ja', 'org.invites.decline', $json$"辞退"$json$::jsonb),
  ('ja', 'org.tab.members', $json$"メンバー"$json$::jsonb),
  ('ja', 'org.tab.repositories', $json$"リポジトリ"$json$::jsonb),
  ('ja', 'org.tab.settings', $json$"設定"$json$::jsonb),
  ('ja', 'org.invite.title', $json$"メンバーを招待"$json$::jsonb),
  ('ja', 'org.invite.description', $json$"@ユーザー名かメールで招待します。招待は相手の JayV に表示され、14 日で期限切れになります。"$json$::jsonb),
  ('ja', 'org.invite.target', $json$"@ユーザー名またはメール"$json$::jsonb),
  ('ja', 'org.invite.placeholder', $json$"@ユーザー名またはメール"$json$::jsonb),
  ('ja', 'org.invite.role', $json$"役割"$json$::jsonb),
  ('ja', 'org.invite.send', $json$"招待"$json$::jsonb),
  ('ja', 'org.invite.sent', $json$"{target} に招待を送りました。"$json$::jsonb),
  ('ja', 'org.invite.hint', $json$"検索するにはユーザー名を 2 文字以上入力してください。"$json$::jsonb),
  ('ja', 'org.invite.emailNote', $json$"JayV はメールを送信しません。本人に知らせてください。確認済みのこのメールでサインインすると招待が表示されます。"$json$::jsonb),
  ('ja', 'org.invite.expires', $json$"{date} まで"$json$::jsonb),
  ('ja', 'org.invite.revoke', $json$"取り消す"$json$::jsonb),
  ('ja', 'org.members.title', $json$"メンバー"$json$::jsonb),
  ('ja', 'org.members.you', $json$"（あなた）"$json$::jsonb),
  ('ja', 'org.members.role', $json$"@{user} の役割"$json$::jsonb),
  ('ja', 'org.members.remove', $json$"削除"$json$::jsonb),
  ('ja', 'org.members.remove.title', $json$"メンバーを削除"$json$::jsonb),
  ('ja', 'org.members.remove.description', $json$"@{user} は組織にアクセスできなくなります。"$json$::jsonb),
  ('ja', 'org.repos.title', $json$"リポジトリ"$json$::jsonb),
  ('ja', 'org.repos.description', $json$"GitHub・GitLab・Bitbucket に対応。メンバーのローカルプロジェクトは、git remote のどれかがここのリポジトリと一致すると組織に入ります。"$json$::jsonb),
  ('ja', 'org.repos.url', $json$"リポジトリ URL"$json$::jsonb),
  ('ja', 'org.repos.add', $json$"追加"$json$::jsonb),
  ('ja', 'org.repos.hint', $json$"HTTPS または SSH の URL を貼り付けてください。"$json$::jsonb),
  ('ja', 'org.repos.invalid', $json$"GitHub・GitLab・Bitbucket のリポジトリ URL ではありません。"$json$::jsonb),
  ('ja', 'org.repos.empty', $json$"リポジトリはまだありません。"$json$::jsonb),
  ('ja', 'org.repos.remove', $json$"削除"$json$::jsonb),
  ('ja', 'org.repos.remove.title', $json$"リポジトリを削除"$json$::jsonb),
  ('ja', 'org.repos.remove.description', $json$"{repo} に一致するプロジェクトは組織から外れます。"$json$::jsonb),
  ('ja', 'org.settings.rename', $json$"名前を変更"$json$::jsonb),
  ('ja', 'org.settings.renamed', $json$"組織名を変更しました。"$json$::jsonb),
  ('ja', 'org.settings.leave', $json$"組織を抜ける"$json$::jsonb),
  ('ja', 'org.settings.leave.description', $json$"メンバーとリポジトリにアクセスできなくなります。最後のオーナーは抜けられません。"$json$::jsonb),
  ('ja', 'org.settings.leave.confirm', $json$"{name} を抜けますか？"$json$::jsonb),
  ('ja', 'org.settings.delete', $json$"組織を削除"$json$::jsonb),
  ('ja', 'org.settings.delete.description', $json$"メンバー・招待・リポジトリを完全に削除します。ローカルのプロジェクトは残ります。"$json$::jsonb),
  ('ja', 'org.settings.delete.type', $json$"確認のため {slug} と入力"$json$::jsonb),
  ('ja', 'org.forbidden', $json$"この組織でのあなたの役割では実行できません。"$json$::jsonb),
  ('ja', 'org.lastOwner', $json$"組織には最低 1 人のオーナーが必要です。先に誰かを昇格してください。"$json$::jsonb),
  ('ja', 'org.slugTaken', $json$"このハンドルは既に使われています。"$json$::jsonb),
  ('ja', 'org.alreadyMember', $json$"この人は既にメンバーです。"$json$::jsonb),
  ('ja', 'org.alreadyInvited', $json$"この人には保留中の招待があります。"$json$::jsonb),
  ('ja', 'org.userNotFound', $json$"このユーザー名の JayV ユーザーはいません。"$json$::jsonb),
  ('ja', 'org.inviteGone', $json$"この招待はもう保留中ではありません。"$json$::jsonb),
  ('ja', 'org.inviteExpired', $json$"この招待は期限切れです。新しい招待を依頼してください。"$json$::jsonb),
  ('ja', 'org.emailUnconfirmed', $json$"この招待を承諾するにはメールアドレスを確認してください。"$json$::jsonb),
  ('ja', 'org.notMember', $json$"この人はメンバーではありません。"$json$::jsonb),
  ('ja', 'org.repoTaken', $json$"このリポジトリは既に組織にあります。"$json$::jsonb),
  ('ja', 'org.repoInvalid', $json$"リポジトリのパスが正しくありません。"$json$::jsonb),
  ('de', 'nav.organizations', $json$"Organisationen"$json$::jsonb),
  ('de', 'org.list.description', $json$"Teams, die Repositories teilen. Ein Projekt gehört zu einer Organisation, wenn sein Git-Remote zu einem ihrer Repositories passt."$json$::jsonb),
  ('de', 'org.list.empty', $json$"Du bist noch in keiner Organisation. Erstelle eine oder nimm eine Einladung an."$json$::jsonb),
  ('de', 'org.open', $json$"Öffnen"$json$::jsonb),
  ('de', 'org.back', $json$"Alle Organisationen"$json$::jsonb),
  ('de', 'org.count.members', $json${"one": "{count} Mitglied", "other": "{count} Mitglieder"}$json$::jsonb),
  ('de', 'org.count.repositories', $json${"one": "{count} Repository", "other": "{count} Repositories"}$json$::jsonb),
  ('de', 'org.role.owner', $json$"Owner"$json$::jsonb),
  ('de', 'org.role.maintainer', $json$"Maintainer"$json$::jsonb),
  ('de', 'org.role.member', $json$"Mitglied"$json$::jsonb),
  ('de', 'org.project.badge', $json$"Gehört zu {name}"$json$::jsonb),
  ('de', 'org.new.title', $json$"Neue Organisation"$json$::jsonb),
  ('de', 'org.new.description', $json$"Du wirst ihr Owner. Lade danach Leute ein und füge Repositories hinzu."$json$::jsonb),
  ('de', 'org.new.create', $json$"Organisation erstellen"$json$::jsonb),
  ('de', 'org.field.name', $json$"Name"$json$::jsonb),
  ('de', 'org.field.slug', $json$"Kennung"$json$::jsonb),
  ('de', 'org.field.slug.hint', $json$"Eindeutig, um die Organisation zu finden."$json$::jsonb),
  ('de', 'org.field.slug.invalid', $json$"Verwende 3 bis {max} Kleinbuchstaben, Ziffern oder -, beginnend und endend mit Buchstabe oder Ziffer."$json$::jsonb),
  ('de', 'org.invites.title', $json$"Einladungen für dich"$json$::jsonb),
  ('de', 'org.invites.description', $json$"Nimm an, um beizutreten. Einladungen laufen nach 14 Tagen ab."$json$::jsonb),
  ('de', 'org.invites.count', $json${"one": "{count} offene Einladung", "other": "{count} offene Einladungen"}$json$::jsonb),
  ('de', 'org.invites.from', $json$"Als {role} · eingeladen von {user} · läuft ab am {date}"$json$::jsonb),
  ('de', 'org.invites.accept', $json$"Annehmen"$json$::jsonb),
  ('de', 'org.invites.decline', $json$"Ablehnen"$json$::jsonb),
  ('de', 'org.tab.members', $json$"Mitglieder"$json$::jsonb),
  ('de', 'org.tab.repositories', $json$"Repositories"$json$::jsonb),
  ('de', 'org.tab.settings', $json$"Einstellungen"$json$::jsonb),
  ('de', 'org.invite.title', $json$"Leute einladen"$json$::jsonb),
  ('de', 'org.invite.description', $json$"Per @Benutzername oder E-Mail. Die Einladung erscheint im JayV der Person und läuft nach 14 Tagen ab."$json$::jsonb),
  ('de', 'org.invite.target', $json$"@Benutzername oder E-Mail"$json$::jsonb),
  ('de', 'org.invite.placeholder', $json$"@Benutzername oder E-Mail"$json$::jsonb),
  ('de', 'org.invite.role', $json$"Rolle"$json$::jsonb),
  ('de', 'org.invite.send', $json$"Einladen"$json$::jsonb),
  ('de', 'org.invite.sent', $json$"Einladung an {target} gesendet."$json$::jsonb),
  ('de', 'org.invite.hint', $json$"Gib mindestens 2 Zeichen des Benutzernamens ein, um zu suchen."$json$::jsonb),
  ('de', 'org.invite.emailNote', $json$"JayV sendet keine E-Mail: Sag der Person Bescheid. Die Einladung erscheint, sobald sie sich mit dieser bestätigten E-Mail anmeldet."$json$::jsonb),
  ('de', 'org.invite.expires', $json$"läuft ab am {date}"$json$::jsonb),
  ('de', 'org.invite.revoke', $json$"Widerrufen"$json$::jsonb),
  ('de', 'org.members.title', $json$"Mitglieder"$json$::jsonb),
  ('de', 'org.members.you', $json$"(du)"$json$::jsonb),
  ('de', 'org.members.role', $json$"Rolle von @{user}"$json$::jsonb),
  ('de', 'org.members.remove', $json$"Entfernen"$json$::jsonb),
  ('de', 'org.members.remove.title', $json$"Mitglied entfernen"$json$::jsonb),
  ('de', 'org.members.remove.description', $json$"@{user} verliert den Zugriff auf die Organisation."$json$::jsonb),
  ('de', 'org.repos.title', $json$"Repositories"$json$::jsonb),
  ('de', 'org.repos.description', $json$"GitHub, GitLab und Bitbucket. Das lokale Projekt eines Mitglieds gehört zur Organisation, wenn einer seiner Git-Remotes zu einem Repository hier passt."$json$::jsonb),
  ('de', 'org.repos.url', $json$"Repository-URL"$json$::jsonb),
  ('de', 'org.repos.add', $json$"Hinzufügen"$json$::jsonb),
  ('de', 'org.repos.hint', $json$"Füge die HTTPS- oder SSH-URL ein."$json$::jsonb),
  ('de', 'org.repos.invalid', $json$"Keine Repository-URL von GitHub, GitLab oder Bitbucket."$json$::jsonb),
  ('de', 'org.repos.empty', $json$"Noch keine Repositories."$json$::jsonb),
  ('de', 'org.repos.remove', $json$"Entfernen"$json$::jsonb),
  ('de', 'org.repos.remove.title', $json$"Repository entfernen"$json$::jsonb),
  ('de', 'org.repos.remove.description', $json$"Projekte, die zu {repo} passen, verlassen die Organisation."$json$::jsonb),
  ('de', 'org.settings.rename', $json$"Umbenennen"$json$::jsonb),
  ('de', 'org.settings.renamed', $json$"Organisation umbenannt."$json$::jsonb),
  ('de', 'org.settings.leave', $json$"Organisation verlassen"$json$::jsonb),
  ('de', 'org.settings.leave.description', $json$"Du verlierst den Zugriff auf Mitglieder und Repositories. Der letzte Owner kann nicht gehen."$json$::jsonb),
  ('de', 'org.settings.leave.confirm', $json$"{name} verlassen?"$json$::jsonb),
  ('de', 'org.settings.delete', $json$"Organisation löschen"$json$::jsonb),
  ('de', 'org.settings.delete.description', $json$"Entfernt Mitglieder, Einladungen und Repositories endgültig. Lokale Projekte bleiben."$json$::jsonb),
  ('de', 'org.settings.delete.type', $json$"Gib {slug} zur Bestätigung ein"$json$::jsonb),
  ('de', 'org.forbidden', $json$"Deine Rolle in dieser Organisation erlaubt das nicht."$json$::jsonb),
  ('de', 'org.lastOwner', $json$"Die Organisation braucht mindestens einen Owner. Befördere zuerst jemanden."$json$::jsonb),
  ('de', 'org.slugTaken', $json$"Diese Kennung ist bereits vergeben."$json$::jsonb),
  ('de', 'org.alreadyMember', $json$"Diese Person ist bereits Mitglied."$json$::jsonb),
  ('de', 'org.alreadyInvited', $json$"Diese Person hat bereits eine offene Einladung."$json$::jsonb),
  ('de', 'org.userNotFound', $json$"Kein JayV-Nutzer mit diesem Benutzernamen."$json$::jsonb),
  ('de', 'org.inviteGone', $json$"Diese Einladung ist nicht mehr offen."$json$::jsonb),
  ('de', 'org.inviteExpired', $json$"Diese Einladung ist abgelaufen. Bitte um eine neue."$json$::jsonb),
  ('de', 'org.emailUnconfirmed', $json$"Bestätige deine E-Mail, um diese Einladung anzunehmen."$json$::jsonb),
  ('de', 'org.notMember', $json$"Diese Person ist kein Mitglied."$json$::jsonb),
  ('de', 'org.repoTaken', $json$"Dieses Repository ist bereits in der Organisation."$json$::jsonb),
  ('de', 'org.repoInvalid', $json$"Ungültiger Repository-Pfad."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
