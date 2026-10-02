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

-- Nome de usuário, data em partes e abas do perfil, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'profile.field.username', $json$"Nome de usuário"$json$::jsonb),
  ('pt-BR', 'profile.field.username.hint', $json$"Único no JayV: é como as pessoas encontram você."$json$::jsonb),
  ('pt-BR', 'profile.username.invalid', $json$"Use de {min} a {max} letras minúsculas, dígitos, _ ou -, começando e terminando com letra ou dígito."$json$::jsonb),
  ('pt-BR', 'profile.username.checking', $json$"Verificando disponibilidade…"$json$::jsonb),
  ('pt-BR', 'profile.username.available', $json$"Disponível."$json$::jsonb),
  ('pt-BR', 'profile.usernameTaken', $json$"Este nome de usuário já está em uso."$json$::jsonb),
  ('pt-BR', 'profile.birthDate.hint', $json$"Dia, mês e ano. Só é salva com os três escolhidos."$json$::jsonb),
  ('pt-BR', 'profile.birthDate.day', $json$"Dia"$json$::jsonb),
  ('pt-BR', 'profile.birthDate.month', $json$"Mês"$json$::jsonb),
  ('pt-BR', 'profile.birthDate.year', $json$"Ano"$json$::jsonb),
  ('pt-BR', 'profile.birthDate.clear', $json$"Limpar data"$json$::jsonb),
  ('pt-BR', 'profile.tab.overview', $json$"Visão geral"$json$::jsonb),
  ('pt-BR', 'profile.tab.data', $json$"Dados pessoais"$json$::jsonb),
  ('pt-BR', 'profile.tab.security', $json$"Segurança"$json$::jsonb),
  ('pt-BR', 'profile.tab.linked', $json$"Contas vinculadas"$json$::jsonb),
  ('en', 'profile.field.username', $json$"Username"$json$::jsonb),
  ('en', 'profile.field.username.hint', $json$"Unique in JayV: it is how people find you."$json$::jsonb),
  ('en', 'profile.username.invalid', $json$"Use {min} to {max} lowercase letters, digits, _ or -, starting and ending with a letter or digit."$json$::jsonb),
  ('en', 'profile.username.checking', $json$"Checking availability…"$json$::jsonb),
  ('en', 'profile.username.available', $json$"Available."$json$::jsonb),
  ('en', 'profile.usernameTaken', $json$"This username is already taken."$json$::jsonb),
  ('en', 'profile.birthDate.hint', $json$"Day, month and year. Saved only when all three are chosen."$json$::jsonb),
  ('en', 'profile.birthDate.day', $json$"Day"$json$::jsonb),
  ('en', 'profile.birthDate.month', $json$"Month"$json$::jsonb),
  ('en', 'profile.birthDate.year', $json$"Year"$json$::jsonb),
  ('en', 'profile.birthDate.clear', $json$"Clear date"$json$::jsonb),
  ('en', 'profile.tab.overview', $json$"Overview"$json$::jsonb),
  ('en', 'profile.tab.data', $json$"Personal data"$json$::jsonb),
  ('en', 'profile.tab.security', $json$"Security"$json$::jsonb),
  ('en', 'profile.tab.linked', $json$"Linked accounts"$json$::jsonb),
  ('es', 'profile.field.username', $json$"Nombre de usuario"$json$::jsonb),
  ('es', 'profile.field.username.hint', $json$"Único en JayV: así te encuentran los demás."$json$::jsonb),
  ('es', 'profile.username.invalid', $json$"Usa de {min} a {max} minúsculas, dígitos, _ o -, empezando y terminando con letra o dígito."$json$::jsonb),
  ('es', 'profile.username.checking', $json$"Comprobando disponibilidad…"$json$::jsonb),
  ('es', 'profile.username.available', $json$"Disponible."$json$::jsonb),
  ('es', 'profile.usernameTaken', $json$"Este nombre de usuario ya está en uso."$json$::jsonb),
  ('es', 'profile.birthDate.hint', $json$"Día, mes y año. Solo se guarda con los tres elegidos."$json$::jsonb),
  ('es', 'profile.birthDate.day', $json$"Día"$json$::jsonb),
  ('es', 'profile.birthDate.month', $json$"Mes"$json$::jsonb),
  ('es', 'profile.birthDate.year', $json$"Año"$json$::jsonb),
  ('es', 'profile.birthDate.clear', $json$"Borrar fecha"$json$::jsonb),
  ('es', 'profile.tab.overview', $json$"Resumen"$json$::jsonb),
  ('es', 'profile.tab.data', $json$"Datos personales"$json$::jsonb),
  ('es', 'profile.tab.security', $json$"Seguridad"$json$::jsonb),
  ('es', 'profile.tab.linked', $json$"Cuentas vinculadas"$json$::jsonb),
  ('zh-CN', 'profile.field.username', $json$"用户名"$json$::jsonb),
  ('zh-CN', 'profile.field.username.hint', $json$"在 JayV 中唯一：别人通过它找到你。"$json$::jsonb),
  ('zh-CN', 'profile.username.invalid', $json$"请使用 {min} 到 {max} 个小写字母、数字、_ 或 -，且以字母或数字开头和结尾。"$json$::jsonb),
  ('zh-CN', 'profile.username.checking', $json$"正在检查是否可用…"$json$::jsonb),
  ('zh-CN', 'profile.username.available', $json$"可以使用。"$json$::jsonb),
  ('zh-CN', 'profile.usernameTaken', $json$"该用户名已被占用。"$json$::jsonb),
  ('zh-CN', 'profile.birthDate.hint', $json$"日、月、年。三项都选好后才会保存。"$json$::jsonb),
  ('zh-CN', 'profile.birthDate.day', $json$"日"$json$::jsonb),
  ('zh-CN', 'profile.birthDate.month', $json$"月"$json$::jsonb),
  ('zh-CN', 'profile.birthDate.year', $json$"年"$json$::jsonb),
  ('zh-CN', 'profile.birthDate.clear', $json$"清除日期"$json$::jsonb),
  ('zh-CN', 'profile.tab.overview', $json$"概览"$json$::jsonb),
  ('zh-CN', 'profile.tab.data', $json$"个人信息"$json$::jsonb),
  ('zh-CN', 'profile.tab.security', $json$"安全"$json$::jsonb),
  ('zh-CN', 'profile.tab.linked', $json$"已关联账户"$json$::jsonb),
  ('hi', 'profile.field.username', $json$"उपयोगकर्ता नाम"$json$::jsonb),
  ('hi', 'profile.field.username.hint', $json$"JayV में अनोखा: लोग आपको इसी से ढूँढते हैं।"$json$::jsonb),
  ('hi', 'profile.username.invalid', $json$"{min} से {max} छोटे अक्षर, अंक, _ या - इस्तेमाल करें, शुरू और अंत अक्षर या अंक से हो।"$json$::jsonb),
  ('hi', 'profile.username.checking', $json$"उपलब्धता जाँची जा रही है…"$json$::jsonb),
  ('hi', 'profile.username.available', $json$"उपलब्ध है।"$json$::jsonb),
  ('hi', 'profile.usernameTaken', $json$"यह उपयोगकर्ता नाम पहले से लिया जा चुका है।"$json$::jsonb),
  ('hi', 'profile.birthDate.hint', $json$"दिन, महीना और साल। तीनों चुनने पर ही सहेजी जाती है।"$json$::jsonb),
  ('hi', 'profile.birthDate.day', $json$"दिन"$json$::jsonb),
  ('hi', 'profile.birthDate.month', $json$"महीना"$json$::jsonb),
  ('hi', 'profile.birthDate.year', $json$"साल"$json$::jsonb),
  ('hi', 'profile.birthDate.clear', $json$"तारीख हटाएँ"$json$::jsonb),
  ('hi', 'profile.tab.overview', $json$"सारांश"$json$::jsonb),
  ('hi', 'profile.tab.data', $json$"व्यक्तिगत जानकारी"$json$::jsonb),
  ('hi', 'profile.tab.security', $json$"सुरक्षा"$json$::jsonb),
  ('hi', 'profile.tab.linked', $json$"जुड़े हुए खाते"$json$::jsonb),
  ('ar', 'profile.field.username', $json$"اسم المستخدم"$json$::jsonb),
  ('ar', 'profile.field.username.hint', $json$"فريد في JayV: هكذا يعثر عليك الآخرون."$json$::jsonb),
  ('ar', 'profile.username.invalid', $json$"استخدم من {min} إلى {max} من الأحرف الصغيرة أو الأرقام أو _ أو -، مع البدء والانتهاء بحرف أو رقم."$json$::jsonb),
  ('ar', 'profile.username.checking', $json$"جارٍ التحقق من التوفر…"$json$::jsonb),
  ('ar', 'profile.username.available', $json$"متاح."$json$::jsonb),
  ('ar', 'profile.usernameTaken', $json$"اسم المستخدم هذا مستخدم بالفعل."$json$::jsonb),
  ('ar', 'profile.birthDate.hint', $json$"اليوم والشهر والسنة. لا تُحفظ إلا عند اختيار الثلاثة."$json$::jsonb),
  ('ar', 'profile.birthDate.day', $json$"اليوم"$json$::jsonb),
  ('ar', 'profile.birthDate.month', $json$"الشهر"$json$::jsonb),
  ('ar', 'profile.birthDate.year', $json$"السنة"$json$::jsonb),
  ('ar', 'profile.birthDate.clear', $json$"مسح التاريخ"$json$::jsonb),
  ('ar', 'profile.tab.overview', $json$"نظرة عامة"$json$::jsonb),
  ('ar', 'profile.tab.data', $json$"البيانات الشخصية"$json$::jsonb),
  ('ar', 'profile.tab.security', $json$"الأمان"$json$::jsonb),
  ('ar', 'profile.tab.linked', $json$"الحسابات المرتبطة"$json$::jsonb),
  ('fr', 'profile.field.username', $json$"Nom d'utilisateur"$json$::jsonb),
  ('fr', 'profile.field.username.hint', $json$"Unique dans JayV : c'est ainsi qu'on vous trouve."$json$::jsonb),
  ('fr', 'profile.username.invalid', $json$"Utilisez {min} à {max} minuscules, chiffres, _ ou -, en commençant et finissant par une lettre ou un chiffre."$json$::jsonb),
  ('fr', 'profile.username.checking', $json$"Vérification de la disponibilité…"$json$::jsonb),
  ('fr', 'profile.username.available', $json$"Disponible."$json$::jsonb),
  ('fr', 'profile.usernameTaken', $json$"Ce nom d'utilisateur est déjà pris."$json$::jsonb),
  ('fr', 'profile.birthDate.hint', $json$"Jour, mois et année. Enregistrée seulement quand les trois sont choisis."$json$::jsonb),
  ('fr', 'profile.birthDate.day', $json$"Jour"$json$::jsonb),
  ('fr', 'profile.birthDate.month', $json$"Mois"$json$::jsonb),
  ('fr', 'profile.birthDate.year', $json$"Année"$json$::jsonb),
  ('fr', 'profile.birthDate.clear', $json$"Effacer la date"$json$::jsonb),
  ('fr', 'profile.tab.overview', $json$"Vue d'ensemble"$json$::jsonb),
  ('fr', 'profile.tab.data', $json$"Données personnelles"$json$::jsonb),
  ('fr', 'profile.tab.security', $json$"Sécurité"$json$::jsonb),
  ('fr', 'profile.tab.linked', $json$"Comptes liés"$json$::jsonb),
  ('ru', 'profile.field.username', $json$"Имя пользователя"$json$::jsonb),
  ('ru', 'profile.field.username.hint', $json$"Уникально в JayV: по нему вас находят."$json$::jsonb),
  ('ru', 'profile.username.invalid', $json$"Используйте от {min} до {max} строчных букв, цифр, _ или -; начало и конец — буква или цифра."$json$::jsonb),
  ('ru', 'profile.username.checking', $json$"Проверяем доступность…"$json$::jsonb),
  ('ru', 'profile.username.available', $json$"Доступно."$json$::jsonb),
  ('ru', 'profile.usernameTaken', $json$"Это имя пользователя уже занято."$json$::jsonb),
  ('ru', 'profile.birthDate.hint', $json$"День, месяц и год. Сохраняется, только когда выбраны все три."$json$::jsonb),
  ('ru', 'profile.birthDate.day', $json$"День"$json$::jsonb),
  ('ru', 'profile.birthDate.month', $json$"Месяц"$json$::jsonb),
  ('ru', 'profile.birthDate.year', $json$"Год"$json$::jsonb),
  ('ru', 'profile.birthDate.clear', $json$"Очистить дату"$json$::jsonb),
  ('ru', 'profile.tab.overview', $json$"Обзор"$json$::jsonb),
  ('ru', 'profile.tab.data', $json$"Личные данные"$json$::jsonb),
  ('ru', 'profile.tab.security', $json$"Безопасность"$json$::jsonb),
  ('ru', 'profile.tab.linked', $json$"Привязанные аккаунты"$json$::jsonb),
  ('ja', 'profile.field.username', $json$"ユーザー名"$json$::jsonb),
  ('ja', 'profile.field.username.hint', $json$"JayV 内で一意です。ほかの人はこの名前であなたを見つけます。"$json$::jsonb),
  ('ja', 'profile.username.invalid', $json$"小文字・数字・_・- を {min}〜{max} 文字で、先頭と末尾は英字か数字にしてください。"$json$::jsonb),
  ('ja', 'profile.username.checking', $json$"利用可能か確認しています…"$json$::jsonb),
  ('ja', 'profile.username.available', $json$"利用できます。"$json$::jsonb),
  ('ja', 'profile.usernameTaken', $json$"このユーザー名は既に使われています。"$json$::jsonb),
  ('ja', 'profile.birthDate.hint', $json$"日・月・年。3 つすべてを選ぶと保存されます。"$json$::jsonb),
  ('ja', 'profile.birthDate.day', $json$"日"$json$::jsonb),
  ('ja', 'profile.birthDate.month', $json$"月"$json$::jsonb),
  ('ja', 'profile.birthDate.year', $json$"年"$json$::jsonb),
  ('ja', 'profile.birthDate.clear', $json$"日付をクリア"$json$::jsonb),
  ('ja', 'profile.tab.overview', $json$"概要"$json$::jsonb),
  ('ja', 'profile.tab.data', $json$"個人情報"$json$::jsonb),
  ('ja', 'profile.tab.security', $json$"セキュリティ"$json$::jsonb),
  ('ja', 'profile.tab.linked', $json$"連携アカウント"$json$::jsonb),
  ('de', 'profile.field.username', $json$"Benutzername"$json$::jsonb),
  ('de', 'profile.field.username.hint', $json$"Eindeutig in JayV: So finden dich andere."$json$::jsonb),
  ('de', 'profile.username.invalid', $json$"Verwende {min} bis {max} Kleinbuchstaben, Ziffern, _ oder -, beginnend und endend mit Buchstabe oder Ziffer."$json$::jsonb),
  ('de', 'profile.username.checking', $json$"Verfügbarkeit wird geprüft…"$json$::jsonb),
  ('de', 'profile.username.available', $json$"Verfügbar."$json$::jsonb),
  ('de', 'profile.usernameTaken', $json$"Dieser Benutzername ist bereits vergeben."$json$::jsonb),
  ('de', 'profile.birthDate.hint', $json$"Tag, Monat und Jahr. Wird erst gespeichert, wenn alle drei gewählt sind."$json$::jsonb),
  ('de', 'profile.birthDate.day', $json$"Tag"$json$::jsonb),
  ('de', 'profile.birthDate.month', $json$"Monat"$json$::jsonb),
  ('de', 'profile.birthDate.year', $json$"Jahr"$json$::jsonb),
  ('de', 'profile.birthDate.clear', $json$"Datum löschen"$json$::jsonb),
  ('de', 'profile.tab.overview', $json$"Übersicht"$json$::jsonb),
  ('de', 'profile.tab.data', $json$"Persönliche Daten"$json$::jsonb),
  ('de', 'profile.tab.security', $json$"Sicherheit"$json$::jsonb),
  ('de', 'profile.tab.linked', $json$"Verknüpfte Konten"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
