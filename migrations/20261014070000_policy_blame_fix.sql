-- v0.101.1: o aviso "a política de LLM da organização não deixa nenhum agente
-- ou modelo" só aparece quando a política desligou mesmo algum; sem agente
-- ligado nas Configurações, o app diz o que falta. A orientação dessa
-- mensagem também diz onde ligar (app) e onde a organização permite (site).
-- Só traduções.

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

insert into public.translations (locale, key, value) values
  ('pt-BR', 'guidance.policyFix', $json$"Abra as Configurações do app e ligue um agente e um modelo dele, escolhendo entre os que @{org} permite. Os owners e maintainers da organização definem isso no site do JayV, na aba Agentes e modelos da organização, e podem permitir os que você usa."$json$::jsonb),
  ('en', 'guidance.policyFix', $json$"Open Settings in the app, turn on an agent and one of its models, picking from what @{org} allows. The organization's owners and maintainers set that on the JayV site, in the organization's Agents and models tab, and can allow the ones you use."$json$::jsonb),
  ('es', 'guidance.policyFix', $json$"Abre Configuración en la app y activa un agente y uno de sus modelos, eligiendo entre los que @{org} permite. Los owners y maintainers de la organización lo definen en el sitio de JayV, en la pestaña Agentes y modelos de la organización, y pueden permitir los que usas."$json$::jsonb),
  ('zh-CN', 'guidance.policyFix', $json$"在应用的设置中开启一个代理及其模型，从 @{org} 允许的范围中选择。组织的 owner 和 maintainer 在 JayV 网站的组织“代理和模型”标签页中设置这些，也可以允许你使用的那些。"$json$::jsonb),
  ('hi', 'guidance.policyFix', $json$"ऐप की सेटिंग्स खोलें और एक एजेंट व उसका मॉडल चालू करें, उन्हीं में से जिन्हें @{org} अनुमति देता है। संगठन के owners और maintainers यह JayV साइट पर संगठन के “एजेंट और मॉडल” टैब में तय करते हैं और आपके उपयोग वाले को अनुमति दे सकते हैं।"$json$::jsonb),
  ('ar', 'guidance.policyFix', $json$"افتح إعدادات التطبيق وشغّل وكيلًا ونموذجًا من نماذجه، من بين ما تسمح به @{org}. يحدد مالكو المؤسسة ومشرفوها ذلك في موقع JayV، في تبويب «الوكلاء والنماذج» للمؤسسة، ويمكنهم السماح بما تستخدمه."$json$::jsonb),
  ('fr', 'guidance.policyFix', $json$"Ouvrez les Réglages de l'app et activez un agent et l'un de ses modèles, parmi ceux que @{org} autorise. Les owners et maintainers de l'organisation le définissent sur le site JayV, dans l'onglet Agents et modèles de l'organisation, et peuvent autoriser ceux que vous utilisez."$json$::jsonb),
  ('ru', 'guidance.policyFix', $json$"Откройте Настройки в приложении и включите агента и одну из его моделей из тех, что разрешает @{org}. Owner и maintainer организации задают это на сайте JayV, на вкладке «Агенты и модели» организации, и могут разрешить нужные вам."$json$::jsonb),
  ('ja', 'guidance.policyFix', $json$"アプリの設定を開き、@{org} が許可するものの中からエージェントとそのモデルをオンにしてください。組織の owner と maintainer が JayV サイトの組織の「エージェントとモデル」タブで設定でき、使っているものを許可することもできます。"$json$::jsonb),
  ('de', 'guidance.policyFix', $json$"Öffne die Einstellungen in der App und schalte einen Agenten und eines seiner Modelle ein, aus dem, was @{org} erlaubt. Die Owner und Maintainer der Organisation legen das auf der JayV-Website im Tab Agenten und Modelle der Organisation fest und können die von dir genutzten erlauben."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
