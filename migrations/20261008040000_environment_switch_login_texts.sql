-- App 0.87.1: Novidades da correção do erro de login ao trocar de ambiente, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.environmentSwitchLogin.title', $json$"Trocar de ambiente não mostra mais erro de login"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.environmentSwitchLogin.detail', $json$"Trocar para o ambiente de uma organização recarregava a janela e tentava usar de novo o link de login, o que terminava em \"PKCE code verifier not found\". Cada link de login agora é usado uma vez só."$json$::jsonb),
  ('en', 'whatsNew.item.environmentSwitchLogin.title', $json$"Switching environment no longer shows a sign-in error"$json$::jsonb),
  ('en', 'whatsNew.item.environmentSwitchLogin.detail', $json$"Switching to an organization's environment reloaded the window and tried to use the sign-in link again, which ended in \"PKCE code verifier not found\". Each sign-in link is now used only once."$json$::jsonb),
  ('es', 'whatsNew.item.environmentSwitchLogin.title', $json$"Cambiar de entorno ya no muestra un error de inicio de sesión"$json$::jsonb),
  ('es', 'whatsNew.item.environmentSwitchLogin.detail', $json$"Cambiar al entorno de una organización recargaba la ventana e intentaba usar de nuevo el enlace de inicio de sesión, lo que terminaba en \"PKCE code verifier not found\". Ahora cada enlace de inicio de sesión se usa una sola vez."$json$::jsonb),
  ('fr', 'whatsNew.item.environmentSwitchLogin.title', $json$"Changer d'environnement n'affiche plus d'erreur de connexion"$json$::jsonb),
  ('fr', 'whatsNew.item.environmentSwitchLogin.detail', $json$"Passer à l'environnement d'une organisation rechargeait la fenêtre et réutilisait le lien de connexion, ce qui finissait par \"PKCE code verifier not found\". Chaque lien de connexion n'est désormais utilisé qu'une seule fois."$json$::jsonb),
  ('de', 'whatsNew.item.environmentSwitchLogin.title', $json$"Der Umgebungswechsel zeigt keinen Anmeldefehler mehr"$json$::jsonb),
  ('de', 'whatsNew.item.environmentSwitchLogin.detail', $json$"Beim Wechsel in die Umgebung einer Organisation wurde das Fenster neu geladen und der Anmeldelink erneut verwendet, was mit \"PKCE code verifier not found\" endete. Jeder Anmeldelink wird jetzt nur noch einmal verwendet."$json$::jsonb),
  ('ru', 'whatsNew.item.environmentSwitchLogin.title', $json$"Переключение среды больше не показывает ошибку входа"$json$::jsonb),
  ('ru', 'whatsNew.item.environmentSwitchLogin.detail', $json$"При переключении на среду организации окно перезагружалось и снова пыталось использовать ссылку входа, что заканчивалось ошибкой \"PKCE code verifier not found\". Теперь каждая ссылка входа используется только один раз."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.environmentSwitchLogin.title', $json$"切换环境不再显示登录错误"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.environmentSwitchLogin.detail', $json$"切换到组织的环境会重新加载窗口并再次使用登录链接，最终出现“PKCE code verifier not found”。现在每个登录链接只会使用一次。"$json$::jsonb),
  ('ja', 'whatsNew.item.environmentSwitchLogin.title', $json$"環境の切り替えでサインインエラーが出なくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.environmentSwitchLogin.detail', $json$"組織の環境に切り替えるとウィンドウが再読み込みされ、サインインリンクが再度使われて「PKCE code verifier not found」になっていました。サインインリンクは 1 回だけ使われるようになりました。"$json$::jsonb),
  ('hi', 'whatsNew.item.environmentSwitchLogin.title', $json$"परिवेश बदलने पर अब साइन-इन त्रुटि नहीं दिखती"$json$::jsonb),
  ('hi', 'whatsNew.item.environmentSwitchLogin.detail', $json$"किसी संगठन के परिवेश पर जाने से विंडो फिर से लोड होती थी और साइन-इन लिंक दोबारा इस्तेमाल होता था, जिसका अंत \"PKCE code verifier not found\" में होता था। अब हर साइन-इन लिंक केवल एक बार इस्तेमाल होता है।"$json$::jsonb),
  ('ar', 'whatsNew.item.environmentSwitchLogin.title', $json$"تبديل البيئة لم يعد يعرض خطأ في تسجيل الدخول"$json$::jsonb),
  ('ar', 'whatsNew.item.environmentSwitchLogin.detail', $json$"كان التبديل إلى بيئة مؤسسة يعيد تحميل النافذة ويحاول استخدام رابط تسجيل الدخول مرة أخرى، فينتهي بالخطأ \"PKCE code verifier not found\". صار كل رابط تسجيل دخول يُستخدم مرة واحدة فقط."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
