-- v0.82.0: toda organização já tem quatro servidores MCP oficiais cadastrados
-- (sequential-thinking, fetch, git e memory) e o servidor que a organização
-- desliga passa a descer ao app com `enabled = false`, para valer por cima do
-- servidor da pessoa com o mesmo nome (e não deixá-lo voltar por baixo).
--
-- `fetch` e `git` não existem no npm (`@modelcontextprotocol/server-fetch` e
-- `-git`): os oficiais são em Python e sobem pelo `uvx`.

-- Os quatro, no formato do app (`McpServer`, em camelCase).
create function public.org_mcp_defaults() returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_array(
    jsonb_build_object('name', 'sequential-thinking', 'transport', 'stdio', 'command', 'npx', 'args', jsonb_build_array('-y', '@modelcontextprotocol/server-sequential-thinking'), 'env', '{}'::jsonb, 'url', '', 'headers', '{}'::jsonb, 'agents', '[]'::jsonb, 'enabled', true),
    jsonb_build_object('name', 'fetch', 'transport', 'stdio', 'command', 'uvx', 'args', jsonb_build_array('mcp-server-fetch'), 'env', '{}'::jsonb, 'url', '', 'headers', '{}'::jsonb, 'agents', '[]'::jsonb, 'enabled', true),
    jsonb_build_object('name', 'git', 'transport', 'stdio', 'command', 'uvx', 'args', jsonb_build_array('mcp-server-git'), 'env', '{}'::jsonb, 'url', '', 'headers', '{}'::jsonb, 'agents', '[]'::jsonb, 'enabled', true),
    jsonb_build_object('name', 'memory', 'transport', 'stdio', 'command', 'npx', 'args', jsonb_build_array('-y', '@modelcontextprotocol/server-memory'), 'env', '{}'::jsonb, 'url', '', 'headers', '{}'::jsonb, 'agents', '[]'::jsonb, 'enabled', true)
  );
$$;

-- Cadastra os quatro como linhas comuns (desligar, trocar e remover valem para
-- eles). Um servidor da organização com o mesmo nome fica como está.
create function public.org_seed_mcp_defaults(org uuid) returns void language sql security definer set search_path = '' as $$
  insert into public.organization_mcp_servers (org_id, name, config, enabled)
  select org, d->>'name', d, true from jsonb_array_elements(public.org_mcp_defaults()) d
  on conflict (org_id, name) do nothing;
$$;

-- Só no nascimento da organização: o que o owner remove depois não volta.
create function public.organizations_seed_mcp() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.org_seed_mcp_defaults(new.id);
  return new;
end;
$$;

create trigger organizations_seed_mcp after insert on public.organizations
  for each row execute function public.organizations_seed_mcp();

-- As organizações que já existem recebem os quatro uma vez, ao rodar esta migração.
select public.org_seed_mcp_defaults(o.id) from public.organizations o;

do $$
declare
  fn text;
begin
  foreach fn in array array['org_mcp_defaults()', 'org_seed_mcp_defaults(uuid)', 'organizations_seed_mcp()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
end;
$$;

-- `my_org_extensions` agora devolve também os servidores desligados, com o
-- `enabled` de cada um: o app não os entrega ao agente, mas o servidor da
-- pessoa com o mesmo nome deixa de valer. As skills seguem só as ligadas.
create or replace function public.my_org_extensions()
returns table (project_id text, org_slug text, own boolean, mcp jsonb, skills jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    select pr.id as project_id, pr.org_id, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    select pr.id, r.org_id, false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    select '', m.org_id, false from public.organization_members m where m.user_id = auth.uid()
  ),
  picked as (
    select distinct on (l.project_id, l.org_id) l.project_id, l.org_id, l.own
    from linked l
    order by l.project_id, l.org_id, l.own desc
  )
  select p.project_id, o.slug, p.own,
    coalesce((select jsonb_agg(s.config || jsonb_build_object('enabled', s.enabled) order by s.name)
              from public.organization_mcp_servers s where s.org_id = p.org_id), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('name', k.name, 'description', k.description, 'body', k.body) order by k.name)
              from public.organization_skills k where k.org_id = p.org_id and k.enabled), '[]'::jsonb)
  from picked p
  join public.organizations o on o.id = p.org_id
  order by p.project_id, p.own desc, o.slug;
