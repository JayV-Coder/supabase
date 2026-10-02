-- Ajustes rápidos de conta e organização.
--
-- Nome de usuário fixo: a pessoa escolhe o nome uma vez. A primeira gravação
-- do perfil marca `username_set_at` e, dali em diante, o gatilho recusa a
-- troca com `profile.username.locked`. O nome sugerido no cadastro continua
-- livre até essa gravação; os perfis que já existem também (a marca nasce
-- nula), porque o banco não sabe quem escolheu o nome e quem só pulou o passo.
--
-- Organização nova já nasce com a política de privacidade comum: segredos em
-- "Nunca ler" e pastas internas em "Só para modelos locais". Quem gerencia
-- muda ou limpa como qualquer outra política. As organizações que já existem
-- ficam como estão.

alter table public.profiles add column username_set_at timestamptz;

create or replace function public.profiles_touch() returns trigger language plpgsql set search_path = '' as $$
begin
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  new.updated_at := now();
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

create or replace function public.create_organization(name text, slug text) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
begin
  if auth.uid() is null then raise exception 'org.forbidden'; end if;
  if exists (select 1 from public.organizations o where o.slug = lower(btrim(create_organization.slug))) then raise exception 'org.slugTaken'; end if;
  insert into public.organizations (name, slug, created_by) values (btrim(name), lower(btrim(slug)), auth.uid()) returning id into org;
  insert into public.organization_members (org_id, user_id, role) values (org, auth.uid(), 'owner');
  insert into public.organization_llm_policies (org_id, deny, local_only, updated_by) values (
    org,
    array['.env', '*.pem', '.ssh/**', 'secrets/**', '*.key', '*.secret'],
    array['internal/**', 'private/**'],
    auth.uid()
  );
  return org;
end;
$$;

-- Executável travado e nome de usuário fixo, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'agent.command.locked', $json$"Definido pelo JayV para este agente; não pode ser alterado aqui."$json$::jsonb),
  ('pt-BR', 'profile.username.once', $json$"Único no JayV: é por ele que as pessoas encontram você. Depois de salvo, não pode mais ser alterado."$json$::jsonb),
  ('pt-BR', 'profile.username.locked', $json$"Seu nome de usuário é definitivo e não pode ser alterado."$json$::jsonb),
  ('en', 'agent.command.locked', $json$"Set by JayV for this agent; it can't be changed here."$json$::jsonb),
  ('en', 'profile.username.once', $json$"Unique in JayV: it is how people find you. Once saved, it can't be changed."$json$::jsonb),
  ('en', 'profile.username.locked', $json$"Your username is permanent and can't be changed."$json$::jsonb),
  ('es', 'agent.command.locked', $json$"Definido por JayV para este agente; no se puede cambiar aquí."$json$::jsonb),
  ('es', 'profile.username.once', $json$"Único en JayV: así te encuentran las personas. Una vez guardado, no se puede cambiar."$json$::jsonb),
  ('es', 'profile.username.locked', $json$"Tu nombre de usuario es definitivo y no se puede cambiar."$json$::jsonb),
  ('zh-CN', 'agent.command.locked', $json$"由 JayV 为此代理设置，无法在此更改。"$json$::jsonb),
  ('zh-CN', 'profile.username.once', $json$"在 JayV 中唯一：别人通过它找到你。保存后将无法更改。"$json$::jsonb),
  ('zh-CN', 'profile.username.locked', $json$"你的用户名已固定，无法更改。"$json$::jsonb),
  ('hi', 'agent.command.locked', $json$"इस एजेंट के लिए JayV द्वारा सेट; इसे यहाँ बदला नहीं जा सकता।"$json$::jsonb),
  ('hi', 'profile.username.once', $json$"JayV में अद्वितीय: लोग आपको इसी से ढूँढते हैं। सहेजने के बाद इसे बदला नहीं जा सकता।"$json$::jsonb),
  ('hi', 'profile.username.locked', $json$"आपका उपयोगकर्ता नाम स्थायी है और बदला नहीं जा सकता।"$json$::jsonb),
  ('ar', 'agent.command.locked', $json$"يحدده JayV لهذا الوكيل؛ لا يمكن تغييره هنا."$json$::jsonb),
  ('ar', 'profile.username.once', $json$"فريد في JayV: به يجدك الآخرون. بعد الحفظ لا يمكن تغييره."$json$::jsonb),
  ('ar', 'profile.username.locked', $json$"اسم المستخدم الخاص بك نهائي ولا يمكن تغييره."$json$::jsonb),
  ('fr', 'agent.command.locked', $json$"Défini par JayV pour cet agent ; il ne peut pas être modifié ici."$json$::jsonb),
  ('fr', 'profile.username.once', $json$"Unique dans JayV : c'est ainsi qu'on vous trouve. Une fois enregistré, il ne peut plus être modifié."$json$::jsonb),
  ('fr', 'profile.username.locked', $json$"Votre nom d'utilisateur est définitif et ne peut pas être modifié."$json$::jsonb),
  ('ru', 'agent.command.locked', $json$"Задаётся JayV для этого агента; здесь его изменить нельзя."$json$::jsonb),
  ('ru', 'profile.username.once', $json$"Уникально в JayV: по нему вас находят. После сохранения изменить его нельзя."$json$::jsonb),
  ('ru', 'profile.username.locked', $json$"Ваше имя пользователя постоянное и не может быть изменено."$json$::jsonb),
  ('ja', 'agent.command.locked', $json$"このエージェント用に JayV が設定します。ここでは変更できません。"$json$::jsonb),
  ('ja', 'profile.username.once', $json$"JayV で一意の名前で、ほかの人はこの名前であなたを見つけます。保存後は変更できません。"$json$::jsonb),
  ('ja', 'profile.username.locked', $json$"ユーザー名は確定済みのため変更できません。"$json$::jsonb),
  ('de', 'agent.command.locked', $json$"Von JayV für diesen Agenten festgelegt; kann hier nicht geändert werden."$json$::jsonb),
  ('de', 'profile.username.once', $json$"Eindeutig in JayV: Darüber finden dich andere. Nach dem Speichern kann er nicht mehr geändert werden."$json$::jsonb),
  ('de', 'profile.username.locked', $json$"Dein Benutzername ist endgültig und kann nicht geändert werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
