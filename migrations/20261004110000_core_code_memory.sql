-- Código e memória do núcleo em crates próprios (v0.51.6). Mudança interna do
-- app, sem diferença para quem usa: só o item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreCodeMemory.title', $json$"Índice do código e memória em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreCodeMemory.detail', $json$"Mudança interna, sem diferença no uso: o índice e a busca no código, os símbolos, o mapa do projeto e a memória dos chats e notas viraram partes próprias do núcleo, compiladas e testadas separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreCodeMemory.title', $json$"Code index and memory in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreCodeMemory.detail', $json$"An internal change with no difference in use: the code index and search, the symbols, the project map and the memory of chats and notes became parts of their own in the core, built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreCodeMemory.title', $json$"Índice del código y memoria en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreCodeMemory.detail', $json$"Un cambio interno, sin diferencia en el uso: el índice y la búsqueda en el código, los símbolos, el mapa del proyecto y la memoria de los chats y notas pasaron a ser partes propias del núcleo, compiladas y probadas por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCodeMemory.title', $json$"代码索引和记忆拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCodeMemory.detail', $json$"这是一项内部改动，使用上没有区别：代码索引与搜索、符号、项目地图以及聊天和笔记的记忆成为核心中独立的部分，分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCodeMemory.title', $json$"कोड इंडेक्स और मेमोरी अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCodeMemory.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: कोड का इंडेक्स और खोज, सिंबल, प्रोजेक्ट का नक्शा और चैट व नोट्स की मेमोरी अब कोर के अपने अलग हिस्से हैं, जो अलग से बनाए और जाँचे जाते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCodeMemory.title', $json$"فهرس الشيفرة والذاكرة في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCodeMemory.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبح فهرس الشيفرة والبحث فيها والرموز وخريطة المشروع وذاكرة المحادثات والملاحظات أجزاءً مستقلة في النواة، تُبنى وتُختبر كلٌّ على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreCodeMemory.title', $json$"L'index du code et la mémoire en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreCodeMemory.detail', $json$"Un changement interne, sans différence à l'usage : l'index et la recherche dans le code, les symboles, la carte du projet et la mémoire des discussions et des notes sont devenus des parties à part du cœur, compilées et testées séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreCodeMemory.title', $json$"Индекс кода и память выделены в отдельные части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreCodeMemory.detail', $json$"Внутреннее изменение, в работе ничего не меняется: индекс и поиск по коду, символы, карта проекта и память чатов и заметок стали отдельными частями ядра, которые собираются и проверяются по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreCodeMemory.title', $json$"コードの索引とメモリーを別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreCodeMemory.detail', $json$"使い方に違いのない内部の変更です。コードの索引と検索、シンボル、プロジェクトマップ、チャットとメモのメモリーがコアの独立した部品になり、別々にビルドとテストができるようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.coreCodeMemory.title', $json$"Code-Index und Gedächtnis in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreCodeMemory.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Der Index und die Suche im Code, die Symbole, die Projektkarte und das Gedächtnis der Chats und Notizen sind jetzt eigene Teile des Kerns, die getrennt gebaut und getestet werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
