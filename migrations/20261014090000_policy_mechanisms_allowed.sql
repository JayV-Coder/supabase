-- Site v2.18.1: a lista de mecanismos da organização passa a mostrar os
-- liberados (marcado = ligado) em vez dos bloqueados; o que se grava continua
-- sendo `blocked_mechanisms`. Só os dois textos da tela mudam.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'policy.mechanisms', $json$"Mecanismos liberados"$json$::jsonb),
  ('en', 'policy.mechanisms', $json$"Allowed mechanisms"$json$::jsonb),
  ('es', 'policy.mechanisms', $json$"Mecanismos permitidos"$json$::jsonb),
  ('zh-CN', 'policy.mechanisms', $json$"允许的机制"$json$::jsonb),
  ('hi', 'policy.mechanisms', $json$"अनुमत तंत्र"$json$::jsonb),
  ('ar', 'policy.mechanisms', $json$"الآليات المسموح بها"$json$::jsonb),
  ('fr', 'policy.mechanisms', $json$"Mécanismes autorisés"$json$::jsonb),
  ('ru', 'policy.mechanisms', $json$"Разрешённые механизмы"$json$::jsonb),
  ('ja', 'policy.mechanisms', $json$"許可するメカニズム"$json$::jsonb),
  ('de', 'policy.mechanisms', $json$"Erlaubte Mechanismen"$json$::jsonb),
  ('pt-BR', 'policy.mechanisms.hint', $json$"Os desmarcados ficam desligados nos projetos desta organização, mesmo para quem os ligou em Configurações › Agentes."$json$::jsonb),
  ('en', 'policy.mechanisms.hint', $json$"Unchecked ones stay off in this organization's projects, even for members who turned them on in Settings › Agents."$json$::jsonb),
  ('es', 'policy.mechanisms.hint', $json$"Los desmarcados quedan desactivados en los proyectos de esta organización, incluso para quienes los activaron en Configuración › Agentes."$json$::jsonb),
  ('zh-CN', 'policy.mechanisms.hint', $json$"未勾选的机制在该组织的项目中保持关闭，即使成员已在“设置 › 智能体”中开启。"$json$::jsonb),
  ('hi', 'policy.mechanisms.hint', $json$"जिन पर निशान नहीं है वे इस संगठन के प्रोजेक्ट में बंद रहते हैं, भले ही सदस्यों ने उन्हें सेटिंग्स › एजेंट में चालू किया हो।"$json$::jsonb),
  ('ar', 'policy.mechanisms.hint', $json$"غير المحددة تبقى معطّلة في مشاريع هذه المؤسسة حتى لو فعّلها الأعضاء في الإعدادات › الوكلاء."$json$::jsonb),
  ('fr', 'policy.mechanisms.hint', $json$"Les mécanismes décochés restent désactivés dans les projets de cette organisation, même pour les membres qui les ont activés dans Réglages › Agents."$json$::jsonb),
  ('ru', 'policy.mechanisms.hint', $json$"Неотмеченные остаются выключенными в проектах этой организации, даже у участников, включивших их в Настройки › Агенты."$json$::jsonb),
  ('ja', 'policy.mechanisms.hint', $json$"チェックされていないものは、設定 › エージェントでオンにしたメンバーも含め、この組織のプロジェクトではオフのままです。"$json$::jsonb),
  ('de', 'policy.mechanisms.hint', $json$"Nicht angehakte bleiben in den Projekten dieser Organisation ausgeschaltet, auch für Mitglieder, die sie unter Einstellungen › Agenten eingeschaltet haben."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
