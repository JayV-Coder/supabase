-- Site v1.1.0: a página Usuários do painel do site, só para o admin do
-- sistema (`public.admins` / `is_admin()`). Lista todas as contas e, em cada
-- uma, deixa o admin: dar ou tirar o papel de admin, bloquear e desbloquear,
-- encerrar as sessões, confirmar o e-mail, remover o app autenticador (quem
-- perdeu o celular), corrigir nome de exibição e nome de usuário, mandar o
-- link de troca de senha e excluir a conta.
--
-- Tudo passa por funções `security definer` que começam por `admin_require()`;
-- o admin não lê `auth.users` nem escreve em tabela nenhuma direto. Cada ação
-- fica em `admin_audit`, que sobrevive à conta excluída (sem chave para
-- `auth.users`). As recusas são chaves do i18n do site (`site.users.error.*`).
--
-- O plano de quem assina vem do Stripe (`subscriptions`, gravada pelo
-- webhook): a página mostra, mas não troca — trocar aqui seria desfeito no
-- próximo evento do Stripe.

-- 1. O registro do que o admin fez.
create table public.admin_audit (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users on delete set null,
  target_id uuid not null,
  target_email text,
  action text not null check (action ~ '^[a-z][A-Za-z]{1,40}$'),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index admin_audit_target on public.admin_audit (target_id, created_at desc);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;

create function public.admin_log(target uuid, action text, detail jsonb default '{}'::jsonb) returns void language sql security definer set search_path = '' as $$
  insert into public.admin_audit (admin_id, target_id, target_email, action, detail)
  values (auth.uid(), target, (select u.email from auth.users u where u.id = target), action, coalesce(detail, '{}'::jsonb));
$$;
revoke execute on function public.admin_log(uuid, text, jsonb) from public, anon, authenticated;

-- A conta existe? Toda ação sobre outra pessoa começa aqui.
create function public.admin_target(target uuid) returns void language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_require();
  if not exists (select 1 from auth.users u where u.id = target) then raise exception 'site.users.error.notFound'; end if;
end;
$$;
revoke execute on function public.admin_target(uuid) from public, anon, authenticated;

-- O plano em vigor de qualquer conta, pela mesma regra de `my_plan()`.
create function public.plan_of(person uuid) returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.plan_key from public.subscriptions s join public.plans p on p.key = s.plan_key
      where s.user_id = person and s.status in ('active', 'trialing', 'past_due')),
    (select p.key from public.plans p where p.is_default)
  );
$$;
revoke execute on function public.plan_of(uuid) from public, anon, authenticated;

