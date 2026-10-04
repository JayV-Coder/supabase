-- Nuvem e agentes do núcleo em crates próprios (v0.51.3). Mudança interna do
-- app, sem diferença para quem usa: só o item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreCloudAgents.title', $json$"Nuvem e agentes em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreCloudAgents.detail', $json$"Mudança interna, sem diferença no uso: a conexão com o servidor e tudo o que fala com os agentes e modelos viraram partes próprias do núcleo, compiladas e testadas separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreCloudAgents.title', $json$"Cloud and agents in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreCloudAgents.detail', $json$"An internal change with no difference in use: the connection to the server and everything that talks to the agents and models became parts of their own in the core, built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreCloudAgents.title', $json$"Nube y agentes en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreCloudAgents.detail', $json$"Un cambio interno, sin diferencia en el uso: la conexión con el servidor y todo lo que habla con los agentes y modelos pasaron a ser partes propias del núcleo, compiladas y probadas por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCloudAgents.title', $json$"云端与智能体拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreCloudAgents.detail', $json$"这是一项内部改动，使用上没有区别：与服务器的连接以及所有与智能体和模型通信的部分成为核心中独立的部分，分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCloudAgents.title', $json$"क्लाउड और एजेंट अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreCloudAgents.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: सर्वर से कनेक्शन और एजेंटों व मॉडलों से बात करने वाला सब कुछ अब कोर के अपने अलग हिस्से हैं, जो अलग से बनाए और जाँचे जाते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCloudAgents.title', $json$"السحابة والوكلاء في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreCloudAgents.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبح الاتصال بالخادم وكل ما يتحدث مع الوكلاء والنماذج أجزاءً مستقلة في النواة، تُبنى وتُختبر كلٌّ على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreCloudAgents.title', $json$"Le cloud et les agents en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreCloudAgents.detail', $json$"Un changement interne, sans différence à l'usage : la connexion au serveur et tout ce qui parle aux agents et aux modèles sont devenus des parties à part du cœur, compilées et testées séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreCloudAgents.title', $json$"Облако и агенты выделены в отдельные части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreCloudAgents.detail', $json$"Внутреннее изменение, в работе ничего не меняется: связь с сервером и всё, что общается с агентами и моделями, стали отдельными частями ядра, которые собираются и проверяются по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreCloudAgents.title', $json$"クラウドとエージェントを別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreCloudAgents.detail', $json$"使い方に違いのない内部の変更です。サーバーとの接続と、エージェントやモデルとやり取りする部分がコアの独立した部品になり、別々にビルドとテストができるようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.coreCloudAgents.title', $json$"Cloud und Agenten in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreCloudAgents.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Verbindung zum Server und alles, was mit den Agenten und Modellen spricht, sind jetzt eigene Teile des Kerns, die getrennt gebaut und getestet werden."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
