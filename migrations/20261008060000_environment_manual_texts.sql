-- App 0.88.1: Novidades do manual de ambientes, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.environmentManual.title', $json$"O manual de ambientes cita o carregamento"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.environmentManual.detail', $json$"A página Ambientes do manual agora diz que a troca mostra um carregamento e não procura atualização."$json$::jsonb),
  ('en', 'whatsNew.item.environmentManual.title', $json$"Manual of environments mentions the loading screen"$json$::jsonb),
  ('en', 'whatsNew.item.environmentManual.detail', $json$"The Environments page of the manual now says that switching shows a loading screen and does not look for updates."$json$::jsonb),
  ('es', 'whatsNew.item.environmentManual.title', $json$"El manual de entornos menciona la pantalla de carga"$json$::jsonb),
  ('es', 'whatsNew.item.environmentManual.detail', $json$"La página Entornos del manual ahora indica que al cambiar se muestra una pantalla de carga y no se buscan actualizaciones."$json$::jsonb),
  ('fr', 'whatsNew.item.environmentManual.title', $json$"Le manuel des environnements mentionne l'écran de chargement"$json$::jsonb),
  ('fr', 'whatsNew.item.environmentManual.detail', $json$"La page Environnements du manuel indique désormais que le changement affiche un écran de chargement et ne cherche pas de mise à jour."$json$::jsonb),
  ('de', 'whatsNew.item.environmentManual.title', $json$"Das Handbuch zu Umgebungen erwähnt den Ladebildschirm"$json$::jsonb),
  ('de', 'whatsNew.item.environmentManual.detail', $json$"Die Seite „Umgebungen“ des Handbuchs sagt jetzt, dass der Wechsel einen Ladebildschirm zeigt und nicht nach Updates sucht."$json$::jsonb),
  ('ru', 'whatsNew.item.environmentManual.title', $json$"В руководстве по средам упомянут экран загрузки"$json$::jsonb),
  ('ru', 'whatsNew.item.environmentManual.detail', $json$"Страница «Среды» в руководстве теперь сообщает, что при переключении показывается экран загрузки и обновления не ищутся."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.environmentManual.title', $json$"环境手册提到了加载界面"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.environmentManual.detail', $json$"手册的“环境”页面现在说明：切换时会显示加载界面，并且不会检查更新。"$json$::jsonb),
  ('ja', 'whatsNew.item.environmentManual.title', $json$"環境のマニュアルに読み込み画面を追記"$json$::jsonb),
  ('ja', 'whatsNew.item.environmentManual.detail', $json$"マニュアルの「環境」ページに、切り替え時は読み込み画面が表示され、更新の確認は行われないことを追記しました。"$json$::jsonb),
  ('hi', 'whatsNew.item.environmentManual.title', $json$"परिवेश के मैनुअल में लोडिंग स्क्रीन का ज़िक्र"$json$::jsonb),
  ('hi', 'whatsNew.item.environmentManual.detail', $json$"मैनुअल के परिवेश पृष्ठ में अब लिखा है कि बदलने पर लोडिंग स्क्रीन दिखती है और अपडेट नहीं खोजे जाते।"$json$::jsonb),
  ('ar', 'whatsNew.item.environmentManual.title', $json$"دليل البيئات يذكر شاشة التحميل"$json$::jsonb),
  ('ar', 'whatsNew.item.environmentManual.detail', $json$"صفحة البيئات في الدليل تذكر الآن أن التبديل يعرض شاشة تحميل ولا يبحث عن تحديثات."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
