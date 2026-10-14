-- v0.101.1: o aviso "a política de LLM da organização não deixa nenhum agente
-- ou modelo" só aparece quando a política desligou mesmo algum; sem agente
-- ligado nas Configurações, o app diz o que falta. Só traduções.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.policyBlameFix.title', $json$"A organização deixa de levar a culpa quando nenhum agente está ligado"$json$::jsonb),
  ('en', 'whatsNew.item.policyBlameFix.title', $json$"The organization is no longer blamed when no agent is on"$json$::jsonb),
  ('es', 'whatsNew.item.policyBlameFix.title', $json$"Ya no se culpa a la organización cuando no hay ningún agente activado"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.policyBlameFix.title', $json$"没有开启任何智能体时，不再归咎于组织"$json$::jsonb),
  ('hi', 'whatsNew.item.policyBlameFix.title', $json$"कोई एजेंट चालू न होने पर अब संगठन को दोष नहीं दिया जाता"$json$::jsonb),
  ('ar', 'whatsNew.item.policyBlameFix.title', $json$"لم يعد يُنسب الخطأ إلى المؤسسة عند عدم تشغيل أي وكيل"$json$::jsonb),
  ('fr', 'whatsNew.item.policyBlameFix.title', $json$"L'organisation n'est plus mise en cause quand aucun agent n'est activé"$json$::jsonb),
  ('ru', 'whatsNew.item.policyBlameFix.title', $json$"Организацию больше не винят, когда ни один агент не включён"$json$::jsonb),
  ('ja', 'whatsNew.item.policyBlameFix.title', $json$"エージェントがオンでないとき、組織のせいにしなくなりました"$json$::jsonb),
  ('de', 'whatsNew.item.policyBlameFix.title', $json$"Die Organisation wird nicht mehr verantwortlich gemacht, wenn kein Agent aktiv ist"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.policyBlameFix.detail', $json$"Um pedido em um projeto de organização só diz que a política de LLM dela não deixa nenhum agente ou modelo permitido quando a política realmente desligou algum. Nos outros casos, o aviso diz o que falta (nenhum agente ou modelo ligado em Configurações)."$json$::jsonb),
  ('en', 'whatsNew.item.policyBlameFix.detail', $json$"A request in an organization project only says the organization's LLM policy left no allowed agent or model when the policy really switched one off. Otherwise it now says what is missing (no agent or model turned on in Settings)."$json$::jsonb),
  ('es', 'whatsNew.item.policyBlameFix.detail', $json$"Una solicitud en un proyecto de organización solo dice que la política de LLM de la organización no deja ningún agente o modelo permitido cuando la política realmente desactivó alguno. En los demás casos, el aviso dice qué falta (ningún agente o modelo activado en Configuración)."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.policyBlameFix.detail', $json$"组织项目中的请求，只有在策略确实关闭了某个智能体或模型时，才会提示组织的 LLM 策略没有留下可用的智能体或模型。其他情况下，提示会说明缺少什么（设置中没有开启任何智能体或模型）。"$json$::jsonb),
  ('hi', 'whatsNew.item.policyBlameFix.detail', $json$"संगठन के प्रोजेक्ट में कोई अनुरोध तभी कहता है कि संगठन की LLM नीति ने कोई अनुमत एजेंट या मॉडल नहीं छोड़ा, जब नीति ने सच में कोई बंद किया हो। अन्य मामलों में संदेश बताता है कि क्या कम है (सेटिंग्स में कोई एजेंट या मॉडल चालू नहीं)।"$json$::jsonb),
  ('ar', 'whatsNew.item.policyBlameFix.detail', $json$"لا يقول الطلب في مشروع مؤسسة إن سياسة LLM الخاصة بها لم تترك أي وكيل أو نموذج مسموحًا إلا إذا عطّلت السياسة فعلًا أحدها. في الحالات الأخرى تذكر الرسالة ما ينقص (لا وكيل أو نموذج مفعّل في الإعدادات)."$json$::jsonb),
  ('fr', 'whatsNew.item.policyBlameFix.detail', $json$"Une demande dans un projet d'organisation n'indique que la politique LLM de l'organisation ne laisse aucun agent ou modèle autorisé que si la politique en a vraiment désactivé un. Sinon, le message dit ce qui manque (aucun agent ou modèle activé dans les Paramètres)."$json$::jsonb),
  ('ru', 'whatsNew.item.policyBlameFix.detail', $json$"Запрос в проекте организации говорит, что политика LLM организации не оставила разрешённого агента или модели, только если политика действительно что-то отключила. В остальных случаях сообщение называет, чего не хватает (в настройках не включён ни один агент или модель)."$json$::jsonb),
  ('ja', 'whatsNew.item.policyBlameFix.detail', $json$"組織プロジェクトでのリクエストは、ポリシーが実際にエージェントまたはモデルをオフにしたときだけ、組織の LLM ポリシーが許可されたエージェントやモデルを残していないと表示します。それ以外では、足りないもの（設定でエージェントやモデルがオンになっていない）を表示します。"$json$::jsonb),
  ('de', 'whatsNew.item.policyBlameFix.detail', $json$"Eine Anfrage in einem Organisationsprojekt meldet nur dann, dass die LLM-Richtlinie der Organisation keinen erlaubten Agenten oder kein erlaubtes Modell übrig lässt, wenn die Richtlinie tatsächlich eines abgeschaltet hat. Sonst nennt die Meldung, was fehlt (kein Agent oder Modell in den Einstellungen eingeschaltet)."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
