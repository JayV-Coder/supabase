-- v0.76.2: .env.example e outros moldes ficam legíveis com .env.* protegido.

insert into public.translations (locale, key, value) values
  ('en', 'whatsNew.item.envTemplates.title', $json$"Example env files stay readable to agents"$json$::jsonb),
  ('en', 'whatsNew.item.envTemplates.detail', $json$"Protecting .env.* no longer blocks .env.example, .env.sample and similar templates: agents can read and edit them, and the \"directory denied\" loop is gone. .env, .env.local, .env.production and other real files stay protected."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.envTemplates.title', $json$"Arquivos .env de exemplo voltam a ser legíveis pelos agentes"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.envTemplates.detail', $json$"Proteger .env.* não bloqueia mais .env.example, .env.sample e moldes parecidos: os agentes conseguem ler e editar, e o ciclo de \"directory denied\" some. O .env, .env.local, .env.production e outros arquivos reais continuam protegidos."$json$::jsonb),
  ('es', 'whatsNew.item.envTemplates.title', $json$"Los archivos .env de ejemplo vuelven a ser legibles para los agentes"$json$::jsonb),
  ('es', 'whatsNew.item.envTemplates.detail', $json$"Proteger .env.* ya no bloquea .env.example, .env.sample ni plantillas similares: los agentes pueden leerlos y editarlos y desaparece el bucle de \"directory denied\". .env, .env.local, .env.production y otros archivos reales siguen protegidos."$json$::jsonb),
  ('fr', 'whatsNew.item.envTemplates.title', $json$"Les fichiers .env d'exemple redeviennent lisibles par les agents"$json$::jsonb),
  ('fr', 'whatsNew.item.envTemplates.detail', $json$"Protéger .env.* ne bloque plus .env.example, .env.sample ni les modèles similaires : les agents peuvent les lire et les modifier, et la boucle « directory denied » disparaît. .env, .env.local, .env.production et les autres vrais fichiers restent protégés."$json$::jsonb),
  ('de', 'whatsNew.item.envTemplates.title', $json$"Beispiel-.env-Dateien sind für Agenten wieder lesbar"$json$::jsonb),
  ('de', 'whatsNew.item.envTemplates.detail', $json$"Der Schutz von .env.* blockiert .env.example, .env.sample und ähnliche Vorlagen nicht mehr: Agenten können sie lesen und bearbeiten, die „directory denied“-Schleife entfällt. .env, .env.local, .env.production und andere echte Dateien bleiben geschützt."$json$::jsonb),
  ('ru', 'whatsNew.item.envTemplates.title', $json$"Примеры .env снова доступны агентам"$json$::jsonb),
  ('ru', 'whatsNew.item.envTemplates.detail', $json$"Защита .env.* больше не блокирует .env.example, .env.sample и похожие шаблоны: агенты могут их читать и править, а цикл «directory denied» исчезает. .env, .env.local, .env.production и другие настоящие файлы остаются защищёнными."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.envTemplates.title', $json$"示例 .env 文件重新可供代理读取"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.envTemplates.detail', $json$"保护 .env.* 不再拦截 .env.example、.env.sample 等模板文件：代理可以读取和编辑它们，“directory denied”的循环也消失了。.env、.env.local、.env.production 等真实文件仍受保护。"$json$::jsonb),
  ('ja', 'whatsNew.item.envTemplates.title', $json$"サンプルの .env ファイルをエージェントが読めるように"$json$::jsonb),
  ('ja', 'whatsNew.item.envTemplates.detail', $json$"`.env.*` の保護が .env.example や .env.sample などのテンプレートをブロックしなくなりました。エージェントは読み書きでき、「directory denied」の繰り返しもなくなります。.env、.env.local、.env.production などの実ファイルは引き続き保護されます。"$json$::jsonb),
  ('hi', 'whatsNew.item.envTemplates.title', $json$"उदाहरण .env फ़ाइलें फिर से एजेंटों के लिए पढ़ने योग्य"$json$::jsonb),
  ('hi', 'whatsNew.item.envTemplates.detail', $json$"`.env.*` की सुरक्षा अब .env.example, .env.sample और ऐसे टेम्पलेट को नहीं रोकती: एजेंट उन्हें पढ़ और संपादित कर सकते हैं, और \"directory denied\" का चक्र खत्म हो गया। .env, .env.local, .env.production जैसी असली फ़ाइलें सुरक्षित रहती हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.envTemplates.title', $json$"ملفات .env التجريبية مقروءة للوكلاء من جديد"$json$::jsonb),
  ('ar', 'whatsNew.item.envTemplates.detail', $json$"حماية ‎.env.*‎ لم تعد تمنع ‎.env.example‎ و‎.env.sample‎ والقوالب المشابهة: يستطيع الوكلاء قراءتها وتعديلها وتنتهي حلقة «directory denied». تبقى ملفات ‎.env‎ و‎.env.local‎ و‎.env.production‎ وغيرها من الملفات الحقيقية محمية."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
