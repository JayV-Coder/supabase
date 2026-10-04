-- Estatísticas e Planos nas próprias pastas (v0.52.3), o segundo passo das
-- telas por funcionalidade. Mudança interna do app, sem diferença para quem
-- usa: só o item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.featureStatsPlans.title', $json$"Estatísticas e Planos em pastas próprias"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.featureStatsPlans.detail', $json$"Mudança interna, sem diferença no uso: as páginas Estatísticas e Planos agora guardam as telas cada uma na própria pasta, como a página Sistema."$json$::jsonb),
  ('en', 'whatsNew.item.featureStatsPlans.title', $json$"Statistics and Plans in their own folders"$json$::jsonb),
  ('en', 'whatsNew.item.featureStatsPlans.detail', $json$"An internal change with no difference in use: the Statistics and Plans pages now each keep their screens in a folder of their own, like the System page."$json$::jsonb),
  ('es', 'whatsNew.item.featureStatsPlans.title', $json$"Estadísticas y Planes en carpetas propias"$json$::jsonb),
  ('es', 'whatsNew.item.featureStatsPlans.detail', $json$"Un cambio interno, sin diferencia en el uso: las páginas Estadísticas y Planes ahora guardan sus pantallas cada una en su propia carpeta, como la página Sistema."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featureStatsPlans.title', $json$"统计和套餐有了各自的文件夹"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featureStatsPlans.detail', $json$"这是一项内部改动，使用上没有区别：统计和套餐页面现在像系统页面一样，各自把界面放在自己的文件夹里。"$json$::jsonb),
  ('hi', 'whatsNew.item.featureStatsPlans.title', $json$"आँकड़े और प्लान अपने-अपने फ़ोल्डर में"$json$::jsonb),
  ('hi', 'whatsNew.item.featureStatsPlans.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: आँकड़े और प्लान पेज अब सिस्टम पेज की तरह अपनी स्क्रीन अपने-अपने फ़ोल्डर में रखते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.featureStatsPlans.title', $json$"الإحصاءات والخطط في مجلدات خاصة"$json$::jsonb),
  ('ar', 'whatsNew.item.featureStatsPlans.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: صارت صفحتا الإحصاءات والخطط تحفظ كلٌّ منهما شاشاتها في مجلدها الخاص، مثل صفحة النظام."$json$::jsonb),
  ('fr', 'whatsNew.item.featureStatsPlans.title', $json$"Statistiques et Forfaits dans leurs propres dossiers"$json$::jsonb),
  ('fr', 'whatsNew.item.featureStatsPlans.detail', $json$"Un changement interne, sans différence à l'usage : les pages Statistiques et Forfaits gardent maintenant chacune leurs écrans dans leur propre dossier, comme la page Système."$json$::jsonb),
  ('ru', 'whatsNew.item.featureStatsPlans.title', $json$"«Статистика» и «Тарифы» в собственных папках"$json$::jsonb),
  ('ru', 'whatsNew.item.featureStatsPlans.detail', $json$"Внутреннее изменение, в работе ничего не меняется: страницы «Статистика» и «Тарифы» теперь хранят свои экраны каждая в своей папке, как страница «Система»."$json$::jsonb),
  ('ja', 'whatsNew.item.featureStatsPlans.title', $json$"統計とプランをそれぞれ専用フォルダーに"$json$::jsonb),
  ('ja', 'whatsNew.item.featureStatsPlans.detail', $json$"使い方に違いのない内部の変更です。統計とプランのページも、システムページと同じように画面をそれぞれ専用のフォルダーにまとめました。"$json$::jsonb),
  ('de', 'whatsNew.item.featureStatsPlans.title', $json$"Statistiken und Pläne in eigenen Ordnern"$json$::jsonb),
  ('de', 'whatsNew.item.featureStatsPlans.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Seiten Statistiken und Pläne halten ihre Ansichten jetzt jeweils in einem eigenen Ordner, wie die Seite System."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
