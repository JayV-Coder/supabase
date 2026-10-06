-- Site 2.0.1: conectar o GitHub começa pela autorização (que sempre volta ao
-- site) e a organização do GitHub é escolhida no site, entre as instalações
-- do GitHub App. Instalar em outra conta ou organização abre a tela do GitHub
-- numa aba nova, porque numa instalação que já existe o GitHub não volta.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.org.git.namespace.install', $json$"Instalar o GitHub App em outra conta ou organização"$json$::jsonb),
  ('pt-BR', 'site.org.git.namespace.installHint', $json$"O GitHub abre numa aba nova. Depois de instalar, volte para esta aba e a lista se atualiza."$json$::jsonb),
  ('en', 'site.org.git.namespace.install', $json$"Install the GitHub App on another account or organization"$json$::jsonb),
  ('en', 'site.org.git.namespace.installHint', $json$"GitHub opens in a new tab. After installing, come back to this tab and the list updates."$json$::jsonb),
  ('es', 'site.org.git.namespace.install', $json$"Instalar la GitHub App en otra cuenta u organización"$json$::jsonb),
  ('es', 'site.org.git.namespace.installHint', $json$"GitHub se abre en una pestaña nueva. Después de instalar, vuelve a esta pestaña y la lista se actualiza."$json$::jsonb),
  ('zh-CN', 'site.org.git.namespace.install', $json$"在其他账户或组织中安装 GitHub App"$json$::jsonb),
  ('zh-CN', 'site.org.git.namespace.installHint', $json$"GitHub 会在新标签页中打开。安装完成后，回到此标签页，列表会自动更新。"$json$::jsonb),
  ('hi', 'site.org.git.namespace.install', $json$"GitHub App को किसी दूसरे खाते या संगठन में इंस्टॉल करें"$json$::jsonb),
  ('hi', 'site.org.git.namespace.installHint', $json$"GitHub एक नए टैब में खुलता है। इंस्टॉल करने के बाद इस टैब पर लौटें, सूची अपडेट हो जाएगी।"$json$::jsonb),
  ('ar', 'site.org.git.namespace.install', $json$"ثبّت تطبيق GitHub في حساب أو مؤسسة أخرى"$json$::jsonb),
  ('ar', 'site.org.git.namespace.installHint', $json$"يُفتح GitHub في علامة تبويب جديدة. بعد التثبيت، عُد إلى علامة التبويب هذه وستتحدّث القائمة."$json$::jsonb),
  ('fr', 'site.org.git.namespace.install', $json$"Installer la GitHub App sur un autre compte ou une autre organisation"$json$::jsonb),
  ('fr', 'site.org.git.namespace.installHint', $json$"GitHub s'ouvre dans un nouvel onglet. Après l'installation, revenez sur cet onglet et la liste se met à jour."$json$::jsonb),
  ('ru', 'site.org.git.namespace.install', $json$"Установить GitHub App в другой аккаунт или организацию"$json$::jsonb),
  ('ru', 'site.org.git.namespace.installHint', $json$"GitHub откроется в новой вкладке. После установки вернитесь на эту вкладку, и список обновится."$json$::jsonb),
  ('ja', 'site.org.git.namespace.install', $json$"GitHub App を別のアカウントまたは組織にインストール"$json$::jsonb),
  ('ja', 'site.org.git.namespace.installHint', $json$"GitHub は新しいタブで開きます。インストール後、このタブに戻るとリストが更新されます。"$json$::jsonb),
  ('de', 'site.org.git.namespace.install', $json$"Die GitHub App in einem anderen Konto oder einer anderen Organisation installieren"$json$::jsonb),
  ('de', 'site.org.git.namespace.installHint', $json$"GitHub öffnet sich in einem neuen Tab. Kehre nach der Installation zu diesem Tab zurück, dann wird die Liste aktualisiert."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
