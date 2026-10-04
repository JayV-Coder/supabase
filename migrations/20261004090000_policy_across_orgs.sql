-- v0.51.4: o projeto ligado a mais de uma organização roda sob a política
-- mais rígida de todas elas.
--
-- Antes, `my_project_policies` olhava só a organização do projeto ou, fora
-- dela, o primeiro repositório da lista (`project_repository` corta em um):
-- um projeto com o clone de `acme/api` e o de `outra/x` ficava só com a
-- política da Acme. Agora entram a organização do projeto e cada repositório
-- dele que alguma organização cadastrou, e o app recebe uma linha por
-- projeto com a junção de todas, pela mais rígida — o mesmo formato de antes,
-- então as versões anteriores do app também passam a receber a junção.

-- Junta duas políticas efetivas pela mais rígida: agentes pela interseção
-- (nulo é "todos"), listas pela união, booleanos pelo "ou", regras de saída
-- pela mais rígida.
create function public.policy_merge(a jsonb, b jsonb) returns jsonb language sql immutable set search_path = '' as $$
  select case
    when a is null then b
    when b is null then a
    else jsonb_build_object(
      'agents', case
        when jsonb_typeof(a->'agents') is distinct from 'array' then b->'agents'
        when jsonb_typeof(b->'agents') is distinct from 'array' then a->'agents'
        else coalesce((
          select jsonb_agg(x order by position)
          from jsonb_array_elements_text(a->'agents') with ordinality as t(x, position)
          where b->'agents' ? x
        ), '[]'::jsonb)
      end,
      'blocked_models', to_jsonb(public.policy_union(
        array(select jsonb_array_elements_text(coalesce(a->'blocked_models', '[]'))),
        array(select jsonb_array_elements_text(coalesce(b->'blocked_models', '[]'))))),
      'deny', to_jsonb(public.policy_union(
        array(select jsonb_array_elements_text(coalesce(a->'deny', '[]'))),
        array(select jsonb_array_elements_text(coalesce(b->'deny', '[]'))))),
      'local_only', to_jsonb(public.policy_union(
        array(select jsonb_array_elements_text(coalesce(a->'local_only', '[]'))),
        array(select jsonb_array_elements_text(coalesce(b->'local_only', '[]'))))),
      'safe_agents', coalesce((a->>'safe_agents')::boolean, false) or coalesce((b->>'safe_agents')::boolean, false),
      'redact_secrets', coalesce((a->>'redact_secrets')::boolean, false) or coalesce((b->>'redact_secrets')::boolean, false),
      'min_read', public.policy_strictest(coalesce(a->>'min_read', 'allow'), coalesce(b->>'min_read', 'allow')),
      'min_write', public.policy_strictest(coalesce(a->>'min_write', 'allow'), coalesce(b->>'min_write', 'allow')),
      'min_shell', public.policy_strictest(coalesce(a->>'min_shell', 'allow'), coalesce(b->>'min_shell', 'allow'))
    )
  end;
$$;

create aggregate public.policy_merge_all(jsonb) (sfunc = public.policy_merge, stype = jsonb);

revoke execute on function public.policy_merge(jsonb, jsonb) from public, anon, authenticated;

-- Uma linha por projeto. `org_slug` lista as organizações, a do projeto
-- primeiro; `org_id` é a primeira delas.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  select linked.project_id,
         (array_agg(linked.org_id order by linked.own desc, o.slug))[1],
         string_agg(distinct o.slug, ', '),
         public.policy_merge_all(linked.policy order by linked.own desc, o.slug)
  from (
    -- A organização do projeto, quando quem chama é membro dela: vale a
    -- política dela e a de todos os repositórios dela.
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    -- Cada repositório do projeto que uma organização de quem chama
    -- cadastrou, não só o primeiro.
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
  ) linked
  join public.organizations o on o.id = linked.org_id
  where linked.policy is not null
  group by linked.project_id;
$$;

