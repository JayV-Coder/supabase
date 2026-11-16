-- App 0.113.1: o cliente passa a ler e gravar as tabelas do app no schema `coder`. Textos das
-- Novidades (`whatsNew.item.coderSchema.*`), nos dez idiomas.

insert into public.translations (locale, key, value) values
  ('en', 'whatsNew.item.coderSchema.title', $json$"Sync uses the app's own data area"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coderSchema.title', $json$"A sincronização usa a área de dados própria do app"$json$::jsonb),
  ('es', 'whatsNew.item.coderSchema.title', $json$"La sincronización usa el área de datos propia de la app"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coderSchema.title', $json$"同步改用应用专属的数据区"$json$::jsonb),
  ('hi', 'whatsNew.item.coderSchema.title', $json$"सिंक अब ऐप के अपने डेटा क्षेत्र का उपयोग करता है"$json$::jsonb),
  ('ar', 'whatsNew.item.coderSchema.title', $json$"تستخدم المزامنة منطقة بيانات التطبيق الخاصة"$json$::jsonb),
  ('fr', 'whatsNew.item.coderSchema.title', $json$"La synchronisation utilise l'espace de données propre à l'app"$json$::jsonb),
  ('ru', 'whatsNew.item.coderSchema.title', $json$"Синхронизация использует собственную область данных приложения"$json$::jsonb),
  ('ja', 'whatsNew.item.coderSchema.title', $json$"同期がアプリ専用のデータ領域を使うようになりました"$json$::jsonb),
  ('de', 'whatsNew.item.coderSchema.title', $json$"Die Synchronisierung nutzt den eigenen Datenbereich der App"$json$::jsonb),
  ('en', 'whatsNew.item.coderSchema.detail', $json$"Chats, projects and usage now sync through the data area reserved for the app, so the account data shared with other apps stays separate. Nothing changes in what you see."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coderSchema.detail', $json$"Chats, projetos e uso agora sincronizam pela área de dados reservada ao app, e os dados da conta compartilhados com outros apps ficam separados. Nada muda no que você vê."$json$::jsonb),
  ('es', 'whatsNew.item.coderSchema.detail', $json$"Los chats, proyectos y el uso ahora se sincronizan por el área de datos reservada a la app, y los datos de la cuenta compartidos con otras apps quedan separados. No cambia nada de lo que ves."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coderSchema.detail', $json$"聊天、项目和用量现在通过应用专属的数据区同步，与其他应用共享的账户数据保持分离。你看到的内容不会有任何变化。"$json$::jsonb),
  ('hi', 'whatsNew.item.coderSchema.detail', $json$"चैट, प्रोजेक्ट और उपयोग अब ऐप के लिए आरक्षित डेटा क्षेत्र से सिंक होते हैं, इसलिए अन्य ऐप्स के साथ साझा खाता डेटा अलग रहता है। आपको जो दिखता है उसमें कुछ नहीं बदलता।"$json$::jsonb),
  ('ar', 'whatsNew.item.coderSchema.detail', $json$"أصبحت الدردشات والمشاريع والاستخدام تُزامَن عبر منطقة البيانات المخصصة للتطبيق، فتبقى بيانات الحساب المشتركة مع تطبيقات أخرى منفصلة. لا يتغير شيء مما تراه."$json$::jsonb),
  ('fr', 'whatsNew.item.coderSchema.detail', $json$"Les chats, projets et l'usage se synchronisent désormais par l'espace de données réservé à l'app, et les données de compte partagées avec d'autres apps restent séparées. Rien ne change dans ce que vous voyez."$json$::jsonb),
  ('ru', 'whatsNew.item.coderSchema.detail', $json$"Чаты, проекты и использование теперь синхронизируются через область данных, выделенную приложению, а данные учётной записи, общие с другими приложениями, остаются отдельно. Для вас ничего не меняется."$json$::jsonb),
  ('ja', 'whatsNew.item.coderSchema.detail', $json$"チャット、プロジェクト、使用量は、アプリ専用のデータ領域を通じて同期されるようになり、他のアプリと共有するアカウントデータは分離されたままです。見た目に変化はありません。"$json$::jsonb),
  ('de', 'whatsNew.item.coderSchema.detail', $json$"Chats, Projekte und Nutzung werden jetzt über den für die App reservierten Datenbereich synchronisiert, sodass die mit anderen Apps geteilten Kontodaten getrennt bleiben. An dem, was Sie sehen, ändert sich nichts."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
