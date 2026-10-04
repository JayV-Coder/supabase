-- Jev, planos e organizações do núcleo em crates próprios (v0.51.5). Mudança
-- interna do app, sem diferença para quem usa: só o item da janela
-- "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, planos e organizações em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"Mudança interna, sem diferença no uso: a portaria do Jev, os recursos do plano e os repositórios das organizações viraram partes próprias do núcleo, compiladas e testadas separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, plans and organizations in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"An internal change with no difference in use: Jev's gate, the plan features and the organization repositories became parts of their own in the core, built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, planes y organizaciones en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"Un cambio interno, sin diferencia en el uso: el filtro de Jev, las funciones del plan y los repositorios de las organizaciones pasaron a ser partes propias del núcleo, compiladas y probadas por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev、套餐和组织拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"这是一项内部改动，使用上没有区别：Jev 的把关、套餐功能和组织的代码仓库成为核心中独立的部分，分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, प्लान और संगठन अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: Jev की जाँच, प्लान की सुविधाएँ और संगठनों के रिपॉज़िटरी अब कोर के अपने अलग हिस्से हैं, जो अलग से बनाए और जाँचे जाते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev والخطط والمؤسسات في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبحت بوابة Jev وميزات الخطة ومستودعات المؤسسات أجزاءً مستقلة في النواة، تُبنى وتُختبر كلٌّ على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, les forfaits et les organisations en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"Un changement interne, sans différence à l'usage : le contrôle de Jev, les fonctionnalités du forfait et les dépôts des organisations sont devenus des parties à part du cœur, compilées et testées séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, тарифы и организации выделены в отдельные части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"Внутреннее изменение, в работе ничего не меняется: проверка Jev, возможности тарифа и репозитории организаций стали отдельными частями ядра, которые собираются и проверяются по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev・プラン・組織を別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"使い方に違いのない内部の変更です。Jev のゲート、プランの機能、組織のリポジトリがコアの独立した部品になり、別々にビルドとテストができるようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.coreJevPlansOrgs.title', $json$"Jev, Tarife und Organisationen in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreJevPlansOrgs.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Prüfung von Jev, die Funktionen des Tarifs und die Repositorys der Organisationen sind jetzt eigene Teile des Kerns, die getrennt gebaut und getestet werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
