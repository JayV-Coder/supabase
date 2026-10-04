-- Orquestração do núcleo em crate próprio (v0.52.1), o último passo que
-- separa o núcleo em partes. Mudança interna do app, sem diferença para quem
-- usa: só o item da janela "Novidades".
insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.coreOrchestration.title', $json$"Núcleo inteiro em partes separadas"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.coreOrchestration.detail', $json$"Mudança interna, sem diferença no uso: a orquestração do Jev, que recebe o pedido, monta o contexto, escolhe o agente e revisa o resultado, virou a última parte própria do núcleo. Agora cada camada é compilada e testada separadamente."$json$::jsonb),
  ('en', 'whatsNew.item.coreOrchestration.title', $json$"The whole core in separate parts"$json$::jsonb),
  ('en', 'whatsNew.item.coreOrchestration.detail', $json$"An internal change with no difference in use: Jev's orchestration, which takes the request, builds the context, picks the agent and reviews the result, became the last part of its own in the core. Every layer is now built and tested separately."$json$::jsonb),
  ('es', 'whatsNew.item.coreOrchestration.title', $json$"Todo el núcleo en partes separadas"$json$::jsonb),
  ('es', 'whatsNew.item.coreOrchestration.detail', $json$"Un cambio interno, sin diferencia en el uso: la orquestación de Jev, que recibe el pedido, arma el contexto, elige el agente y revisa el resultado, pasó a ser la última parte propia del núcleo. Ahora cada capa se compila y se prueba por separado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreOrchestration.title', $json$"整个核心拆分为独立部分"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.coreOrchestration.detail', $json$"这是一项内部改动，使用上没有区别：Jev 的编排（接收请求、组织上下文、选择代理并审查结果）成为核心中最后一个独立部分。现在每一层都分别编译和测试。"$json$::jsonb),
  ('hi', 'whatsNew.item.coreOrchestration.title', $json$"पूरा कोर अलग हिस्सों में"$json$::jsonb),
  ('hi', 'whatsNew.item.coreOrchestration.detail', $json$"एक आंतरिक बदलाव, उपयोग में कोई अंतर नहीं: Jev का ऑर्केस्ट्रेशन, जो अनुरोध लेता है, संदर्भ बनाता है, एजेंट चुनता है और नतीजे की समीक्षा करता है, कोर का आख़िरी अलग हिस्सा बन गया। अब हर परत अलग से बनाई और जाँची जाती है।"$json$::jsonb),
  ('ar', 'whatsNew.item.coreOrchestration.title', $json$"النواة كلها في أجزاء منفصلة"$json$::jsonb),
  ('ar', 'whatsNew.item.coreOrchestration.detail', $json$"تغيير داخلي لا يغيّر شيئًا في الاستخدام: أصبح تنسيق Jev، الذي يستقبل الطلب ويجهّز السياق ويختار الوكيل ويراجع النتيجة، آخر جزء مستقل في النواة. الآن تُبنى كل طبقة وتُختبر على حدة."$json$::jsonb),
  ('fr', 'whatsNew.item.coreOrchestration.title', $json$"Tout le cœur en parties séparées"$json$::jsonb),
  ('fr', 'whatsNew.item.coreOrchestration.detail', $json$"Un changement interne, sans différence à l'usage : l'orchestration de Jev, qui reçoit la demande, prépare le contexte, choisit l'agent et relit le résultat, est devenue la dernière partie à part du cœur. Chaque couche est désormais compilée et testée séparément."$json$::jsonb),
  ('ru', 'whatsNew.item.coreOrchestration.title', $json$"Всё ядро разделено на отдельные части"$json$::jsonb),
  ('ru', 'whatsNew.item.coreOrchestration.detail', $json$"Внутреннее изменение, в работе ничего не меняется: оркестрация Jev, которая принимает запрос, собирает контекст, выбирает агента и проверяет результат, стала последней отдельной частью ядра. Теперь каждый слой собирается и проверяется по отдельности."$json$::jsonb),
  ('ja', 'whatsNew.item.coreOrchestration.title', $json$"コア全体を別々の部品に"$json$::jsonb),
  ('ja', 'whatsNew.item.coreOrchestration.detail', $json$"使い方に違いのない内部の変更です。リクエストを受け取り、コンテキストを組み立て、エージェントを選び、結果を確認する Jev のオーケストレーションが、コアの最後の独立した部品になりました。これで各層を別々にビルドとテストができます。"$json$::jsonb),
  ('de', 'whatsNew.item.coreOrchestration.title', $json$"Der ganze Kern in getrennten Teilen"$json$::jsonb),
  ('de', 'whatsNew.item.coreOrchestration.detail', $json$"Eine interne Änderung ohne Unterschied in der Nutzung: Die Orchestrierung von Jev, die die Anfrage annimmt, den Kontext aufbaut, den Agenten wählt und das Ergebnis prüft, ist jetzt der letzte eigene Teil des Kerns. Jede Schicht wird nun getrennt gebaut und getestet."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
