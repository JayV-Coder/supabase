-- A foto de perfil própria: vale em todo login, só muda pelas funções e só
-- aponta para a pasta da conta no bucket `avatars`.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'gh@teste.local', '{"name":"Octo","avatar_url":"https://avatars.example/octo.png"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'mail@teste.local', '{}');

create function pg_temp.as_user(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated', 'aal', 'aal1')::text, true);
$$;

select is((select public from storage.buckets where id = 'avatars'), true, 'o bucket das fotos é público para leitura');
select is((select avatar_url from public.profiles where user_id = '00000000-0000-0000-0000-0000000000c1'), 'https://avatars.example/octo.png', 'sem foto própria, vale a do provedor');

-- O arquivo enviado pelo Storage (aqui direto na tabela).
insert into storage.objects (bucket_id, name) values
  ('avatars', '00000000-0000-0000-0000-0000000000c1/photo-1.webp'),
  ('avatars', '00000000-0000-0000-0000-0000000000c2/photo-1.webp');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select throws_ok($$ select public.profile_photo_set('https://p.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000000c2/photo-1.webp') $$,
  'P0001', 'site.account.photo.invalid', 'a foto de outra conta não serve');
select throws_ok($$ select public.profile_photo_set('https://p.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000000c1/missing.webp') $$,
  'P0001', 'site.account.photo.invalid', 'um arquivo que não existe no bucket não serve');
select throws_ok($$ select public.profile_photo_set('https://evil.example/avatar.png') $$,
  'P0001', 'site.account.photo.invalid', 'um endereço fora do Storage não serve');
select lives_ok($$ select public.profile_photo_set('https://p.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000000c1/photo-1.webp') $$,
  'a foto da própria pasta vale');
select is((select (avatar_url, avatar_custom)::text from public.profiles), '(https://p.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000000c1/photo-1.webp,t)', 'a foto própria fica gravada');

update public.profiles set avatar_url = 'https://evil.example/x.png', avatar_custom = false, display_name = 'Octo Cat';
select is((select (avatar_url like '%/photo-1.webp', avatar_custom, display_name)::text from public.profiles), '(t,t,"Octo Cat")', 'o update direto não troca a foto, só o resto');

reset role;
-- Um novo login pelo provedor reescreve os metadados.
update auth.users set raw_user_meta_data = '{"name":"Octo","avatar_url":"https://avatars.example/octo-new.png"}' where id = '00000000-0000-0000-0000-0000000000c1';
select ok((select avatar_url like '%/photo-1.webp' from public.profiles where user_id = '00000000-0000-0000-0000-0000000000c1'), 'o login pelo provedor não troca a foto própria');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select is(public.profile_photo_clear(), 'https://avatars.example/octo-new.png', 'tirar a foto volta para a do provedor');
select is((select (avatar_url, avatar_custom)::text from public.profiles), '(https://avatars.example/octo-new.png,f)', 'e a foto volta a seguir o provedor');

-- A conta de e-mail e senha, sem provedor.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select lives_ok($$ select public.profile_photo_set('https://p.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000000c2/photo-1.webp') $$,
  'a conta de e-mail e senha também escolhe foto');
select is(public.profile_photo_clear(), null, 'sem provedor, tirar a foto deixa sem foto');

-- O Storage: cada conta só na própria pasta.
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-0000-0000-0000000000c2/photo-2.webp') $$, 'envia para a própria pasta');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-0000-0000-0000000000c1/photo-9.webp') $$, '42501', null, 'não envia para a pasta de outra conta');
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 2::bigint, 'só lista a própria pasta');

reset role;
select * from finish();
rollback;
