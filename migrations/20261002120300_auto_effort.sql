-- Esforço de raciocínio automático: o Jev escolhe por pedido, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'effort.auto', $json$"Automático (Jev)"$json$::jsonb),
  ('pt-BR', 'agent.effort.hint.auto', $json$"No automático, o Jev escolhe a cada pedido: baixo para pedidos pequenos, alto só para os grandes. Mais esforço pensa melhor, mas demora e custa mais."$json$::jsonb),
  ('en', 'effort.auto', $json$"Automatic (Jev)"$json$::jsonb),
  ('en', 'agent.effort.hint.auto', $json$"Automatic lets Jev pick per request: low for small requests, high only for large ones. More effort thinks better but takes longer and costs more."$json$::jsonb),
  ('es', 'effort.auto', $json$"Automático (Jev)"$json$::jsonb),
  ('es', 'agent.effort.hint.auto', $json$"En automático, Jev elige en cada solicitud: bajo para las pequeñas y alto solo para las grandes. Más esfuerzo piensa mejor, pero tarda más y cuesta más."$json$::jsonb),
  ('zh-CN', 'effort.auto', $json$"自动（Jev）"$json$::jsonb),
  ('zh-CN', 'agent.effort.hint.auto', $json$"自动模式下由 Jev 按请求选择：小请求用低，只有大请求才用高。投入越多思考越好，但更慢、更贵。"$json$::jsonb),
  ('hi', 'effort.auto', $json$"स्वचालित (Jev)"$json$::jsonb),
  ('hi', 'agent.effort.hint.auto', $json$"स्वचालित में Jev हर अनुरोध के लिए चुनता है: छोटे अनुरोधों के लिए कम, सिर्फ़ बड़े अनुरोधों के लिए ज़्यादा। ज़्यादा प्रयास बेहतर सोचता है, पर समय और खर्च ज़्यादा होता है।"$json$::jsonb),
  ('ar', 'effort.auto', $json$"تلقائي (Jev)"$json$::jsonb),
  ('ar', 'agent.effort.hint.auto', $json$"في الوضع التلقائي يختار Jev لكل طلب: منخفض للطلبات الصغيرة، ومرتفع للكبيرة فقط. الجهد الأكبر يفكر أفضل لكنه أبطأ وأكثر تكلفة."$json$::jsonb),
  ('fr', 'effort.auto', $json$"Automatique (Jev)"$json$::jsonb),
  ('fr', 'agent.effort.hint.auto', $json$"En automatique, Jev choisit à chaque demande : faible pour les petites, élevé seulement pour les grandes. Plus d'effort réfléchit mieux mais prend plus de temps et coûte plus."$json$::jsonb),
  ('ru', 'effort.auto', $json$"Автоматически (Jev)"$json$::jsonb),
  ('ru', 'agent.effort.hint.auto', $json$"В автоматическом режиме Jev выбирает для каждого запроса: низкое для небольших, высокое только для крупных. Больше усилий — лучше рассуждение, но дольше и дороже."$json$::jsonb),
  ('ja', 'effort.auto', $json$"自動（Jev）"$json$::jsonb),
  ('ja', 'agent.effort.hint.auto', $json$"自動では Jev がリクエストごとに選びます。小さな依頼は低、大きな依頼だけ高。労力を上げるほどよく考えますが、時間と費用が増えます。"$json$::jsonb),
  ('de', 'effort.auto', $json$"Automatisch (Jev)"$json$::jsonb),
  ('de', 'agent.effort.hint.auto', $json$"Bei Automatisch wählt Jev pro Anfrage: niedrig für kleine Anfragen, hoch nur für große. Mehr Aufwand denkt gründlicher, dauert aber länger und kostet mehr."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