-- A checagem da resposta pelo Jev (`verification`) nunca foi ligada no app e
-- saiu do código; as perguntas dela saem junto, e a função `jev` deixa de
-- aceitar o conjunto.
delete from public.jev_questions where question_set = 'verification';

-- Os textos da v0.51.4, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'turn.interrupted', $json$"O app fechou com este pedido no ar, e ele parou aí. Nada foi retomado sozinho: reenvie se quiser continuar."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.indexAfterBuild.title', $json$"A busca enxerga o que o agente acabou de criar"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.indexAfterBuild.detail', $json$"O índice do projeto era lido uma vez e não mudava depois que um agente editava arquivos no modo Desenvolvimento: arquivos novos ficavam fora da busca, do mapa e dos símbolos. Agora, depois de cada pedido em Desenvolvimento, a pasta é lida de novo no pedido seguinte."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.settingsWhileWorking.title', $json$"Configurações e Sistema abrem com um agente trabalhando"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.settingsWhileWorking.detail', $json$"As duas páginas ficavam em \"Carregando…\" até o pedido em andamento terminar. Agora abrem na hora; o que você salvar enquanto o agente trabalha vale a partir do próximo pedido."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.titlesWithCli.title', $json$"Título do chat também com agentes de linha de comando"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.titlesWithCli.detail', $json$"Sem nenhum modelo por API configurado, o chat ficava com as primeiras palavras do pedido. Agora o agente de linha de comando dá o título, no modelo mais barato dele e em somente leitura: uma chamada curta, uma vez por chat, sem segurar o próximo pedido da fila."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.policyAcrossOrgs.title', $json$"Projeto em duas organizações segue a política mais rígida"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.policyAcrossOrgs.detail', $json$"Um projeto com repositórios de duas organizações usava só a política de LLM da primeira. Agora vale a junção de todas, pela mais rígida: só os agentes que todas permitem, os padrões de privacidade de todas e a regra de saída mais dura de cada uma."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.interruptedNotResumed.title', $json$"Pedido interrompido ao fechar o app não recomeça sozinho"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.interruptedNotResumed.detail', $json$"Ao reabrir o app, o pedido que estava no ar voltava para a fila e rodava de novo do zero, inclusive um build pela metade numa pasta já mexida. Agora ele aparece como falho, com o motivo, e o reenvio fica a um clique. Pedidos que só esperavam a vez continuam na fila."$json$::jsonb),
  ('en', 'turn.interrupted', $json$"The app closed while this request was running, so it stopped there. Nothing was resumed on its own: send it again to continue."$json$::jsonb),
  ('en', 'whatsNew.item.indexAfterBuild.title', $json$"Search sees what the agent just created"$json$::jsonb),
  ('en', 'whatsNew.item.indexAfterBuild.detail', $json$"The project index was read once and did not change after an agent edited files in Development mode: new files stayed out of search, the map and the symbols. Now, after each Development request, the folder is read again for the next request."$json$::jsonb),
  ('en', 'whatsNew.item.settingsWhileWorking.title', $json$"Settings and System open while an agent works"$json$::jsonb),
  ('en', 'whatsNew.item.settingsWhileWorking.detail', $json$"Both pages stayed on \"Loading…\" until the running request finished. Now they open right away; what you save while the agent works applies from the next request."$json$::jsonb),
  ('en', 'whatsNew.item.titlesWithCli.title', $json$"Chat titles with command-line agents too"$json$::jsonb),
  ('en', 'whatsNew.item.titlesWithCli.detail', $json$"With no API model set up, the chat kept the first words of the request as its title. Now the command-line agent names it, on its cheapest model and read-only: one short call, once per chat, without holding up the next request in the queue."$json$::jsonb),
  ('en', 'whatsNew.item.policyAcrossOrgs.title', $json$"A project in two organizations follows the stricter policy"$json$::jsonb),
  ('en', 'whatsNew.item.policyAcrossOrgs.detail', $json$"A project with repositories from two organizations used only the LLM policy of the first one. Now all of them apply together, whichever is stricter: only the agents every one allows, the privacy patterns of all and the toughest exit rule of each."$json$::jsonb),
  ('en', 'whatsNew.item.interruptedNotResumed.title', $json$"A request cut off by closing the app does not restart by itself"$json$::jsonb),
  ('en', 'whatsNew.item.interruptedNotResumed.detail', $json$"When the app reopened, the request that was running went back to the queue and ran again from scratch, even a half-done build in a folder already changed. Now it shows as failed, with the reason, and resending is one click away. Requests that were only waiting their turn stay in the queue."$json$::jsonb),
  ('es', 'turn.interrupted', $json$"La app se cerró mientras esta solicitud estaba en curso, así que se detuvo ahí. Nada se reanudó solo: reenvíala si quieres continuar."$json$::jsonb),
  ('es', 'whatsNew.item.indexAfterBuild.title', $json$"La búsqueda ve lo que el agente acaba de crear"$json$::jsonb),
  ('es', 'whatsNew.item.indexAfterBuild.detail', $json$"El índice del proyecto se leía una vez y no cambiaba después de que un agente editara archivos en el modo Desarrollo: los archivos nuevos quedaban fuera de la búsqueda, el mapa y los símbolos. Ahora, después de cada solicitud en Desarrollo, la carpeta se vuelve a leer en la siguiente."$json$::jsonb),
  ('es', 'whatsNew.item.settingsWhileWorking.title', $json$"Configuración y Sistema se abren mientras un agente trabaja"$json$::jsonb),
  ('es', 'whatsNew.item.settingsWhileWorking.detail', $json$"Las dos páginas se quedaban en \"Cargando…\" hasta que terminaba la solicitud en curso. Ahora se abren al instante; lo que guardes mientras el agente trabaja se aplica desde la próxima solicitud."$json$::jsonb),
  ('es', 'whatsNew.item.titlesWithCli.title', $json$"Título del chat también con agentes de línea de comandos"$json$::jsonb),
  ('es', 'whatsNew.item.titlesWithCli.detail', $json$"Sin ningún modelo por API configurado, el chat se quedaba con las primeras palabras de la solicitud. Ahora el agente de línea de comandos le pone el título, con su modelo más barato y en solo lectura: una llamada corta, una vez por chat, sin retrasar la siguiente solicitud de la cola."$json$::jsonb),
  ('es', 'whatsNew.item.policyAcrossOrgs.title', $json$"Un proyecto en dos organizaciones sigue la política más estricta"$json$::jsonb),
  ('es', 'whatsNew.item.policyAcrossOrgs.detail', $json$"Un proyecto con repositorios de dos organizaciones usaba solo la política de LLM de la primera. Ahora se aplican todas juntas, la más estricta: solo los agentes que todas permiten, los patrones de privacidad de todas y la regla de salida más dura de cada una."$json$::jsonb),
  ('es', 'whatsNew.item.interruptedNotResumed.title', $json$"Una solicitud interrumpida al cerrar la app no se reinicia sola"$json$::jsonb),
  ('es', 'whatsNew.item.interruptedNotResumed.detail', $json$"Al reabrir la app, la solicitud en curso volvía a la cola y se ejecutaba de nuevo desde cero, incluso una construcción a medias en una carpeta ya modificada. Ahora aparece como fallida, con el motivo, y reenviarla está a un clic. Las solicitudes que solo esperaban su turno siguen en la cola."$json$::jsonb),
  ('zh-CN', 'turn.interrupted', $json$"应用在此请求运行时关闭，因此请求在那里停止。没有任何内容自动恢复：如需继续，请重新发送。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.indexAfterBuild.title', $json$"搜索能看到代理刚创建的内容"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.indexAfterBuild.detail', $json$"项目索引只读取一次，代理在开发模式下编辑文件后也不会更新：新文件不会出现在搜索、地图和符号中。现在，每个开发模式请求之后，下一个请求会重新读取文件夹。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.settingsWhileWorking.title', $json$"代理工作时也能打开设置和系统页面"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.settingsWhileWorking.detail', $json$"这两个页面以前会一直显示“加载中…”，直到正在运行的请求结束。现在会立即打开；代理工作期间保存的内容从下一个请求开始生效。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.titlesWithCli.title', $json$"使用命令行代理时也能生成聊天标题"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.titlesWithCli.detail', $json$"如果没有配置任何 API 模型，聊天标题会使用请求的前几个词。现在由命令行代理以其最便宜的模型、只读方式命名：每个聊天只调用一次简短请求，不会耽误队列中的下一个请求。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.policyAcrossOrgs.title', $json$"属于两个组织的项目遵循更严格的策略"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.policyAcrossOrgs.detail', $json$"包含两个组织仓库的项目以前只使用第一个组织的 LLM 策略。现在所有策略一起生效，以更严格者为准：只允许所有组织都允许的代理，合并所有隐私规则，并取每项输出规则中最严格的。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.interruptedNotResumed.title', $json$"关闭应用时中断的请求不会自行重新开始"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.interruptedNotResumed.detail', $json$"重新打开应用时，正在运行的请求会回到队列并从头再运行一次，即使是在已被修改的文件夹中进行到一半的构建。现在它会显示为失败并附上原因，一键即可重新发送。仅在排队等待的请求仍保留在队列中。"$json$::jsonb),
  ('hi', 'turn.interrupted', $json$"यह अनुरोध चलते समय ऐप बंद हो गया, इसलिए यह वहीं रुक गया। कुछ भी अपने आप फिर से शुरू नहीं हुआ: जारी रखने के लिए इसे फिर से भेजें।"$json$::jsonb),
  ('hi', 'whatsNew.item.indexAfterBuild.title', $json$"खोज वह देखती है जो एजेंट ने अभी बनाया"$json$::jsonb),
  ('hi', 'whatsNew.item.indexAfterBuild.detail', $json$"प्रोजेक्ट इंडेक्स एक बार पढ़ा जाता था और डेवलपमेंट मोड में एजेंट के फ़ाइलें बदलने के बाद नहीं बदलता था: नई फ़ाइलें खोज, मैप और सिंबल से बाहर रह जाती थीं। अब डेवलपमेंट के हर अनुरोध के बाद, अगले अनुरोध में फ़ोल्डर फिर से पढ़ा जाता है।"$json$::jsonb),
  ('hi', 'whatsNew.item.settingsWhileWorking.title', $json$"एजेंट के काम करते समय भी सेटिंग्स और सिस्टम खुलते हैं"$json$::jsonb),
  ('hi', 'whatsNew.item.settingsWhileWorking.detail', $json$"दोनों पेज चल रहा अनुरोध पूरा होने तक \"लोड हो रहा है…\" पर रुके रहते थे। अब वे तुरंत खुलते हैं; एजेंट के काम करते समय आप जो सहेजते हैं, वह अगले अनुरोध से लागू होता है।"$json$::jsonb),
  ('hi', 'whatsNew.item.titlesWithCli.title', $json$"कमांड-लाइन एजेंट के साथ भी चैट का शीर्षक"$json$::jsonb),
  ('hi', 'whatsNew.item.titlesWithCli.detail', $json$"कोई API मॉडल सेट न होने पर चैट का शीर्षक अनुरोध के पहले शब्द रहते थे। अब कमांड-लाइन एजेंट अपने सबसे सस्ते मॉडल पर, केवल-पढ़ने के मोड में शीर्षक देता है: हर चैट के लिए एक छोटी कॉल, एक बार, कतार के अगले अनुरोध को रोके बिना।"$json$::jsonb),
  ('hi', 'whatsNew.item.policyAcrossOrgs.title', $json$"दो संगठनों वाला प्रोजेक्ट अधिक सख़्त नीति का पालन करता है"$json$::jsonb),
  ('hi', 'whatsNew.item.policyAcrossOrgs.detail', $json$"दो संगठनों की रिपॉज़िटरी वाला प्रोजेक्ट केवल पहले संगठन की LLM नीति इस्तेमाल करता था। अब सभी नीतियाँ साथ लागू होती हैं, जो अधिक सख़्त हो: केवल वे एजेंट जिन्हें सभी अनुमति देते हैं, सभी के गोपनीयता पैटर्न और हर एक का सबसे सख़्त आउटपुट नियम।"$json$::jsonb),
  ('hi', 'whatsNew.item.interruptedNotResumed.title', $json$"ऐप बंद करने से कटा अनुरोध अपने आप फिर शुरू नहीं होता"$json$::jsonb),
  ('hi', 'whatsNew.item.interruptedNotResumed.detail', $json$"ऐप दोबारा खुलने पर, चल रहा अनुरोध कतार में लौटकर शुरू से फिर चलता था, यहाँ तक कि पहले से बदले फ़ोल्डर में आधा बना बिल्ड भी। अब यह कारण के साथ विफल दिखता है, और दोबारा भेजना एक क्लिक पर है। जो अनुरोध सिर्फ़ अपनी बारी का इंतज़ार कर रहे थे, वे कतार में बने रहते हैं।"$json$::jsonb),
  ('ar', 'turn.interrupted', $json$"أُغلق التطبيق أثناء تنفيذ هذا الطلب، فتوقف عند ذلك الحد. لم يُستأنف أي شيء تلقائيًا: أعد إرساله إذا أردت المتابعة."$json$::jsonb),
  ('ar', 'whatsNew.item.indexAfterBuild.title', $json$"البحث يرى ما أنشأه الوكيل للتو"$json$::jsonb),
  ('ar', 'whatsNew.item.indexAfterBuild.detail', $json$"كان فهرس المشروع يُقرأ مرة واحدة ولا يتغير بعد أن يعدّل وكيلٌ الملفات في وضع التطوير: فتبقى الملفات الجديدة خارج البحث والخريطة والرموز. الآن، بعد كل طلب في وضع التطوير، يُعاد قراءة المجلد في الطلب التالي."$json$::jsonb),
  ('ar', 'whatsNew.item.settingsWhileWorking.title', $json$"الإعدادات والنظام يُفتحان أثناء عمل الوكيل"$json$::jsonb),
  ('ar', 'whatsNew.item.settingsWhileWorking.detail', $json$"كانت الصفحتان تبقيان على \"جارٍ التحميل…\" حتى ينتهي الطلب الجاري. الآن تُفتحان فورًا، وما تحفظه أثناء عمل الوكيل يُطبَّق بدءًا من الطلب التالي."$json$::jsonb),
  ('ar', 'whatsNew.item.titlesWithCli.title', $json$"عنوان المحادثة مع وكلاء سطر الأوامر أيضًا"$json$::jsonb),
  ('ar', 'whatsNew.item.titlesWithCli.detail', $json$"عند عدم إعداد أي نموذج عبر API، كان عنوان المحادثة هو أولى كلمات الطلب. الآن يمنحها وكيل سطر الأوامر عنوانًا، بأرخص نماذجه وفي وضع القراءة فقط: استدعاء قصير، مرة واحدة لكل محادثة، دون تأخير الطلب التالي في الطابور."$json$::jsonb),
  ('ar', 'whatsNew.item.policyAcrossOrgs.title', $json$"المشروع التابع لمنظمتين يتبع السياسة الأشد"$json$::jsonb),
  ('ar', 'whatsNew.item.policyAcrossOrgs.detail', $json$"كان المشروع الذي يضم مستودعات من منظمتين يستخدم سياسة LLM للأولى فقط. الآن تُطبَّق كلها معًا، بالأشد منها: الوكلاء الذين تسمح بهم جميعها فقط، وأنماط الخصوصية لكل منها، وأشد قاعدة خروج في كل واحدة."$json$::jsonb),
  ('ar', 'whatsNew.item.interruptedNotResumed.title', $json$"الطلب الذي قُطع بإغلاق التطبيق لا يبدأ من جديد تلقائيًا"$json$::jsonb),
  ('ar', 'whatsNew.item.interruptedNotResumed.detail', $json$"عند إعادة فتح التطبيق، كان الطلب الجاري يعود إلى الطابور ويُنفَّذ من البداية، حتى لو كان بناءً غير مكتمل في مجلد تغيّر بالفعل. الآن يظهر كفاشل مع السبب، وإعادة الإرسال على بُعد نقرة. أما الطلبات التي كانت تنتظر دورها فقط فتبقى في الطابور."$json$::jsonb),
  ('fr', 'turn.interrupted', $json$"L'app s'est fermée pendant que cette demande était en cours, elle s'est donc arrêtée là. Rien n'a repris tout seul : renvoyez-la pour continuer."$json$::jsonb),
  ('fr', 'whatsNew.item.indexAfterBuild.title', $json$"La recherche voit ce que l'agent vient de créer"$json$::jsonb),
  ('fr', 'whatsNew.item.indexAfterBuild.detail', $json$"L'index du projet était lu une seule fois et ne changeait pas après qu'un agent avait modifié des fichiers en mode Développement : les nouveaux fichiers restaient hors de la recherche, de la carte et des symboles. Désormais, après chaque demande en Développement, le dossier est relu pour la demande suivante."$json$::jsonb),
  ('fr', 'whatsNew.item.settingsWhileWorking.title', $json$"Paramètres et Système s'ouvrent pendant qu'un agent travaille"$json$::jsonb),
  ('fr', 'whatsNew.item.settingsWhileWorking.detail', $json$"Les deux pages restaient sur « Chargement… » jusqu'à la fin de la demande en cours. Elles s'ouvrent désormais tout de suite ; ce que vous enregistrez pendant que l'agent travaille s'applique à partir de la demande suivante."$json$::jsonb),
  ('fr', 'whatsNew.item.titlesWithCli.title', $json$"Titre du chat aussi avec les agents en ligne de commande"$json$::jsonb),
  ('fr', 'whatsNew.item.titlesWithCli.detail', $json$"Sans aucun modèle par API configuré, le chat gardait les premiers mots de la demande comme titre. Désormais l'agent en ligne de commande le nomme, avec son modèle le moins cher et en lecture seule : un appel court, une fois par chat, sans retenir la demande suivante de la file."$json$::jsonb),
  ('fr', 'whatsNew.item.policyAcrossOrgs.title', $json$"Un projet dans deux organisations suit la politique la plus stricte"$json$::jsonb),
  ('fr', 'whatsNew.item.policyAcrossOrgs.detail', $json$"Un projet avec des dépôts de deux organisations n'utilisait que la politique LLM de la première. Désormais toutes s'appliquent ensemble, la plus stricte l'emportant : seuls les agents que toutes autorisent, les motifs de confidentialité de toutes et la règle de sortie la plus dure de chacune."$json$::jsonb),
  ('fr', 'whatsNew.item.interruptedNotResumed.title', $json$"Une demande coupée par la fermeture de l'app ne redémarre plus seule"$json$::jsonb),
  ('fr', 'whatsNew.item.interruptedNotResumed.detail', $json$"À la réouverture de l'app, la demande en cours retournait dans la file et repartait de zéro, même un build à moitié fait dans un dossier déjà modifié. Elle apparaît maintenant comme échouée, avec la raison, et la renvoyer ne prend qu'un clic. Les demandes qui attendaient seulement leur tour restent dans la file."$json$::jsonb),
  ('ru', 'turn.interrupted', $json$"Приложение закрылось, пока выполнялся этот запрос, и он остановился. Ничего не возобновилось само: отправьте его снова, чтобы продолжить."$json$::jsonb),
  ('ru', 'whatsNew.item.indexAfterBuild.title', $json$"Поиск видит то, что агент только что создал"$json$::jsonb),
  ('ru', 'whatsNew.item.indexAfterBuild.detail', $json$"Индекс проекта читался один раз и не менялся после того, как агент правил файлы в режиме разработки: новые файлы не попадали в поиск, карту и символы. Теперь после каждого запроса в режиме разработки папка перечитывается для следующего запроса."$json$::jsonb),
  ('ru', 'whatsNew.item.settingsWhileWorking.title', $json$"Настройки и «Система» открываются, пока агент работает"$json$::jsonb),
  ('ru', 'whatsNew.item.settingsWhileWorking.detail', $json$"Обе страницы показывали «Загрузка…», пока не завершался текущий запрос. Теперь они открываются сразу; то, что вы сохраните во время работы агента, применяется со следующего запроса."$json$::jsonb),
  ('ru', 'whatsNew.item.titlesWithCli.title', $json$"Название чата и с агентами командной строки"$json$::jsonb),
  ('ru', 'whatsNew.item.titlesWithCli.detail', $json$"Если не был настроен ни один API-модель, название чата состояло из первых слов запроса. Теперь название даёт агент командной строки — на самой дешёвой своей модели и только для чтения: один короткий вызов на чат, не задерживая следующий запрос в очереди."$json$::jsonb),
  ('ru', 'whatsNew.item.policyAcrossOrgs.title', $json$"Проект в двух организациях следует более строгой политике"$json$::jsonb),
  ('ru', 'whatsNew.item.policyAcrossOrgs.detail', $json$"Проект с репозиториями из двух организаций использовал только политику LLM первой. Теперь действуют все вместе, по самой строгой: только агенты, разрешённые всеми, шаблоны приватности всех и самое жёсткое правило вывода каждой."$json$::jsonb),
  ('ru', 'whatsNew.item.interruptedNotResumed.title', $json$"Запрос, прерванный закрытием приложения, не перезапускается сам"$json$::jsonb),
  ('ru', 'whatsNew.item.interruptedNotResumed.detail', $json$"При повторном открытии приложения выполнявшийся запрос возвращался в очередь и запускался заново с нуля — даже наполовину сделанная сборка в уже изменённой папке. Теперь он отображается как неудачный, с причиной, а повторная отправка — в один клик. Запросы, которые лишь ждали своей очереди, остаются в ней."$json$::jsonb),
  ('ja', 'turn.interrupted', $json$"このリクエストの実行中にアプリが閉じたため、そこで止まりました。自動では再開していません。続けるにはもう一度送信してください。"$json$::jsonb),
  ('ja', 'whatsNew.item.indexAfterBuild.title', $json$"エージェントが作ったばかりのものを検索が見つけます"$json$::jsonb),
  ('ja', 'whatsNew.item.indexAfterBuild.detail', $json$"プロジェクトのインデックスは一度だけ読み込まれ、開発モードでエージェントがファイルを編集しても更新されませんでした。新しいファイルは検索、マップ、シンボルに含まれませんでした。今後は開発モードのリクエストのたびに、次のリクエストでフォルダーを読み直します。"$json$::jsonb),
  ('ja', 'whatsNew.item.settingsWhileWorking.title', $json$"エージェントの作業中でも設定とシステムが開きます"$json$::jsonb),
  ('ja', 'whatsNew.item.settingsWhileWorking.detail', $json$"両方のページは実行中のリクエストが終わるまで「読み込み中…」のままでした。今はすぐに開きます。エージェントの作業中に保存した内容は次のリクエストから反映されます。"$json$::jsonb),
  ('ja', 'whatsNew.item.titlesWithCli.title', $json$"コマンドラインエージェントでもチャットのタイトルを付けます"$json$::jsonb),
  ('ja', 'whatsNew.item.titlesWithCli.detail', $json$"API モデルが設定されていない場合、チャットのタイトルはリクエストの最初の数語のままでした。今はコマンドラインエージェントが、最も安いモデルを読み取り専用で使って名前を付けます。チャットごとに一度だけの短い呼び出しで、キューの次のリクエストを待たせません。"$json$::jsonb),
  ('ja', 'whatsNew.item.policyAcrossOrgs.title', $json$"2 つの組織に属するプロジェクトはより厳しいポリシーに従います"$json$::jsonb),
  ('ja', 'whatsNew.item.policyAcrossOrgs.detail', $json$"2 つの組織のリポジトリを持つプロジェクトは、最初の組織の LLM ポリシーだけを使っていました。今はすべてをまとめて、より厳しいほうを適用します。すべてが許可するエージェントのみ、すべてのプライバシーパターン、それぞれで最も厳しい出力ルールです。"$json$::jsonb),
  ('ja', 'whatsNew.item.interruptedNotResumed.title', $json$"アプリを閉じて中断されたリクエストは自動で再開しません"$json$::jsonb),
  ('ja', 'whatsNew.item.interruptedNotResumed.detail', $json$"アプリを再度開くと、実行中だったリクエストがキューに戻って最初からやり直されていました。すでに変更されたフォルダーでの途中のビルドも同様です。今は理由付きの失敗として表示され、ワンクリックで再送できます。順番を待っていただけのリクエストはキューに残ります。"$json$::jsonb),
  ('de', 'turn.interrupted', $json$"Die App wurde geschlossen, während diese Anfrage lief, daher hat sie dort aufgehört. Nichts wurde von selbst fortgesetzt: Sende sie erneut, um weiterzumachen."$json$::jsonb),
  ('de', 'whatsNew.item.indexAfterBuild.title', $json$"Die Suche sieht, was der Agent gerade erstellt hat"$json$::jsonb),
  ('de', 'whatsNew.item.indexAfterBuild.detail', $json$"Der Projektindex wurde einmal gelesen und änderte sich nicht, nachdem ein Agent im Entwicklungsmodus Dateien bearbeitet hatte: Neue Dateien fehlten in Suche, Karte und Symbolen. Jetzt wird der Ordner nach jeder Anfrage im Entwicklungsmodus für die nächste Anfrage neu gelesen."$json$::jsonb),
  ('de', 'whatsNew.item.settingsWhileWorking.title', $json$"Einstellungen und System öffnen sich, während ein Agent arbeitet"$json$::jsonb),
  ('de', 'whatsNew.item.settingsWhileWorking.detail', $json$"Beide Seiten blieben bei „Wird geladen…“, bis die laufende Anfrage fertig war. Jetzt öffnen sie sofort; was du speicherst, während der Agent arbeitet, gilt ab der nächsten Anfrage."$json$::jsonb),
  ('de', 'whatsNew.item.titlesWithCli.title', $json$"Chattitel auch mit Kommandozeilen-Agenten"$json$::jsonb),
  ('de', 'whatsNew.item.titlesWithCli.detail', $json$"Ohne eingerichtetes API-Modell behielt der Chat die ersten Wörter der Anfrage als Titel. Jetzt benennt ihn der Kommandozeilen-Agent, mit seinem günstigsten Modell und nur lesend: ein kurzer Aufruf, einmal pro Chat, ohne die nächste Anfrage in der Warteschlange aufzuhalten."$json$::jsonb),
  ('de', 'whatsNew.item.policyAcrossOrgs.title', $json$"Ein Projekt in zwei Organisationen folgt der strengeren Richtlinie"$json$::jsonb),
  ('de', 'whatsNew.item.policyAcrossOrgs.detail', $json$"Ein Projekt mit Repositorys aus zwei Organisationen nutzte nur die LLM-Richtlinie der ersten. Jetzt gelten alle zusammen, jeweils die strengere: nur die Agenten, die alle erlauben, die Datenschutzmuster aller und die härteste Ausgaberegel jeder einzelnen."$json$::jsonb),
  ('de', 'whatsNew.item.interruptedNotResumed.title', $json$"Eine durch Schließen der App abgebrochene Anfrage startet nicht von selbst neu"$json$::jsonb),
  ('de', 'whatsNew.item.interruptedNotResumed.detail', $json$"Beim erneuten Öffnen der App ging die laufende Anfrage zurück in die Warteschlange und lief noch einmal von vorn, selbst ein halb fertiger Build in einem schon veränderten Ordner. Jetzt erscheint sie als fehlgeschlagen, mit dem Grund, und erneutes Senden ist einen Klick entfernt. Anfragen, die nur auf ihre Reihe warteten, bleiben in der Warteschlange."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
