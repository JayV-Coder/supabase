-- Base e armazenamento local do núcleo em crates próprios (v0.51.2). Mudança
-- interna do app, sem diferença para quem usa: só o item da janela
-- "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreCrates.title', $json$"Base do núcleo em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreCrates.detail', $json$"Mudança interna, sem diferença no uso: textos, configuração, segurança de rede e o banco local do app viraram partes próprias do núcleo, compiladas e testadas separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreCrates.title', $json$"Core foundation in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreCrates.detail', $json$"An internal change with no difference in use: texts, configuration, network security and the app's local database became parts of their own in the core, built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreCrates.title', $json$"La base del núcleo en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreCrates.detail', $json$"Un cambio interno, sin diferencia en el uso: los textos, la configuración, la seguridad de red y la base de datos local de la app pasaron a ser partes propias del núcleo, compiladas y probadas por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCrates.title', $json$"核心基础拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCrates.detail', $json$"这是一项内部改动，使用上没有区别：文本、配置、网络安全和应用的本地数据库成为核心中独立的部分，分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCrates.title', $json$"कोर की नींव अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCrates.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: टेक्स्ट, कॉन्फ़िगरेशन, नेटवर्क सुरक्षा और ऐप का स्थानीय डेटाबेस अब कोर के अपने अलग हिस्से हैं, जो अलग से बनाए और जाँचे जाते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCrates.title', $json$"أساس النواة في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCrates.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبحت النصوص والإعدادات وأمان الشبكة وقاعدة البيانات المحلية للتطبيق أجزاءً مستقلة في النواة، تُبنى وتُختبر كلٌّ على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreCrates.title', $json$"La base du cœur en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreCrates.detail', $json$"Un changement interne, sans différence à l'usage : les textes, la configuration, la sécurité réseau et la base de données locale de l'app sont devenus des parties à part du cœur, compilées et testées séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreCrates.title', $json$"Основа ядра разделена на части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreCrates.detail', $json$"Внутреннее изменение, в работе ничего не меняется: тексты, настройки, сетевая безопасность и локальная база данных приложения стали отдельными частями ядра, которые собираются и проверяются по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreCrates.title', $json$"コアの土台を別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreCrates.detail', $json$"使い方に違いのない内部の変更です。テキスト、設定、ネットワークの安全性、アプリのローカルデータベースがコアの独立した部品になり、別々にビルドとテストができるようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.coreCrates.title', $json$"Fundament des Kerns in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreCrates.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Texte, Konfiguration, Netzwerksicherheit und die lokale Datenbank der App sind jetzt eigene Teile des Kerns, die getrennt gebaut und getestet werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
