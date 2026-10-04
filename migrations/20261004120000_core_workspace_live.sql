-- Workspace e "Ao vivo" do núcleo em crates próprios (v0.51.7). Mudança
-- interna do app, sem diferença para quem usa: só o item da janela
-- "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreWorkspaceLive.title', $json$"Projetos, chats e Ao vivo em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreWorkspaceLive.detail', $json$"Mudança interna, sem diferença no uso: os projetos, os chats e a fila de pedidos, e também o painel Ao vivo, viraram partes próprias do núcleo, compiladas e testadas separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreWorkspaceLive.title', $json$"Projects, chats and Live in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreWorkspaceLive.detail', $json$"An internal change with no difference in use: projects, chats and the request queue, and also the Live panel, became parts of their own in the core, built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreWorkspaceLive.title', $json$"Proyectos, chats y En vivo en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreWorkspaceLive.detail', $json$"Un cambio interno, sin diferencia en el uso: los proyectos, los chats y la cola de pedidos, y también el panel En vivo, pasaron a ser partes propias del núcleo, compiladas y probadas por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreWorkspaceLive.title', $json$"项目、聊天和实时面板拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreWorkspaceLive.detail', $json$"这是一项内部改动，使用上没有区别：项目、聊天和请求队列，以及实时面板，成为核心中独立的部分，分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreWorkspaceLive.title', $json$"प्रोजेक्ट, चैट और लाइव अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreWorkspaceLive.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: प्रोजेक्ट, चैट और अनुरोधों की कतार, और लाइव पैनल भी, अब कोर के अपने अलग हिस्से हैं, जो अलग से बनाए और जाँचे जाते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreWorkspaceLive.title', $json$"المشاريع والمحادثات واللوحة المباشرة في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreWorkspaceLive.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبحت المشاريع والمحادثات وقائمة انتظار الطلبات، وكذلك اللوحة المباشرة، أجزاءً مستقلة في النواة، تُبنى وتُختبر كلٌّ على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreWorkspaceLive.title', $json$"Projets, discussions et En direct en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreWorkspaceLive.detail', $json$"Un changement interne, sans différence à l'usage : les projets, les discussions et la file des demandes, ainsi que le panneau En direct, sont devenus des parties à part du cœur, compilées et testées séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreWorkspaceLive.title', $json$"Проекты, чаты и «В реальном времени» выделены в отдельные части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreWorkspaceLive.detail', $json$"Внутреннее изменение, в работе ничего не меняется: проекты, чаты и очередь запросов, а также панель «В реальном времени» стали отдельными частями ядра, которые собираются и проверяются по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreWorkspaceLive.title', $json$"プロジェクト・チャット・ライブを別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreWorkspaceLive.detail', $json$"使い方に違いのない内部の変更です。プロジェクト、チャット、リクエストのキュー、そしてライブパネルがコアの独立した部品になり、別々にビルドとテストができるようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.coreWorkspaceLive.title', $json$"Projekte, Chats und Live in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreWorkspaceLive.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Projekte, die Chats und die Warteschlange der Anfragen sowie das Live-Panel sind jetzt eigene Teile des Kerns, die getrennt gebaut und getestet werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
