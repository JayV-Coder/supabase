-- O nome completo dá lugar ao nome de usuário: único, curto e fácil de buscar
-- dentro do JayV (a busca entre membros chega com as organizações). O app
-- 0.15.0 lia `full_name`; a partir daqui só o 0.16.0 lê o perfil.

-- 3 a 30 caracteres: minúsculas sem acento, dígitos, `_` e `-`, começando e
-- terminando em letra ou dígito. Guardado já em minúsculas, então o índice
-- único vale sem diferenciar caixa.
create function public.username_ok(name text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(name ~ '^[a-z0-9][a-z0-9_-]{1,28}[a-z0-9]$', false);
$$;

-- A base sugerida: o apelido do provedor ou o começo do e-mail, sem acento e
-- sem o que o formato não aceita; curta o bastante para caber um sufixo.
create function public.username_base(meta jsonb, email text) returns text language sql immutable set search_path = '' as $$
  with raw as (
    select lower(translate(coalesce(
      nullif(btrim(meta->>'user_name'), ''),
      nullif(btrim(meta->>'preferred_username'), ''),
      nullif(split_part(coalesce(email, ''), '@', 1), ''),
      'user'),
      'áàâãäåçéèêëíìîïñóòôõöúùûüýÿÁÀÂÃÄÅÇÉÈÊËÍÌÎÏÑÓÒÔÕÖÚÙÛÜÝ',
      'aaaaaaceeeeiiiinooooouuuuyyaaaaaaceeeeiiiinooooouuuuy')) as name
  ), slug as (
    select btrim(left(regexp_replace(regexp_replace(name, '[^a-z0-9_-]+', '-', 'g'), '[-_]{2,}', '-', 'g'), 24), '-_') as name from raw
  )
  select case when char_length(name) >= 3 then name else 'user' || name end from slug;
$$;

-- O primeiro nome livre a partir da base: `ana`, `ana-2`, `ana-3`...
create function public.username_free(base text) returns text language plpgsql stable set search_path = '' as $$
declare
  candidate text := base;
  n int := 1;
begin
  while exists (select 1 from public.profiles where username = candidate) loop
    n := n + 1;
    candidate := base || '-' || n;
  end loop;
  return candidate;
end;
$$;

alter table public.profiles drop column full_name;
alter table public.profiles add column username text;

do $$
declare
  account record;
begin
  for account in select u.id, u.raw_user_meta_data, u.email from auth.users u join public.profiles p on p.user_id = u.id order by u.created_at loop
    update public.profiles
      set username = public.username_free(public.username_base(account.raw_user_meta_data, account.email))
      where user_id = account.id;
  end loop;
end;
$$;

alter table public.profiles
  alter column username set not null,
  add constraint profiles_username_format check (public.username_ok(username)),
  add constraint profiles_username_unique unique (username);

create or replace function public.profiles_create() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name, username)
  values (new.id, public.profile_name(new.raw_user_meta_data, new.email),
          public.username_free(public.username_base(new.raw_user_meta_data, new.email)))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

-- A tela pergunta antes de gravar. Só diz sim ou não: nenhum perfil sai daqui.
create function public.username_available(name text) returns boolean language sql stable security definer set search_path = '' as $$
  select public.username_ok(name)
     and not exists (select 1 from public.profiles where username = name and user_id <> auth.uid());
$$;

revoke execute on function public.username_available(text) from public, anon;
grant execute on function public.username_available(text) to authenticated;
revoke execute on function public.username_base(jsonb, text), public.username_free(text) from public, anon, authenticated;
