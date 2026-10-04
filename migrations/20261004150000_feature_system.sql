-- Página Sistema na própria pasta (v0.52.2), o primeiro passo das telas por
-- funcionalidade. Mudança interna do app, sem diferença para quem usa: só o
-- item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.featureSystem.title', $json$"A página Sistema na própria pasta"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.featureSystem.detail', $json$"Mudança interna, sem diferença no uso: a página Sistema agora guarda a lógica, as telas e os testes numa pasta só, o primeiro passo para organizar as telas por funcionalidade."$json$::jsonb),
  ('en', 'whatsNew.item.featureSystem.title', $json$"The System page in its own folder"$json$::jsonb),
  ('en', 'whatsNew.item.featureSystem.detail', $json$"An internal change with no difference in use: the System page now keeps its logic, screens and tests in one folder, the first step in organizing the screens by feature."$json$::jsonb),
  ('es', 'whatsNew.item.featureSystem.title', $json$"La página Sistema en su propia carpeta"$json$::jsonb),
  ('es', 'whatsNew.item.featureSystem.detail', $json$"Un cambio interno, sin diferencia en el uso: la página Sistema ahora guarda la lógica, las pantallas y las pruebas en una sola carpeta, el primer paso para organizar las pantallas por funcionalidad."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featureSystem.title', $json$"系统页面有了自己的文件夹"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featureSystem.detail', $json$"这是一项内部改动，使用上没有区别：系统页面现在把逻辑、界面和测试放在同一个文件夹里，这是按功能整理界面的第一步。"$json$::jsonb),
  ('hi', 'whatsNew.item.featureSystem.title', $json$"सिस्टम पेज अपने फ़ोल्डर में"$json$::jsonb),
  ('hi', 'whatsNew.item.featureSystem.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: सिस्टम पेज अब अपना तर्क, स्क्रीन और परीक्षण एक ही फ़ोल्डर में रखता है, स्क्रीनों को सुविधा के अनुसार व्यवस्थित करने का पहला कदम।"$json$::jsonb),
  ('ar', 'whatsNew.item.featureSystem.title', $json$"صفحة النظام في مجلدها الخاص"$json$::jsonb),
  ('ar', 'whatsNew.item.featureSystem.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: صارت صفحة النظام تحفظ منطقها وشاشاتها واختباراتها في مجلد واحد، وهي الخطوة الأولى لتنظيم الشاشات حسب الميزة."$json$::jsonb),
  ('fr', 'whatsNew.item.featureSystem.title', $json$"La page Système dans son propre dossier"$json$::jsonb),
  ('fr', 'whatsNew.item.featureSystem.detail', $json$"Un changement interne, sans différence à l'usage : la page Système garde maintenant sa logique, ses écrans et ses tests dans un seul dossier, la première étape pour organiser les écrans par fonctionnalité."$json$::jsonb),
  ('ru', 'whatsNew.item.featureSystem.title', $json$"Страница «Система» в собственной папке"$json$::jsonb),
  ('ru', 'whatsNew.item.featureSystem.detail', $json$"Внутреннее изменение, в работе ничего не меняется: страница «Система» теперь хранит логику, экраны и тесты в одной папке. Это первый шаг к тому, чтобы разложить экраны по функциям."$json$::jsonb),
  ('ja', 'whatsNew.item.featureSystem.title', $json$"システムページを専用フォルダーに"$json$::jsonb),
  ('ja', 'whatsNew.item.featureSystem.detail', $json$"使い方に違いのない内部の変更です。システムページのロジック、画面、テストを一つのフォルダーにまとめました。画面を機能ごとに整理する最初の一歩です。"$json$::jsonb),
  ('de', 'whatsNew.item.featureSystem.title', $json$"Die Seite System im eigenen Ordner"$json$::jsonb),
  ('de', 'whatsNew.item.featureSystem.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Seite System hält ihre Logik, Ansichten und Tests jetzt in einem Ordner, der erste Schritt, die Ansichten nach Funktionen zu ordnen."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