-- 2. A lista. A busca olha e-mail, nome de usuário e nome de exibição;
-- `total` é o número de contas que a busca acha (para paginar).
create function public.admin_users(search text default '', page_size int default 50, page int default 0)
returns table (
  user_id uuid, email text, display_name text, username text, avatar_url text,
  created_at timestamptz, last_sign_in_at timestamptz, email_confirmed_at timestamptz, banned_until timestamptz,
  providers text[], has_password boolean, has_mfa boolean, is_admin boolean,
  plan_key text, subscription_status text, organizations bigint, projects bigint, total bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare
  wanted text := '%' || replace(replace(replace(lower(btrim(coalesce(search, ''))), '\', '\\'), '%', '\%'), '_', '\_') || '%';
begin
  perform public.admin_require();
  return query
    select u.id, u.email::text, p.display_name, p.username, p.avatar_url,
      u.created_at, u.last_sign_in_at, u.email_confirmed_at, u.banned_until,
      coalesce((select array_agg(distinct i.provider order by i.provider) from auth.identities i where i.user_id = u.id), '{}'),
      coalesce(u.encrypted_password, '') <> '',
      exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'),
      exists (select 1 from public.admins a where a.user_id = u.id),
      public.plan_of(u.id),
      (select s.status from public.subscriptions s where s.user_id = u.id),
      (select count(*) from public.organization_members m where m.user_id = u.id),
      (select count(*) from public.projects pr where pr.user_id = u.id and pr.row_deleted_at is null),
      count(*) over ()
    from auth.users u
    left join public.profiles p on p.user_id = u.id
    where wanted = '%%'
       or lower(coalesce(u.email, '')) like wanted
       or lower(coalesce(p.username, '')) like wanted
       or lower(coalesce(p.display_name, '')) like wanted
    order by u.created_at desc
    limit least(greatest(coalesce(page_size, 50), 1), 200)
    offset greatest(coalesce(page, 0), 0) * least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;
revoke execute on function public.admin_users(text, int, int) from public, anon;
grant execute on function public.admin_users(text, int, int) to authenticated;

-- 3. Uma conta inteira: perfil, acesso, plano e assinatura, organizações, uso
-- e o que os admins já fizeram com ela.
create function public.admin_user(target uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
      'expertise', (select a.value from public.account_settings a where a.user_id = u.id and a.key = 'expertise_level' and a.row_deleted_at is null),
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

-- 4. As ações. O admin não age sobre a própria conta (não se tranca para
-- fora) e não bloqueia nem exclui outro admin sem antes tirar o papel.
create function public.admin_not_self(target uuid) returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if target = auth.uid() then raise exception 'site.users.error.self'; end if;
end;
$$;
revoke execute on function public.admin_not_self(uuid) from public, anon, authenticated;

create function public.admin_set_admin(target uuid, on_off boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  perform public.admin_not_self(target);
  if on_off then
    insert into public.admins (user_id) values (target) on conflict do nothing;
  else
    delete from public.admins where user_id = target;
  end if;
  perform public.admin_log(target, case when on_off then 'grantAdmin' else 'revokeAdmin' end);
end;
$$;

-- Encerrar as sessões apaga os refresh tokens: o app e o site pedem login de
-- novo quando o token de acesso em mãos vencer (até uma hora).
create function public.admin_sign_out(target uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  perform public.admin_not_self(target);
  delete from auth.refresh_tokens where user_id = target::text;
  delete from auth.sessions where user_id = target;
  perform public.admin_log(target, 'signOut');
end;
$$;

-- O bloqueio é o `banned_until` do Supabase Auth: a conta não entra nem
-- renova a sessão. Bloquear também encerra as sessões abertas.
create function public.admin_set_banned(target uuid, on_off boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  perform public.admin_not_self(target);
  if on_off and exists (select 1 from public.admins a where a.user_id = target) then raise exception 'site.users.error.isAdmin'; end if;
  update auth.users set banned_until = case when on_off then now() + interval '100 years' else null end where id = target;
  if on_off then
    delete from auth.refresh_tokens where user_id = target::text;
    delete from auth.sessions where user_id = target;
  end if;
  perform public.admin_log(target, case when on_off then 'ban' else 'unban' end);
end;
$$;

create function public.admin_confirm_email(target uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = target;
  perform public.admin_log(target, 'confirmEmail');
end;
$$;

-- Quem perdeu o app autenticador volta a entrar só com a senha (ou o
-- provedor) e pode cadastrar outro.
create function public.admin_reset_mfa(target uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  perform public.admin_not_self(target);
  delete from auth.mfa_factors where user_id = target;
  perform public.admin_log(target, 'resetMfa');
end;
$$;

-- O link de troca de senha sai pelo Supabase Auth (o site chama `/recover`
-- com o e-mail que esta função devolve, depois de registrar).
create function public.admin_password_reset(target uuid) returns text language plpgsql security definer set search_path = '' as $$
declare
  address text;
begin
  perform public.admin_target(target);
  select u.email into address from auth.users u where u.id = target;
  if coalesce(address, '') = '' then raise exception 'site.users.error.noEmail'; end if;
  perform public.admin_log(target, 'passwordReset');
  return address;
end;
$$;

-- O gatilho do perfil deixa o nome de usuário fixo depois da primeira
-- gravação; só o admin, por esta função, corrige o nome ou libera a troca.
create or replace function public.profiles_touch() returns trigger language plpgsql set search_path = '' as $$
begin
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if coalesce(current_setting('jayv.admin_profile', true), '') = 'on' then
    return new;
  end if;
  -- A marca não volta a nulo nem anda depois de posta; a hora é a do banco.
  if old.username_set_at is not null then
    new.username_set_at := old.username_set_at;
    if new.username is distinct from old.username then
      raise exception 'profile.username.locked' using errcode = 'P0001';
    end if;
  elsif new.username_set_at is not null then
    new.username_set_at := now();
  end if;
  return new;
end;
$$;

create function public.admin_update_profile(target uuid, display_name text, username text, unlock_username boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  previous record;
  wanted text := lower(btrim(coalesce(username, '')));
begin
  perform public.admin_target(target);
  select p.display_name, p.username into previous from public.profiles p where p.user_id = target;
  if not found then raise exception 'site.users.error.notFound'; end if;
  if char_length(btrim(coalesce(display_name, ''))) not between 1 and 60 or not public.username_ok(wanted) then
    raise exception 'profile.invalid';
  end if;
  if exists (select 1 from public.profiles p where p.username = wanted and p.user_id <> target) then raise exception 'profile.usernameTaken'; end if;
  perform set_config('jayv.admin_profile', 'on', true);
  update public.profiles p
    set display_name = btrim(admin_update_profile.display_name),
        username = wanted,
        username_set_at = case when unlock_username then null else p.username_set_at end
    where p.user_id = target;
  perform set_config('jayv.admin_profile', '', true);
  perform public.admin_log(target, 'updateProfile', jsonb_build_object(
    'display_name', jsonb_build_array(previous.display_name, btrim(admin_update_profile.display_name)),
    'username', jsonb_build_array(previous.username, wanted),
    'unlock_username', coalesce(unlock_username, false)
  ));
end;
$$;

-- Excluir apaga a conta e, em cascata, tudo dela (projetos, chats, perfil,
-- assinatura gravada). A organização em que ela é a única pessoa vai junto;
-- a organização em que ela é o único owner e há mais membros trava a
-- exclusão, para não ficar sem dono — promova alguém antes.
create function public.admin_delete_user(target uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_target(target);
  perform public.admin_not_self(target);
  if exists (select 1 from public.admins a where a.user_id = target) then raise exception 'site.users.error.isAdmin'; end if;
  if exists (
    select 1 from public.organization_members m
    where m.user_id = target and m.role = 'owner'
      and not exists (select 1 from public.organization_members o where o.org_id = m.org_id and o.role = 'owner' and o.user_id <> target)
      and exists (select 1 from public.organization_members o where o.org_id = m.org_id and o.user_id <> target)
  ) then
    raise exception 'site.users.error.soleOwner';
  end if;
  perform public.admin_log(target, 'deleteUser');
  delete from public.organizations o
    where exists (select 1 from public.organization_members m where m.org_id = o.id and m.user_id = target)
      and not exists (select 1 from public.organization_members m where m.org_id = o.id and m.user_id <> target);
  delete from auth.users where id = target;
end;
$$;

revoke execute on function
  public.admin_set_admin(uuid, boolean), public.admin_sign_out(uuid), public.admin_set_banned(uuid, boolean),
  public.admin_confirm_email(uuid), public.admin_reset_mfa(uuid), public.admin_password_reset(uuid),
  public.admin_update_profile(uuid, text, text, boolean), public.admin_delete_user(uuid)
from public, anon;
grant execute on function
  public.admin_set_admin(uuid, boolean), public.admin_sign_out(uuid), public.admin_set_banned(uuid, boolean),
  public.admin_confirm_email(uuid), public.admin_reset_mfa(uuid), public.admin_password_reset(uuid),
  public.admin_update_profile(uuid, text, text, boolean), public.admin_delete_user(uuid)
to authenticated;
