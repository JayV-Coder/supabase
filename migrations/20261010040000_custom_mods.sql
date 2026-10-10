-- App 0.93.0: as integrações com LLM viram mods, e a pessoa pode criar os
-- seus (Configuração › Mods): um programa de linha de comando ou uma API
-- compatível com OpenAI ou Anthropic. Criar mods é o recurso `customMods`
-- do catálogo dos planos: entra em todo plano que já existe, opcional e
-- ligado, como o Kilo Code e os gateways de API; o admin tira dos planos que
-- quiser, e o app desliga os mods criados de quem não o tem.
--
-- A política de LLM da organização não muda: os ids dos mods criados
-- (`mod-…`) são de cada pessoa e não entram na lista de agentes permitidos.
-- Sem lista (todos), eles rodam nos projetos da organização; com lista, ficam
-- desligados lá.

insert into public.features (key, position, core) values
  ('customMods', 129, false)
on conflict (key) do nothing;

insert into public.plan_features (plan_key, feature_key, mode, default_on)
select p.key, 'customMods', 'optional', true from public.plans p
on conflict (plan_key, feature_key) do nothing;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'feature.customMods.title', $json$"Criar mods"$json$::jsonb),
  ('en', 'feature.customMods.title', $json$"Create mods"$json$::jsonb),
  ('es', 'feature.customMods.title', $json$"Crear mods"$json$::jsonb),
  ('zh-CN', 'feature.customMods.title', $json$"创建模组"$json$::jsonb),
  ('hi', 'feature.customMods.title', $json$"मॉड बनाना"$json$::jsonb),
  ('ar', 'feature.customMods.title', $json$"إنشاء الإضافات"$json$::jsonb),
  ('fr', 'feature.customMods.title', $json$"Créer des mods"$json$::jsonb),
  ('ru', 'feature.customMods.title', $json$"Создание модов"$json$::jsonb),
  ('ja', 'feature.customMods.title', $json$"Mod の作成"$json$::jsonb),
  ('de', 'feature.customMods.title', $json$"Mods erstellen"$json$::jsonb),
  ('pt-BR', 'feature.customMods.detail', $json$"Criar as suas próprias integrações com LLM em Configuração › Mods: programas de linha de comando ou APIs compatíveis com OpenAI ou Anthropic."$json$::jsonb),
  ('en', 'feature.customMods.detail', $json$"Create your own LLM integrations in Settings › Mods: command-line programs or APIs compatible with OpenAI or Anthropic."$json$::jsonb),
  ('es', 'feature.customMods.detail', $json$"Crear tus propias integraciones con LLM en Configuración › Mods: programas de línea de comandos o API compatibles con OpenAI o Anthropic."$json$::jsonb),
  ('zh-CN', 'feature.customMods.detail', $json$"在“设置 › 模组”中创建自己的 LLM 集成：命令行程序或兼容 OpenAI 或 Anthropic 的 API。"$json$::jsonb),
  ('hi', 'feature.customMods.detail', $json$"सेटिंग्स › मॉड में अपने LLM इंटीग्रेशन बनाएँ: कमांड-लाइन प्रोग्राम या OpenAI या Anthropic के साथ संगत API।"$json$::jsonb),
  ('ar', 'feature.customMods.detail', $json$"إنشاء تكاملات LLM خاصة بك في الإعدادات › الإضافات: برامج سطر أوامر أو واجهات API متوافقة مع OpenAI أو Anthropic."$json$::jsonb),
  ('fr', 'feature.customMods.detail', $json$"Créer vos propres intégrations LLM dans Configuration › Mods : programmes en ligne de commande ou API compatibles avec OpenAI ou Anthropic."$json$::jsonb),
  ('ru', 'feature.customMods.detail', $json$"Собственные интеграции с LLM в Настройки › Моды: программы командной строки или API, совместимые с OpenAI или Anthropic."$json$::jsonb),
  ('ja', 'feature.customMods.detail', $json$"設定 › Mod で独自の LLM 連携を作成：コマンドラインプログラム、または OpenAI や Anthropic 互換の API。"$json$::jsonb),
  ('de', 'feature.customMods.detail', $json$"Eigene LLM-Anbindungen unter Einstellungen › Mods erstellen: Kommandozeilenprogramme oder APIs, die mit OpenAI oder Anthropic kompatibel sind."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
