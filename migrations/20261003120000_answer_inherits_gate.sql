-- v0.43.1: a resposta a uma pergunta do agente não é barrada como pedido novo.
--
-- Só textos: o item da janela "Novidades" desta versão.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.answerNotBlocked.title', $json$"Responder ao agente não é mais barrado na portaria"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.answerNotBlocked.detail', $json$"Quando o agente fazia uma segunda pergunta (comum no modo Planejamento), a resposta era julgada sem o pedido que começou a conversa e podia ser barrada como uma funcionalidade nova. Agora a portaria lê a conversa desde o pedido de origem, e a resposta herda a liberação dele."$json$::jsonb),
  ('en', 'whatsNew.item.answerNotBlocked.title', $json$"Answering the agent is no longer blocked at the gatehouse"$json$::jsonb),
  ('en', 'whatsNew.item.answerNotBlocked.detail', $json$"When the agent asked a second question (common in Planning mode), the answer was judged without the request that started the conversation and could be blocked as a new feature. The gatehouse now reads the conversation from the original request, and the answer inherits its pass."$json$::jsonb),
  ('es', 'whatsNew.item.answerNotBlocked.title', $json$"Responder al agente ya no se bloquea en la portería"$json$::jsonb),
  ('es', 'whatsNew.item.answerNotBlocked.detail', $json$"Cuando el agente hacía una segunda pregunta (habitual en el modo Planificación), la respuesta se juzgaba sin la solicitud que inició la conversación y podía bloquearse como una funcionalidad nueva. Ahora la portería lee la conversación desde la solicitud original, y la respuesta hereda su aprobación."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.answerNotBlocked.title', $json$"回答智能体不再被门岗拦截"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.answerNotBlocked.detail', $json$"当智能体提出第二个问题时（在规划模式中很常见），回答会脱离开启对话的原始请求被单独评判，可能被当作新功能拦下。现在门岗会从原始请求开始阅读整段对话，回答沿用原始请求的放行结果。"$json$::jsonb),
  ('hi', 'whatsNew.item.answerNotBlocked.title', $json$"एजेंट को जवाब देना अब गेट पर नहीं रुकता"$json$::jsonb),
  ('hi', 'whatsNew.item.answerNotBlocked.detail', $json$"जब एजेंट दूसरा सवाल पूछता था (प्लानिंग मोड में आम), तो जवाब को बातचीत शुरू करने वाले अनुरोध के बिना आँका जाता था और उसे नई सुविधा मानकर रोका जा सकता था। अब गेट मूल अनुरोध से बातचीत पढ़ता है, और जवाब को उसी की मंज़ूरी मिलती है।"$json$::jsonb),
  ('ar', 'whatsNew.item.answerNotBlocked.title', $json$"لم يعد الرد على الوكيل يُحجب عند البوابة"$json$::jsonb),
  ('ar', 'whatsNew.item.answerNotBlocked.detail', $json$"عندما كان الوكيل يطرح سؤالًا ثانيًا (وهو أمر شائع في وضع التخطيط)، كان الرد يُقيَّم بمعزل عن الطلب الذي بدأ المحادثة وقد يُحجب كأنه ميزة جديدة. أصبحت البوابة الآن تقرأ المحادثة من الطلب الأصلي، ويرث الرد الإذن الذي ناله ذلك الطلب."$json$::jsonb),
  ('fr', 'whatsNew.item.answerNotBlocked.title', $json$"Répondre à l'agent n'est plus bloqué à la loge"$json$::jsonb),
  ('fr', 'whatsNew.item.answerNotBlocked.detail', $json$"Quand l'agent posait une deuxième question (fréquent en mode Planification), la réponse était jugée sans la demande qui avait lancé la conversation et pouvait être bloquée comme une nouvelle fonctionnalité. La loge lit désormais la conversation depuis la demande d'origine, et la réponse hérite de son feu vert."$json$::jsonb),
  ('ru', 'whatsNew.item.answerNotBlocked.title', $json$"Ответ агенту больше не блокируется на проходной"$json$::jsonb),
  ('ru', 'whatsNew.item.answerNotBlocked.detail', $json$"Когда агент задавал второй вопрос (обычное дело в режиме планирования), ответ оценивался без запроса, с которого начался разговор, и мог быть заблокирован как новая функция. Теперь проходная читает разговор с исходного запроса, и ответ наследует его допуск."$json$::jsonb),
  ('ja', 'whatsNew.item.answerNotBlocked.title', $json$"エージェントへの回答がゲートで止められなくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.answerNotBlocked.detail', $json$"エージェントが2つ目の質問をしたとき（計画モードではよくあります）、回答は会話を始めた依頼と切り離して判定され、新機能の依頼としてブロックされることがありました。現在はゲートが元の依頼から会話を読み、回答はその依頼の通過結果を引き継ぎます。"$json$::jsonb),
  ('de', 'whatsNew.item.answerNotBlocked.title', $json$"Antworten an den Agenten werden an der Pforte nicht mehr blockiert"$json$::jsonb),
  ('de', 'whatsNew.item.answerNotBlocked.detail', $json$"Stellte der Agent eine zweite Frage (häufig im Planungsmodus), wurde die Antwort ohne die Anfrage bewertet, mit der das Gespräch begann, und konnte als neue Funktion blockiert werden. Die Pforte liest das Gespräch jetzt ab der ursprünglichen Anfrage, und die Antwort übernimmt deren Freigabe."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
