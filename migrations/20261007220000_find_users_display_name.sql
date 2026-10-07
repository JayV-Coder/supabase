-- site v2.5.0 e app v0.83.1. A busca para convidar à organização acha pelo
-- `@usuário` e também pelo nome de exibição, em qualquer parte do texto e sem
-- diferenciar maiúsculas; o e-mail continua fora da busca. Primeiro vêm o
-- usuário exato e os que começam com o texto, depois os que só o contêm.
create or replace function public.find_users(query text)
returns table (user_id uuid, username text, display_name text, avatar_url text)
language plpgsql stable security definer set search_path = '' as $$
declare
  wanted text := ltrim(lower(btrim(query)), '@');
  pattern text;
begin
  if auth.uid() is null or char_length(wanted) < 2 then return; end if;
  pattern := replace(replace(replace(wanted, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select p.user_id, p.username, p.display_name, p.avatar_url
    from public.profiles p
    where lower(p.username) like '%' || pattern || '%'
       or lower(p.display_name) like '%' || pattern || '%'
    order by
      (lower(p.username) = wanted) desc,
      (lower(p.username) like pattern || '%') desc,
      (lower(p.display_name) like pattern || '%') desc,
      char_length(p.username), p.username
    limit 8;
end;
$$;

update public.translations set value = case locale
  when 'pt-BR' then $json$"Digite ao menos 2 caracteres do nome de usuário ou do nome para buscar."$json$::jsonb
  when 'en' then $json$"Type at least 2 characters of the username or name to search."$json$::jsonb
  when 'es' then $json$"Escribe al menos 2 caracteres del nombre de usuario o del nombre para buscar."$json$::jsonb
  when 'zh-CN' then $json$"输入用户名或姓名的至少 2 个字符即可搜索。"$json$::jsonb
  when 'hi' then $json$"खोजने के लिए उपयोगकर्ता नाम या नाम के कम से कम 2 अक्षर लिखें।"$json$::jsonb
  when 'ar' then $json$"اكتب حرفين على الأقل من اسم المستخدم أو الاسم للبحث."$json$::jsonb
  when 'fr' then $json$"Saisissez au moins 2 caractères du nom d’utilisateur ou du nom pour chercher."$json$::jsonb
  when 'ru' then $json$"Введите не менее 2 символов имени пользователя или имени для поиска."$json$::jsonb
  when 'ja' then $json$"検索するには、ユーザー名または表示名を 2 文字以上入力してください。"$json$::jsonb
  when 'de' then $json$"Geben Sie mindestens 2 Zeichen des Benutzernamens oder Namens ein, um zu suchen."$json$::jsonb
end
where key = 'org.invite.hint' and locale in ('pt-BR','en','es','zh-CN','hi','ar','fr','ru','ja','de');

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.backMark.title', $json$"Um só botão de voltar em todo o app"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.backMark.detail', $json$"Todos os botões de voltar do app (organização, todos os projetos, tutorial, perguntas ao agente, entrar) agora usam o mesmo ❯ verde apontando para a esquerda que o site usa, nos temas claro e escuro."$json$::jsonb),
  ('en', 'whatsNew.item.backMark.title', $json$"One back button everywhere"$json$::jsonb),
  ('en', 'whatsNew.item.backMark.detail', $json$"Every back button in the app (organization, all projects, tutorial, questions to the agent, sign-in) now uses the same green ❯ pointing left that the site uses, in both light and dark themes."$json$::jsonb),
  ('es', 'whatsNew.item.backMark.title', $json$"Un solo botón de volver en toda la app"$json$::jsonb),
  ('es', 'whatsNew.item.backMark.detail', $json$"Todos los botones de volver de la app (organización, todos los proyectos, tutorial, preguntas al agente, iniciar sesión) usan ahora el mismo ❯ verde que apunta a la izquierda que usa el sitio, en los temas claro y oscuro."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.backMark.title', $json$"全应用统一的返回按钮"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.backMark.detail', $json$"应用中所有返回按钮（组织、所有项目、教程、向智能体的提问、登录）现在都使用与网站相同的、指向左侧的绿色 ❯，浅色和深色主题均适用。"$json$::jsonb),
  ('hi', 'whatsNew.item.backMark.title', $json$"हर जगह एक जैसा वापस जाने का बटन"$json$::jsonb),
  ('hi', 'whatsNew.item.backMark.detail', $json$"ऐप के सभी वापस जाने के बटन (संगठन, सभी प्रोजेक्ट, ट्यूटोरियल, एजेंट से सवाल, साइन-इन) अब वही हरा ❯ इस्तेमाल करते हैं जो साइट पर बाईं ओर इशारा करता है, हल्की और गहरी दोनों थीम में।"$json$::jsonb),
  ('ar', 'whatsNew.item.backMark.title', $json$"زر رجوع موحّد في كل مكان"$json$::jsonb),
  ('ar', 'whatsNew.item.backMark.detail', $json$"تستخدم الآن جميع أزرار الرجوع في التطبيق (المنظمة، كل المشاريع، الدليل التعليمي، أسئلة الوكيل، تسجيل الدخول) علامة ❯ الخضراء نفسها المتجهة إلى اليسار كما في الموقع، في السمتين الفاتحة والداكنة."$json$::jsonb),
  ('fr', 'whatsNew.item.backMark.title', $json$"Un seul bouton retour partout"$json$::jsonb),
  ('fr', 'whatsNew.item.backMark.detail', $json$"Tous les boutons retour de l’app (organisation, tous les projets, tutoriel, questions à l’agent, connexion) utilisent désormais le même ❯ vert pointant vers la gauche que le site, en thème clair comme sombre."$json$::jsonb),
  ('ru', 'whatsNew.item.backMark.title', $json$"Единая кнопка «Назад» везде"$json$::jsonb),
  ('ru', 'whatsNew.item.backMark.detail', $json$"Все кнопки «Назад» в приложении (организация, все проекты, обучение, вопросы агенту, вход) теперь используют тот же зелёный ❯, направленный влево, что и сайт, в светлой и тёмной темах."$json$::jsonb),
  ('ja', 'whatsNew.item.backMark.title', $json$"どこでも同じ「戻る」ボタン"$json$::jsonb),
  ('ja', 'whatsNew.item.backMark.detail', $json$"アプリ内のすべての「戻る」ボタン（組織、すべてのプロジェクト、チュートリアル、エージェントへの質問、サインイン）が、サイトと同じ左向きの緑の ❯ になりました。ライト・ダークどちらのテーマでも同じです。"$json$::jsonb),
  ('de', 'whatsNew.item.backMark.title', $json$"Überall derselbe Zurück-Button"$json$::jsonb),
  ('de', 'whatsNew.item.backMark.detail', $json$"Alle Zurück-Buttons der App (Organisation, alle Projekte, Tutorial, Fragen an den Agenten, Anmeldung) verwenden jetzt dasselbe grüne, nach links zeigende ❯ wie die Website – im hellen und im dunklen Design."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
