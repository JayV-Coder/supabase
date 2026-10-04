-- Núcleo em camadas (v0.51.1). Mudança interna do app, sem diferença para
-- quem usa: só o item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreLayers.title', $json$"Núcleo organizado em camadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreLayers.detail', $json$"Mudança interna, sem diferença no uso: as partes do núcleo do app deixaram de depender umas das outras em roda. É o primeiro passo para cada funcionalidade ser criada e corrigida separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreLayers.title', $json$"Core organized in layers"$json$::jsonb),
  ('en', 'whatsNew.item.coreLayers.detail', $json$"An internal change with no difference in use: the parts of the app's core no longer depend on each other in circles. It is the first step toward building and fixing each feature separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreLayers.title', $json$"Núcleo organizado en capas"$json$::jsonb),
  ('es', 'whatsNew.item.coreLayers.detail', $json$"Un cambio interno, sin diferencia en el uso: las partes del núcleo de la app ya no dependen unas de otras en círculo. Es el primer paso para crear y corregir cada función por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreLayers.title', $json$"核心按层组织"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreLayers.detail', $json$"这是一项内部改动，使用上没有区别：应用核心的各部分不再相互循环依赖。这是让每个功能都能单独开发和修复的第一步。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreLayers.title', $json$"कोर अब परतों में व्यवस्थित"$json$::jsonb),
  ('hi', 'whatsNew.item.coreLayers.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: ऐप के कोर के हिस्से अब एक-दूसरे पर घूमकर निर्भर नहीं रहते। यह हर सुविधा को अलग से बनाने और ठीक करने की ओर पहला कदम है।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreLayers.title', $json$"النواة منظمة في طبقات"$json$::jsonb),
  ('ar', 'whatsNew.item.coreLayers.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: لم تعد أجزاء نواة التطبيق تعتمد على بعضها في حلقة. إنها الخطوة الأولى نحو بناء كل ميزة وإصلاحها على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreLayers.title', $json$"Le cœur organisé en couches"$json$::jsonb),
  ('fr', 'whatsNew.item.coreLayers.detail', $json$"Un changement interne, sans différence à l'usage : les parties du cœur de l'app ne dépendent plus les unes des autres en boucle. C'est le premier pas pour créer et corriger chaque fonctionnalité séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreLayers.title', $json$"Ядро разделено на слои"$json$::jsonb),
  ('ru', 'whatsNew.item.coreLayers.detail', $json$"Внутреннее изменение, в работе ничего не меняется: части ядра приложения больше не зависят друг от друга по кругу. Это первый шаг к тому, чтобы создавать и исправлять каждую функцию отдельно."$json$::jsonb),
  ('ja', 'whatsNew.item.coreLayers.title', $json$"コアをレイヤーに整理"$json$::jsonb),
  ('ja', 'whatsNew.item.coreLayers.detail', $json$"使い方に違いのない内部の変更です。アプリのコアの各部分が互いに循環して依存しなくなりました。機能ごとに個別に作成・修正できるようにするための第一歩です。"$json$::jsonb),
  ('de', 'whatsNew.item.coreLayers.title', $json$"Kern in Schichten geordnet"$json$::jsonb),
  ('de', 'whatsNew.item.coreLayers.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Teile des App-Kerns hängen nicht mehr im Kreis voneinander ab. Das ist der erste Schritt, um jede Funktion getrennt zu bauen und zu korrigieren."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
