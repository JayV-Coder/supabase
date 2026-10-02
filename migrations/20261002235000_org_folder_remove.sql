-- Remover a pasta da organização neste computador: a aba Repositórios ganha
-- o botão que esquece a pasta guardada. Só traduções: a pasta fica no
-- computador, e os clones e projetos não são tocados.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'repos.folder.remove', $json$"Remover"$json$::jsonb),
  ('pt-BR', 'repos.folder.remove.title', $json$"Remover pasta da organização"$json$::jsonb),
  ('pt-BR', 'repos.folder.remove.description', $json$"Este computador esquece {path} como a pasta desta organização. Os clones e os projetos deles continuam onde estão; o próximo clone pergunta a pasta de novo."$json$::jsonb),
  ('en', 'repos.folder.remove', $json$"Remove"$json$::jsonb),
  ('en', 'repos.folder.remove.title', $json$"Remove organization folder"$json$::jsonb),
  ('en', 'repos.folder.remove.description', $json$"This computer forgets {path} as this organization's folder. The clones and their projects stay where they are; the next clone asks for a folder again."$json$::jsonb),
  ('es', 'repos.folder.remove', $json$"Quitar"$json$::jsonb),
  ('es', 'repos.folder.remove.title', $json$"Quitar carpeta de la organización"$json$::jsonb),
  ('es', 'repos.folder.remove.description', $json$"Este equipo olvida {path} como carpeta de esta organización. Los clones y sus proyectos siguen donde están; el próximo clon vuelve a pedir una carpeta."$json$::jsonb),
  ('zh-CN', 'repos.folder.remove', $json$"移除"$json$::jsonb),
  ('zh-CN', 'repos.folder.remove.title', $json$"移除组织文件夹"$json$::jsonb),
  ('zh-CN', 'repos.folder.remove.description', $json$"本机将不再把 {path} 作为该组织的文件夹。克隆和对应的项目保持不变；下次克隆时会重新询问文件夹。"$json$::jsonb),
  ('hi', 'repos.folder.remove', $json$"हटाएँ"$json$::jsonb),
  ('hi', 'repos.folder.remove.title', $json$"संगठन फ़ोल्डर हटाएँ"$json$::jsonb),
  ('hi', 'repos.folder.remove.description', $json$"यह कंप्यूटर {path} को इस संगठन के फ़ोल्डर के रूप में भूल जाएगा। क्लोन और उनके प्रोजेक्ट जहाँ हैं वहीं रहेंगे; अगला क्लोन फिर से फ़ोल्डर पूछेगा।"$json$::jsonb),
  ('ar', 'repos.folder.remove', $json$"إزالة"$json$::jsonb),
  ('ar', 'repos.folder.remove.title', $json$"إزالة مجلد المؤسسة"$json$::jsonb),
  ('ar', 'repos.folder.remove.description', $json$"سينسى هذا الحاسوب {path} بوصفه مجلد هذه المؤسسة. تبقى النسخ ومشاريعها في مكانها؛ وسيطلب الاستنساخ التالي مجلدًا من جديد."$json$::jsonb),
  ('fr', 'repos.folder.remove', $json$"Retirer"$json$::jsonb),
  ('fr', 'repos.folder.remove.title', $json$"Retirer le dossier de l'organisation"$json$::jsonb),
  ('fr', 'repos.folder.remove.description', $json$"Cet ordinateur oublie {path} comme dossier de cette organisation. Les clones et leurs projets restent où ils sont ; le prochain clonage redemandera un dossier."$json$::jsonb),
  ('ru', 'repos.folder.remove', $json$"Убрать"$json$::jsonb),
  ('ru', 'repos.folder.remove.title', $json$"Убрать папку организации"$json$::jsonb),
  ('ru', 'repos.folder.remove.description', $json$"Этот компьютер забудет {path} как папку этой организации. Клоны и их проекты останутся на месте; при следующем клонировании папка будет запрошена снова."$json$::jsonb),
  ('ja', 'repos.folder.remove', $json$"削除"$json$::jsonb),
  ('ja', 'repos.folder.remove.title', $json$"組織フォルダーを削除"$json$::jsonb),
  ('ja', 'repos.folder.remove.description', $json$"このコンピューターは {path} をこの組織のフォルダーとして記憶しなくなります。クローンとそのプロジェクトはそのまま残り、次のクローン時に再びフォルダーを尋ねます。"$json$::jsonb),
  ('de', 'repos.folder.remove', $json$"Entfernen"$json$::jsonb),
  ('de', 'repos.folder.remove.title', $json$"Organisationsordner entfernen"$json$::jsonb),
  ('de', 'repos.folder.remove.description', $json$"Dieser Computer vergisst {path} als Ordner dieser Organisation. Die Klone und ihre Projekte bleiben, wo sie sind; beim nächsten Klonen wird wieder nach einem Ordner gefragt."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