$$;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'docs.mcp.usage', $json$"Abra Configurações › MCP (ou Ctrl+K › Configurações › MCP) e adicione um servidor pelo formulário ou cole uma configuração (JSON mcpServers, uma linha claude mcp add ou um comando npx). No chat, digite /mcp seguido de uma configuração ou de uma descrição: um agente monta o rascunho e nada é salvo antes de você conferir. Os servidores das suas organizações aparecem abaixo dos seus e não se editam ali. Depois ligue Aprovar servidores MCP na aba de cada agente que deve usá-los (começa desligado); Ctrl+K › Aprovar servidores MCP faz o mesmo para um agente. As organizações podem bloquear por agente, e o modo planejamento nunca leva os servidores. Quatro servidores oficiais (sequential-thinking, fetch, git e memory) já vêm cadastrados, como entradas que você pode desligar, editar ou remover; fetch e git rodam pelo uvx, então o uv precisa estar instalado. Nos chats de uma organização (o geral e os de cada projeto), os servidores dela valem por cima dos seus com o mesmo nome, mesmo quando a organização desliga um."$json$::jsonb),
  ('en', 'docs.mcp.usage', $json$"Open Settings › MCP (or Ctrl+K › Settings › MCP) and add a server by form, or paste a configuration (mcpServers JSON, a claude mcp add line or an npx command). In a chat, type /mcp followed by a configuration or a description: an agent drafts the configuration and nothing is saved until you review it. Four official servers (sequential-thinking, fetch, git and memory) come registered, as entries you can turn off, edit or remove; fetch and git run through uvx, so uv must be installed. Servers from your organizations are listed below yours and cannot be edited there; in an organization’s chats (the general one and each project’s) they win over yours with the same name, even when the organization turns one off. Then turn on Approve MCP servers in the Settings tab of each agent that should use them (it starts off); Ctrl+K › Approve MCP servers does the same for one agent. Organizations can block it per agent, and planning mode never carries the servers."$json$::jsonb),
  ('es', 'docs.mcp.usage', $json$"Abre Configuración › MCP (o Ctrl+K › Configuración › MCP) y añade un servidor con el formulario o pega una configuración (JSON mcpServers, una línea claude mcp add o un comando npx). En un chat, escribe /mcp seguido de una configuración o una descripción: un agente prepara el borrador y no se guarda nada hasta que lo revises. Los servidores de tus organizaciones aparecen debajo de los tuyos y no se editan allí. Después activa Aprobar servidores MCP en la pestaña de cada agente que deba usarlos (empieza desactivado); Ctrl+K › Aprobar servidores MCP hace lo mismo para un agente. Las organizaciones pueden bloquearlo por agente, y el modo de planificación nunca lleva los servidores. Cuatro servidores oficiales (sequential-thinking, fetch, git y memory) vienen ya registrados, como entradas que puedes desactivar, editar o eliminar; fetch y git se ejecutan con uvx, así que uv debe estar instalado. En los chats de una organización (el general y los de cada proyecto), sus servidores tienen prioridad sobre los tuyos con el mismo nombre, incluso cuando la organización desactiva uno."$json$::jsonb),
  ('zh-CN', 'docs.mcp.usage', $json$"打开“设置 › MCP”（或 Ctrl+K › 设置 › MCP），通过表单添加服务器，或粘贴配置（mcpServers JSON、claude mcp add 命令行或 npx 命令）。在聊天中输入 /mcp，后面跟配置或描述：代理会生成草稿，你确认之前不会保存任何内容。你所在组织的服务器显示在你自己的下方，不能在那里编辑。然后在每个要使用它们的代理的设置标签页中开启“批准 MCP 服务器”（默认关闭）；Ctrl+K › 批准 MCP 服务器可对单个代理执行同样的操作。组织可以按代理屏蔽它，规划模式永远不会带上这些服务器。四个官方服务器（sequential-thinking、fetch、git 和 memory）已预先注册，是可以关闭、编辑或删除的普通条目；fetch 和 git 通过 uvx 运行，因此需要安装 uv。在组织的聊天（通用聊天和各项目的聊天）中，组织的服务器优先于你的同名服务器，即使组织将其关闭也一样。"$json$::jsonb),
  ('hi', 'docs.mcp.usage', $json$"सेटिंग › MCP खोलें (या Ctrl+K › सेटिंग › MCP) और फ़ॉर्म से सर्वर जोड़ें या कॉन्फ़िगरेशन चिपकाएँ (mcpServers JSON, claude mcp add पंक्ति या npx कमांड)। चैट में /mcp के बाद कॉन्फ़िगरेशन या विवरण लिखें: एजेंट मसौदा बनाता है और आपके जाँचने से पहले कुछ भी सहेजा नहीं जाता। आपके संगठनों के सर्वर आपके सर्वरों के नीचे दिखते हैं और वहाँ संपादित नहीं होते। फिर हर उस एजेंट के सेटिंग टैब में MCP सर्वर स्वीकृत करें चालू करें जिसे इन्हें इस्तेमाल करना है (यह बंद से शुरू होता है); Ctrl+K › MCP सर्वर स्वीकृत करें एक एजेंट के लिए यही करता है। संगठन इसे हर एजेंट के लिए अवरुद्ध कर सकते हैं, और योजना मोड कभी सर्वर नहीं ले जाता। चार आधिकारिक सर्वर (sequential-thinking, fetch, git और memory) पहले से रजिस्टर आते हैं, सामान्य प्रविष्टियों के रूप में जिन्हें आप बंद, संपादित या हटा सकते हैं; fetch और git uvx से चलते हैं, इसलिए uv इंस्टॉल होना चाहिए। किसी संगठन की चैट में (सामान्य चैट और हर प्रोजेक्ट की चैट) संगठन के सर्वर आपके उसी नाम वाले सर्वर पर भारी पड़ते हैं, भले ही संगठन उसे बंद कर दे।"$json$::jsonb),
  ('ar', 'docs.mcp.usage', $json$"افتح الإعدادات › MCP (أو Ctrl+K › الإعدادات › MCP) وأضف خادمًا بالنموذج أو الصق إعدادًا (JSON من mcpServers أو سطر claude mcp add أو أمر npx). في المحادثة اكتب ‎/mcp‎ متبوعًا بإعداد أو وصف: يُعدّ الوكيل مسودة ولا يُحفظ شيء قبل أن تراجعه. تظهر خوادم مؤسساتك أسفل خوادمك ولا تُعدَّل هناك. ثم فعّل «الموافقة على خوادم MCP» في تبويب كل وكيل يجب أن يستخدمها (يبدأ متوقفًا)؛ وCtrl+K › الموافقة على خوادم MCP يفعل الشيء نفسه لوكيل واحد. يمكن للمؤسسات حجبه لكل وكيل، ولا يحمل وضع التخطيط الخوادم أبدًا. تأتي أربعة خوادم رسمية (sequential-thinking وfetch وgit وmemory) مسجَّلة مسبقًا، كإدخالات عادية يمكنك إيقافها أو تعديلها أو إزالتها؛ يعمل fetch وgit عبر uvx، لذا يجب تثبيت uv. في محادثات المؤسسة (العامة ومحادثات كل مشروع) تتقدّم خوادم المؤسسة على خوادمك التي تحمل الاسم نفسه، حتى لو أوقفت المؤسسة أحدها."$json$::jsonb),
  ('fr', 'docs.mcp.usage', $json$"Ouvrez Paramètres › MCP (ou Ctrl+K › Paramètres › MCP) et ajoutez un serveur par le formulaire ou collez une configuration (JSON mcpServers, une ligne claude mcp add ou une commande npx). Dans un chat, tapez /mcp suivi d’une configuration ou d’une description : un agent prépare le brouillon et rien n’est enregistré avant votre vérification. Les serveurs de vos organisations apparaissent sous les vôtres et ne s’y modifient pas. Activez ensuite Approuver les serveurs MCP dans l’onglet de chaque agent qui doit les utiliser (désactivé au départ) ; Ctrl+K › Approuver les serveurs MCP fait de même pour un agent. Les organisations peuvent le bloquer par agent, et le mode planification ne transporte jamais les serveurs. Quatre serveurs officiels (sequential-thinking, fetch, git et memory) sont déjà enregistrés, comme des entrées ordinaires que vous pouvez désactiver, modifier ou supprimer ; fetch et git passent par uvx, donc uv doit être installé. Dans les conversations d’une organisation (la générale et celles de chaque projet), ses serveurs l’emportent sur les vôtres de même nom, même lorsque l’organisation en désactive un."$json$::jsonb),
  ('ru', 'docs.mcp.usage', $json$"Откройте «Настройки › MCP» (или Ctrl+K › Настройки › MCP) и добавьте сервер через форму либо вставьте конфигурацию (JSON mcpServers, строку claude mcp add или команду npx). В чате введите /mcp, а затем конфигурацию или описание: агент подготовит черновик, и ничего не сохранится, пока вы его не проверите. Серверы ваших организаций показаны под вашими и там не редактируются. Затем включите «Одобрять серверы MCP» на вкладке каждого агента, который должен их использовать (по умолчанию выключено); Ctrl+K › Одобрять серверы MCP делает то же для одного агента. Организации могут блокировать это по агентам, а режим планирования никогда не берёт серверы. Четыре официальных сервера (sequential-thinking, fetch, git и memory) уже зарегистрированы как обычные записи: их можно выключить, изменить или удалить; fetch и git запускаются через uvx, поэтому должен быть установлен uv. В чатах организации (общем и в чатах каждого проекта) её серверы имеют приоритет над вашими с тем же именем, даже если организация выключила сервер."$json$::jsonb),
  ('ja', 'docs.mcp.usage', $json$"設定 › MCP（または Ctrl+K › 設定 › MCP）を開き、フォームでサーバーを追加するか、設定（mcpServers の JSON、claude mcp add の行、npx コマンド）を貼り付けます。チャットでは /mcp に続けて設定または説明を入力します。エージェントが下書きを作り、確認するまで何も保存されません。所属組織のサーバーは自分のものの下に表示され、そこでは編集できません。そのあと、使わせたい各エージェントの設定タブで「MCP サーバーを承認」をオンにします（初期値はオフ）。Ctrl+K › MCP サーバーを承認 で1つのエージェントに対して同じことができます。組織はエージェントごとにブロックでき、計画モードではサーバーは渡されません。 公式サーバー 4 つ（sequential-thinking、fetch、git、memory）が最初から登録されています。通常のエントリなので、オフにしたり編集したり削除したりできます。fetch と git は uvx で動くため、uv のインストールが必要です。組織のチャット（全体用と各プロジェクト用）では、同じ名前なら組織のサーバーがあなたのものより優先されます。組織がそのサーバーをオフにしている場合も同じです。"$json$::jsonb),
  ('de', 'docs.mcp.usage', $json$"Öffnen Sie Einstellungen › MCP (oder Strg+K › Einstellungen › MCP) und fügen Sie einen Server über das Formular hinzu oder fügen Sie eine Konfiguration ein (mcpServers-JSON, eine claude-mcp-add-Zeile oder einen npx-Befehl). Geben Sie im Chat /mcp gefolgt von einer Konfiguration oder Beschreibung ein: Ein Agent erstellt den Entwurf, und nichts wird gespeichert, bevor Sie ihn geprüft haben. Die Server Ihrer Organisationen stehen unter Ihren eigenen und lassen sich dort nicht bearbeiten. Schalten Sie danach „MCP-Server freigeben“ im Einstellungs-Tab jedes Agenten ein, der sie nutzen soll (standardmäßig aus); Strg+K › MCP-Server freigeben macht dasselbe für einen Agenten. Organisationen können es je Agent sperren, und der Planungsmodus trägt die Server nie. Vier offizielle Server (sequential-thinking, fetch, git und memory) sind bereits eingetragen, als normale Einträge, die Sie ausschalten, bearbeiten oder entfernen können; fetch und git laufen über uvx, daher muss uv installiert sein. In den Chats einer Organisation (dem allgemeinen und denen jedes Projekts) haben deren Server Vorrang vor Ihren gleichnamigen, auch wenn die Organisation einen ausschaltet."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.mcpDefaults.title', $json$"Servidores MCP prontos para usar"$json$::jsonb),
  ('en', 'whatsNew.item.mcpDefaults.title', $json$"MCP servers ready to use"$json$::jsonb),
  ('es', 'whatsNew.item.mcpDefaults.title', $json$"Servidores MCP listos para usar"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.mcpDefaults.title', $json$"开箱即用的 MCP 服务器"$json$::jsonb),
  ('hi', 'whatsNew.item.mcpDefaults.title', $json$"इस्तेमाल के लिए तैयार MCP सर्वर"$json$::jsonb),
  ('ar', 'whatsNew.item.mcpDefaults.title', $json$"خوادم MCP جاهزة للاستخدام"$json$::jsonb),
  ('fr', 'whatsNew.item.mcpDefaults.title', $json$"Serveurs MCP prêts à l’emploi"$json$::jsonb),
  ('ru', 'whatsNew.item.mcpDefaults.title', $json$"Серверы MCP готовы к работе"$json$::jsonb),
  ('ja', 'whatsNew.item.mcpDefaults.title', $json$"すぐ使える MCP サーバー"$json$::jsonb),
  ('de', 'whatsNew.item.mcpDefaults.title', $json$"MCP-Server sofort einsatzbereit"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git e memory já vêm cadastrados em Configurações › MCP (e em cada organização, no site), como entradas comuns que você pode desligar, editar ou remover; o que for removido não volta. Nos chats de uma organização (o geral e os de cada projeto), os servidores dela valem por cima dos seus com o mesmo nome, mesmo quando a organização desliga um. fetch e git rodam pelo uvx (os servidores oficiais são em Python, não npm), então o uv precisa estar instalado; os servidores só chegam a um agente com “Aprovar servidores MCP” ligado na aba dele."$json$::jsonb),
  ('en', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git and memory now come registered in Settings › MCP (and in every organization on the site), as regular entries you can turn off, edit or remove; a removed one does not come back. In an organization’s chats (the general one and each project’s) the organization’s servers win over yours with the same name, even when the organization turns one off. fetch and git run through uvx (the official servers are Python, not npm), so uv must be installed; the servers only reach an agent with “Approve MCP servers” on in its tab."$json$::jsonb),
  ('es', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git y memory ya vienen registrados en Configuración › MCP (y en cada organización, en el sitio), como entradas normales que puedes desactivar, editar o eliminar; las eliminadas no vuelven. En los chats de una organización (el general y los de cada proyecto), sus servidores tienen prioridad sobre los tuyos con el mismo nombre, incluso cuando la organización desactiva uno. fetch y git se ejecutan con uvx (los servidores oficiales son de Python, no de npm), así que uv debe estar instalado; los servidores solo llegan a un agente con «Aprobar servidores MCP» activado en su pestaña."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking、fetch、git 和 memory 现已预先注册在“设置 › MCP”（以及网站上的每个组织）中，是可以关闭、编辑或删除的普通条目；删除后不会再回来。在组织的聊天（通用聊天和各项目的聊天）中，组织的服务器优先于你的同名服务器，即使组织将其关闭也一样。fetch 和 git 通过 uvx 运行（官方服务器是 Python 的，不在 npm 上），因此需要安装 uv；只有在代理标签页中开启“批准 MCP 服务器”后，服务器才会送达该代理。"$json$::jsonb),
  ('hi', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git और memory अब सेटिंग › MCP में (और साइट पर हर संगठन में) पहले से रजिस्टर आते हैं, सामान्य प्रविष्टियों के रूप में जिन्हें आप बंद, संपादित या हटा सकते हैं; हटाया गया वापस नहीं आता। किसी संगठन की चैट में (सामान्य चैट और हर प्रोजेक्ट की चैट) संगठन के सर्वर आपके उसी नाम वाले सर्वर पर भारी पड़ते हैं, भले ही संगठन उसे बंद कर दे। fetch और git uvx से चलते हैं (आधिकारिक सर्वर Python के हैं, npm के नहीं), इसलिए uv इंस्टॉल होना चाहिए; सर्वर किसी एजेंट तक तभी पहुँचते हैं जब उसके टैब में “MCP सर्वर स्वीकृत करें” चालू हो।"$json$::jsonb),
  ('ar', 'whatsNew.item.mcpDefaults.detail', $json$"أصبحت sequential thinking وfetch وgit وmemory مسجَّلة مسبقًا في الإعدادات › MCP (وفي كل مؤسسة على الموقع)، كإدخالات عادية يمكنك إيقافها أو تعديلها أو إزالتها؛ وما تُزيله لا يعود. في محادثات المؤسسة (العامة ومحادثات كل مشروع) تتقدّم خوادم المؤسسة على خوادمك التي تحمل الاسم نفسه، حتى لو أوقفت المؤسسة أحدها. يعمل fetch وgit عبر uvx (الخوادم الرسمية مكتوبة بـ Python وليست على npm)، لذا يجب تثبيت uv؛ ولا تصل الخوادم إلى وكيل إلا إذا كان «الموافقة على خوادم MCP» مفعّلًا في تبويبه."$json$::jsonb),
  ('fr', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git et memory sont désormais enregistrés dans Paramètres › MCP (et dans chaque organisation sur le site), comme des entrées ordinaires que vous pouvez désactiver, modifier ou supprimer ; une entrée supprimée ne revient pas. Dans les conversations d’une organisation (la générale et celles de chaque projet), ses serveurs l’emportent sur les vôtres de même nom, même lorsque l’organisation en désactive un. fetch et git passent par uvx (les serveurs officiels sont en Python, pas sur npm), donc uv doit être installé ; les serveurs ne parviennent à un agent que si « Approuver les serveurs MCP » est activé dans son onglet."$json$::jsonb),
  ('ru', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git и memory теперь уже зарегистрированы в «Настройки › MCP» (и в каждой организации на сайте) как обычные записи: их можно выключить, изменить или удалить, и удалённые не возвращаются. В чатах организации (общем и в чатах каждого проекта) её серверы имеют приоритет над вашими с тем же именем, даже если организация выключила сервер. fetch и git запускаются через uvx (официальные серверы написаны на Python и есть не в npm), поэтому должен быть установлен uv; серверы доходят до агента, только если на его вкладке включено «Одобрять серверы MCP»."$json$::jsonb),
  ('ja', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking、fetch、git、memory が「設定 › MCP」（およびサイトの各組織）に最初から登録されるようになりました。通常のエントリなので、オフ・編集・削除ができ、削除したものは戻りません。組織のチャット（全体用と各プロジェクト用）では、同じ名前なら組織のサーバーがあなたのものより優先されます。組織がそのサーバーをオフにしている場合も同じです。fetch と git は uvx で動くため（公式サーバーは npm ではなく Python 製です）、uv のインストールが必要です。サーバーは、エージェントのタブで「MCP サーバーを承認」がオンのときだけ届きます。"$json$::jsonb),
  ('de', 'whatsNew.item.mcpDefaults.detail', $json$"Sequential thinking, fetch, git und memory sind jetzt in Einstellungen › MCP (und in jeder Organisation auf der Website) bereits eingetragen, als normale Einträge, die Sie ausschalten, bearbeiten oder entfernen können; Entferntes kommt nicht zurück. In den Chats einer Organisation (dem allgemeinen und denen jedes Projekts) haben deren Server Vorrang vor Ihren gleichnamigen, auch wenn die Organisation einen ausschaltet. fetch und git laufen über uvx (die offiziellen Server sind in Python, nicht auf npm), daher muss uv installiert sein; die Server erreichen einen Agenten nur, wenn „MCP-Server freigeben“ in seinem Tab eingeschaltet ist."$json$::jsonb),
  ('pt-BR', 'orgExtensions.off', $json$"desligado pela organização"$json$::jsonb),
  ('en', 'orgExtensions.off', $json$"off by the organization"$json$::jsonb),
  ('es', 'orgExtensions.off', $json$"desactivado por la organización"$json$::jsonb),
  ('zh-CN', 'orgExtensions.off', $json$"已被组织关闭"$json$::jsonb),
  ('hi', 'orgExtensions.off', $json$"संगठन द्वारा बंद"$json$::jsonb),
  ('ar', 'orgExtensions.off', $json$"أوقفته المؤسسة"$json$::jsonb),
  ('fr', 'orgExtensions.off', $json$"désactivé par l’organisation"$json$::jsonb),
  ('ru', 'orgExtensions.off', $json$"выключен организацией"$json$::jsonb),
  ('ja', 'orgExtensions.off', $json$"組織がオフにしています"$json$::jsonb),
  ('de', 'orgExtensions.off', $json$"von der Organisation ausgeschaltet"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
