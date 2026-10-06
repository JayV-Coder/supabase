-- v0.71.1: abas das Configurações na vertical, à esquerda do conteúdo (texto
-- das Novidades, nos dez idiomas).

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.settingsSideTabs.title', $json$"Abas das Configurações à esquerda"$json$::jsonb),
  ('en', 'whatsNew.item.settingsSideTabs.title', $json$"Settings tabs on the left"$json$::jsonb),
  ('es', 'whatsNew.item.settingsSideTabs.title', $json$"Pestañas de Ajustes a la izquierda"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.settingsSideTabs.title', $json$"设置标签页移到左侧"$json$::jsonb),
  ('hi', 'whatsNew.item.settingsSideTabs.title', $json$"सेटिंग्स के टैब बाईं ओर"$json$::jsonb),
  ('ar', 'whatsNew.item.settingsSideTabs.title', $json$"تبويبات الإعدادات على اليسار"$json$::jsonb),
  ('fr', 'whatsNew.item.settingsSideTabs.title', $json$"Onglets des réglages à gauche"$json$::jsonb),
  ('ru', 'whatsNew.item.settingsSideTabs.title', $json$"Вкладки настроек слева"$json$::jsonb),
  ('ja', 'whatsNew.item.settingsSideTabs.title', $json$"設定のタブを左側に配置"$json$::jsonb),
  ('de', 'whatsNew.item.settingsSideTabs.title', $json$"Einstellungs-Tabs links"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.settingsSideTabs.detail', $json$"As abas da página de Configurações (App, Jev, MCP, Skills e cada agente) agora ficam numa coluna à esquerda, ao lado do conteúdo da página, e não mais numa linha no topo. A coluna acompanha a rolagem da página."$json$::jsonb),
  ('en', 'whatsNew.item.settingsSideTabs.detail', $json$"The tabs of the Settings page (App, Jev, MCP, Skills and each agent) now sit in a column on the left, next to the content of the page, instead of in a row on top. The column follows you as the page scrolls."$json$::jsonb),
  ('es', 'whatsNew.item.settingsSideTabs.detail', $json$"Las pestañas de la página de Ajustes (App, Jev, MCP, Skills y cada agente) ahora están en una columna a la izquierda, junto al contenido de la página, en lugar de en una fila arriba. La columna te acompaña al desplazar la página."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.settingsSideTabs.detail', $json$"设置页面的标签页（应用、Jev、MCP、技能以及各个智能体）现在以一列的形式排在页面内容左侧，不再横排在顶部。该列会随页面滚动一起移动。"$json$::jsonb),
  ('hi', 'whatsNew.item.settingsSideTabs.detail', $json$"सेटिंग्स पेज के टैब (ऐप, Jev, MCP, स्किल्स और हर एजेंट) अब ऊपर एक पंक्ति में नहीं, बल्कि पेज की सामग्री के बगल में बाईं ओर एक कॉलम में हैं। पेज स्क्रॉल करने पर यह कॉलम साथ चलता है।"$json$::jsonb),
  ('ar', 'whatsNew.item.settingsSideTabs.detail', $json$"أصبحت تبويبات صفحة الإعدادات (التطبيق وJev وMCP وSkills وكل وكيل) في عمود على اليسار بجانب محتوى الصفحة بدلًا من صفٍّ في الأعلى. ويتبعك العمود أثناء تمرير الصفحة."$json$::jsonb),
  ('fr', 'whatsNew.item.settingsSideTabs.detail', $json$"Les onglets de la page Réglages (App, Jev, MCP, Skills et chaque agent) sont maintenant dans une colonne à gauche, à côté du contenu de la page, et non plus sur une ligne en haut. La colonne vous suit quand la page défile."$json$::jsonb),
  ('ru', 'whatsNew.item.settingsSideTabs.detail', $json$"Вкладки страницы настроек (Приложение, Jev, MCP, Скиллы и каждый агент) теперь расположены столбцом слева, рядом с содержимым страницы, а не строкой сверху. Столбец движется вместе с прокруткой страницы."$json$::jsonb),
  ('ja', 'whatsNew.item.settingsSideTabs.detail', $json$"設定ページのタブ（アプリ、Jev、MCP、スキル、各エージェント）を、上の横並びではなく、ページ内容の左側に縦に並べるようにしました。ページをスクロールしても列は追従します。"$json$::jsonb),
  ('de', 'whatsNew.item.settingsSideTabs.detail', $json$"Die Tabs der Einstellungsseite (App, Jev, MCP, Skills und jeder Agent) stehen jetzt in einer Spalte links neben dem Seiteninhalt statt in einer Zeile oben. Die Spalte läuft beim Scrollen der Seite mit."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
