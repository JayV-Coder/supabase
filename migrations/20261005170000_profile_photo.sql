-- A foto de perfil escolhida pela pessoa no painel do site. Ela vale em todo
-- login — e-mail e senha ou qualquer conta vinculada — e aparece no app, nas
-- listas de membros e na Administração, que já leem `profiles.avatar_url`.
--
-- Até aqui `avatar_url` seguia o provedor: o gatilho `profiles_avatar` o
-- reescrevia a cada login pelo GitHub, GitLab ou Bitbucket. Com a foto
-- própria (`avatar_custom`), o provedor não a troca mais; tirar a foto volta
-- para a do provedor.
--
-- O arquivo mora no Storage, no bucket público `avatars`, na pasta com o id da
-- conta (`<user_id>/<arquivo>.webp`). Só a dona escreve e apaga ali.

alter table public.profiles add column avatar_custom boolean not null default false;

-- 1. O bucket: público para leitura (a foto aparece para os membros da
-- organização e no app), até 1 MB e só imagem. O site já manda a foto cortada
-- em 512×512.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/webp', 'image/png', 'image/jpeg'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 2. Cada conta só mexe na própria pasta, e com o segundo fator em dia (como
-- toda tabela do `public`, migração `second_factor`).
create policy "avatars: dono lista" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.second_factor_ok()));
create policy "avatars: dono envia" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.second_factor_ok()));
create policy "avatars: dono troca" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.second_factor_ok()))
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.second_factor_ok()));
create policy "avatars: dono apaga" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.second_factor_ok()));

-- 3. A foto só muda por `profile_photo_set`, `profile_photo_clear` e pelo
-- gatilho do provedor (as três ligam `jayv.profile_photo`). Um `update` direto
-- do cliente em `avatar_url` ou `avatar_custom` é ignorado: a foto não aponta
-- para fora do bucket. O resto do gatilho é o da migração `admin_users`.
create or replace function public.profiles_touch() returns trigger language plpgsql set search_path = '' as $$
begin
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if coalesce(current_setting('jayv.profile_photo', true), '') <> 'on' then
    new.avatar_url := old.avatar_url;
    new.avatar_custom := old.avatar_custom;
  end if;
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

-- 4. O provedor só atualiza a foto de quem não escolheu uma.
create or replace function public.profiles_avatar() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('jayv.profile_photo', 'on', true);
  update public.profiles set avatar_url = public.profile_avatar(new.raw_user_meta_data)
    where user_id = new.id and not avatar_custom;
  perform set_config('jayv.profile_photo', '', true);
  return new;
end;
$$;

-- 5. Grava a foto que a própria conta acabou de enviar. O endereço tem de ser
-- o público de um arquivo que existe na pasta dela no bucket `avatars`.
create function public.profile_photo_set(url text) returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  object text;
begin
  if me is null then raise exception 'site.session.failed'; end if;
  object := substring(coalesce(url, '') from ('^https://[A-Za-z0-9.:-]+/storage/v1/object/public/avatars/(' || me::text || '/[A-Za-z0-9._-]{1,120})$'));
  if object is null or char_length(url) > 500 then raise exception 'site.account.photo.invalid'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = object) then
    raise exception 'site.account.photo.invalid';
  end if;
  perform set_config('jayv.profile_photo', 'on', true);
  update public.profiles p set avatar_url = url, avatar_custom = true where p.user_id = me;
  perform set_config('jayv.profile_photo', '', true);
  return url;
end;
$$;

-- 6. Tira a foto própria: volta a do provedor do último login, ou nenhuma.
create function public.profile_photo_clear() returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  fallback text;
begin
  if me is null then raise exception 'site.session.failed'; end if;
  select public.profile_avatar(u.raw_user_meta_data) into fallback from auth.users u where u.id = me;
  perform set_config('jayv.profile_photo', 'on', true);
  update public.profiles p set avatar_url = fallback, avatar_custom = false where p.user_id = me;
  perform set_config('jayv.profile_photo', '', true);
  return fallback;
end;
$$;

revoke execute on function public.profile_photo_set(text), public.profile_photo_clear() from public, anon;
grant execute on function public.profile_photo_set(text), public.profile_photo_clear() to authenticated;
revoke execute on function public.profiles_avatar() from public, anon, authenticated;
