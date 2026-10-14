-- v0.101.0: a organização também escolhe quais permissões do chat já vêm
-- sempre ligadas nos projetos dela (além de bloquear, da v0.100.0). Cada uma
-- das três (rodar comandos, Git, rede) fica em um de três estados: livre (a
-- pessoa liga), sempre ligada ou bloqueada. A bloqueada vence a ligada quando
-- duas organizações do projeto discordam. O projeto recebe `enabled_grants` e
-- `grant_defaults` (quem liga cada uma) em `my_project_policies`.

alter table public.organization_chat_permissions
  add column enabled text[] not null default '{}' check (enabled <@ array['shell', 'git', 'network']::text[]),
  add constraint organization_chat_permissions_disjoint check (not (enabled && blocked));

-- Troca a RPC de dois parâmetros pela de três: o site antigo, que manda só
-- `blocked`, continua valendo (`enabled` assume lista vazia).
drop function public.set_chat_permissions(uuid, jsonb);
create function public.set_chat_permissions(org uuid, blocked jsonb, enabled jsonb default '[]'::jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  off text[];
  on_ text[];
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if jsonb_typeof(blocked) is distinct from 'array' or jsonb_typeof(enabled) is distinct from 'array' then raise exception 'policy.invalid'; end if;
  off := public.policy_list(blocked);
  on_ := public.policy_list(enabled);
  if not (off <@ array['shell', 'git', 'network']::text[]) or not (on_ <@ array['shell', 'git', 'network']::text[]) or off && on_ then
    raise exception 'policy.invalid';
  end if;
  delete from public.organization_chat_permissions c where c.org_id = org;
  if cardinality(off) = 0 and cardinality(on_) = 0 then return; end if;
  insert into public.organization_chat_permissions (org_id, blocked, enabled, updated_by) values (org, off, on_, auth.uid());
end;
$$;

-- Quem liga cada permissão: `{"git": ["acme"]}`. Interna: não confere papel.
create function public.grant_defaults_of(org uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(kind, jsonb_build_array(o.slug)), '{}'::jsonb)
  from public.organizations o
  join public.organization_chat_permissions c on c.org_id = o.id
  cross join lateral unnest(c.enabled) as kind
  where o.id = org;
$$;

-- A mesma `my_project_policies` da v0.100.0, com `enabled_grants` e
-- `grant_defaults`. Projeto que só tem permissão ligada também aparece.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy,
           public.command_sources_of(pr.org_id, null, true) as sources,
           public.grant_sources_of(pr.org_id) as grants,
           public.grant_defaults_of(pr.org_id) as defaults, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = pr.org_id::text
    union all
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), public.command_sources_of(r.org_id, r.id, false),
           public.grant_sources_of(r.org_id), public.grant_defaults_of(r.org_id), false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = r.org_id::text
  ), merged as (
    select l.project_id,
           (array_agg(l.org_id order by l.own desc, o.slug))[1] as org_id,
           string_agg(distinct o.slug, ', ') as org_slug,
           public.policy_merge_all(l.policy order by l.own desc, o.slug) as policy,
           public.command_sources_merge_all(l.sources order by l.own desc, o.slug) as sources,
           public.command_sources_merge_all(l.grants order by l.own desc, o.slug) as grants,
           public.command_sources_merge_all(l.defaults order by l.own desc, o.slug) as defaults
    from linked l
    join public.organizations o on o.id = l.org_id
    group by l.project_id
  )
  select m.project_id, m.org_id, m.org_slug,
         coalesce(m.policy, '{}'::jsonb)
         || case
           when m.sources = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_commands', (select jsonb_agg(k order by k) from jsonb_object_keys(m.sources) k),
             'command_sources', m.sources)
         end
         || case
           when m.grants = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_grants', (select jsonb_agg(k order by k) from jsonb_object_keys(m.grants) k),
             'grant_sources', m.grants)
         end
         || case
           when m.defaults = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'enabled_grants', (select jsonb_agg(k order by k) from jsonb_object_keys(m.defaults) k),
             'grant_defaults', m.defaults)
         end
  from merged m
  where m.policy is not null or m.sources <> '{}'::jsonb or m.grants <> '{}'::jsonb or m.defaults <> '{}'::jsonb;
$$;

revoke execute on function public.grant_defaults_of(uuid) from public, anon, authenticated;
revoke execute on function public.set_chat_permissions(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.set_chat_permissions(uuid, jsonb, jsonb) to authenticated;

-- Os textos da v0.101.0 (app e site), nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.chatperm.description', $json$"Para cada permissão do chat, escolha se as pessoas a ligam quando quiserem, se ela já vem sempre ligada ou se fica bloqueada nos projetos desta organização. A bloqueada aparece desativada no app como \"Bloqueado por <organização>\", e a sempre ligada como \"Sempre ligada por <organização>\". Comandos específicos se bloqueiam logo abaixo."$json$::jsonb),
  ('en', 'site.chatperm.description', $json$"For each chat permission, choose whether people switch it on when they want, whether it always comes switched on, or whether it is blocked in this organization's projects. A blocked one shows disabled in the app as \"Blocked by <organization>\", and an always-on one as \"Always on by <organization>\". Specific commands are blocked right below."$json$::jsonb),
  ('es', 'site.chatperm.description', $json$"Para cada permiso del chat, elige si las personas lo activan cuando quieran, si viene siempre activado o si está bloqueado en los proyectos de esta organización. El bloqueado aparece deshabilitado en la app como \"Bloqueado por <organización>\" y el siempre activado como \"Siempre activado por <organización>\". Los comandos concretos se bloquean justo debajo."$json$::jsonb),
  ('zh-CN', 'site.chatperm.description', $json$"为每项聊天权限选择：由成员按需开启、始终开启，还是在本组织项目中阻止。被阻止的在应用中显示为禁用并标注“被 <组织> 阻止”，始终开启的标注“由 <组织> 始终开启”。具体命令在下方阻止。"$json$::jsonb),
  ('hi', 'site.chatperm.description', $json$"हर चैट अनुमति के लिए चुनें कि लोग उसे जब चाहें चालू करें, वह हमेशा चालू रहे, या इस संगठन के प्रोजेक्ट में अवरुद्ध हो। अवरुद्ध अनुमति ऐप में \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है और हमेशा चालू वाली \"<संगठन> द्वारा हमेशा चालू\" के साथ। विशिष्ट कमांड ठीक नीचे अवरुद्ध किए जाते हैं।"$json$::jsonb),
  ('ar', 'site.chatperm.description', $json$"لكل إذن دردشة اختر: هل يشغّله الأشخاص متى شاؤوا، أم يأتي مفعّلًا دائمًا، أم يُحظر في مشاريع هذه المؤسسة. يظهر المحظور في التطبيق معطّلًا مع \"محظور بواسطة <المؤسسة>\" والمفعّل دائمًا مع \"مفعّل دائمًا بواسطة <المؤسسة>\". تُحظر الأوامر المحددة أسفل ذلك مباشرة."$json$::jsonb),
  ('fr', 'site.chatperm.description', $json$"Pour chaque autorisation du chat, choisissez si les personnes l'activent quand elles veulent, si elle est toujours activée ou si elle est bloquée dans les projets de cette organisation. Une autorisation bloquée apparaît grisée dans l'app avec « Bloqué par <organisation> », et celle toujours activée avec « Toujours activée par <organisation> ». Les commandes précises se bloquent juste en dessous."$json$::jsonb),
  ('ru', 'site.chatperm.description', $json$"Для каждого разрешения чата выберите: включают ли его люди по желанию, оно всегда включено или заблокировано в проектах этой организации. Заблокированное отображается в приложении неактивным с пометкой «Заблокировано: <организация>», а всегда включённое — «Всегда включено: <организация>». Отдельные команды блокируются ниже."$json$::jsonb),
  ('ja', 'site.chatperm.description', $json$"チャットの権限ごとに、メンバーが必要なときに有効にする、常に有効にする、この組織のプロジェクトでブロックする、のどれかを選びます。ブロックしたものはアプリで「<組織> がブロック中」と表示されて無効になり、常に有効なものは「<組織> が常にオン」と表示されます。個別のコマンドはすぐ下でブロックします。"$json$::jsonb),
  ('de', 'site.chatperm.description', $json$"Wählen Sie für jede Chat-Berechtigung, ob Personen sie bei Bedarf einschalten, ob sie immer eingeschaltet ist oder ob sie in den Projekten dieser Organisation blockiert wird. Eine blockierte erscheint in der App deaktiviert als „Blockiert von <Organisation>“, eine immer eingeschaltete als „Immer an durch <Organisation>“. Bestimmte Befehle werden direkt darunter blockiert."$json$::jsonb),
  ('pt-BR', 'site.chatperm.state.free', $json$"Livre: a pessoa liga"$json$::jsonb),
  ('en', 'site.chatperm.state.free', $json$"Free: people switch it on"$json$::jsonb),
  ('es', 'site.chatperm.state.free', $json$"Libre: la persona la activa"$json$::jsonb),
  ('zh-CN', 'site.chatperm.state.free', $json$"自由：由成员开启"$json$::jsonb),
  ('hi', 'site.chatperm.state.free', $json$"मुक्त: व्यक्ति चालू करता है"$json$::jsonb),
  ('ar', 'site.chatperm.state.free', $json$"حرّ: يشغّله الشخص"$json$::jsonb),
  ('fr', 'site.chatperm.state.free', $json$"Libre : la personne l'active"$json$::jsonb),
  ('ru', 'site.chatperm.state.free', $json$"Свободно: включает человек"$json$::jsonb),
  ('ja', 'site.chatperm.state.free', $json$"自由：メンバーが有効化"$json$::jsonb),
  ('de', 'site.chatperm.state.free', $json$"Frei: Person schaltet ein"$json$::jsonb),
  ('pt-BR', 'site.chatperm.state.on', $json$"Sempre ligada"$json$::jsonb),
  ('en', 'site.chatperm.state.on', $json$"Always on"$json$::jsonb),
  ('es', 'site.chatperm.state.on', $json$"Siempre activada"$json$::jsonb),
  ('zh-CN', 'site.chatperm.state.on', $json$"始终开启"$json$::jsonb),
  ('hi', 'site.chatperm.state.on', $json$"हमेशा चालू"$json$::jsonb),
  ('ar', 'site.chatperm.state.on', $json$"مفعّل دائمًا"$json$::jsonb),
  ('fr', 'site.chatperm.state.on', $json$"Toujours activée"$json$::jsonb),
  ('ru', 'site.chatperm.state.on', $json$"Всегда включено"$json$::jsonb),
  ('ja', 'site.chatperm.state.on', $json$"常にオン"$json$::jsonb),
  ('de', 'site.chatperm.state.on', $json$"Immer an"$json$::jsonb),
  ('pt-BR', 'site.chatperm.state.blocked', $json$"Bloqueada"$json$::jsonb),
  ('en', 'site.chatperm.state.blocked', $json$"Blocked"$json$::jsonb),
  ('es', 'site.chatperm.state.blocked', $json$"Bloqueada"$json$::jsonb),
  ('zh-CN', 'site.chatperm.state.blocked', $json$"阻止"$json$::jsonb),
  ('hi', 'site.chatperm.state.blocked', $json$"अवरुद्ध"$json$::jsonb),
  ('ar', 'site.chatperm.state.blocked', $json$"محظور"$json$::jsonb),
  ('fr', 'site.chatperm.state.blocked', $json$"Bloquée"$json$::jsonb),
  ('ru', 'site.chatperm.state.blocked', $json$"Заблокировано"$json$::jsonb),
  ('ja', 'site.chatperm.state.blocked', $json$"ブロック"$json$::jsonb),
  ('de', 'site.chatperm.state.blocked', $json$"Blockiert"$json$::jsonb),
  ('pt-BR', 'grants.enabledBy', $json$"Sempre ligada por {orgs}"$json$::jsonb),
  ('en', 'grants.enabledBy', $json$"Always on by {orgs}"$json$::jsonb),
  ('es', 'grants.enabledBy', $json$"Siempre activada por {orgs}"$json$::jsonb),
  ('zh-CN', 'grants.enabledBy', $json$"由 {orgs} 始终开启"$json$::jsonb),
  ('hi', 'grants.enabledBy', $json$"{orgs} द्वारा हमेशा चालू"$json$::jsonb),
  ('ar', 'grants.enabledBy', $json$"مفعّل دائمًا بواسطة {orgs}"$json$::jsonb),
  ('fr', 'grants.enabledBy', $json$"Toujours activée par {orgs}"$json$::jsonb),
  ('ru', 'grants.enabledBy', $json$"Всегда включено: {orgs}"$json$::jsonb),
  ('ja', 'grants.enabledBy', $json$"{orgs} が常にオン"$json$::jsonb),
  ('de', 'grants.enabledBy', $json$"Immer an durch {orgs}"$json$::jsonb),
  ('pt-BR', 'docs.chatPermissions.summary', $json$"Donos e mantenedores escolhem no site do JayV, para cada permissão do chat (rodar comandos, escrever no Git, usar a rede), se ela é livre, sempre ligada ou bloqueada nos projetos da organização. A sempre ligada vem ligada em todo chat e a bloqueada aparece desativada em Permissões do chat como \"Bloqueado por <organização>\"; o agente nunca recebe a bloqueada."$json$::jsonb),
  ('en', 'docs.chatPermissions.summary', $json$"Owners and maintainers choose on the JayV site, for each chat permission (run commands, write to Git, use the network), whether it is free, always on or blocked in the organization's projects. An always-on one comes switched on in every chat and a blocked one shows disabled in the chat's Permissions as \"Blocked by <organization>\"; the agent is never given a blocked one."$json$::jsonb),
  ('es', 'docs.chatPermissions.summary', $json$"Los propietarios y mantenedores eligen en el sitio de JayV, para cada permiso del chat (ejecutar comandos, escribir en Git, usar la red), si es libre, siempre activado o bloqueado en los proyectos de la organización. El siempre activado viene activado en todo chat y el bloqueado aparece desactivado en Permisos del chat como \"Bloqueado por <organización>\"; el agente nunca recibe el bloqueado."$json$::jsonb),
  ('zh-CN', 'docs.chatPermissions.summary', $json$"所有者和维护者在 JayV 网站上为每项聊天权限（运行命令、写入 Git、使用网络）选择在组织项目中是自由、始终开启还是阻止。始终开启的在每个聊天中都已开启，被阻止的在聊天的“权限”中显示为禁用并标注“被 <组织> 阻止”；智能体永远得不到被阻止的权限。"$json$::jsonb),
  ('hi', 'docs.chatPermissions.summary', $json$"स्वामी और मेंटेनर JayV साइट पर हर चैट अनुमति (कमांड चलाना, Git में लिखना, नेटवर्क का उपयोग) के लिए चुनते हैं कि वह संगठन के प्रोजेक्ट में मुक्त, हमेशा चालू या अवरुद्ध हो। हमेशा चालू अनुमति हर चैट में चालू मिलती है और अवरुद्ध अनुमति चैट की अनुमतियों में \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है; एजेंट को अवरुद्ध अनुमति कभी नहीं मिलती।"$json$::jsonb),
  ('ar', 'docs.chatPermissions.summary', $json$"يختار المالكون والمشرفون في موقع JayV لكل إذن دردشة (تشغيل الأوامر، الكتابة في Git، استخدام الشبكة) إن كان حرًّا أو مفعّلًا دائمًا أو محظورًا في مشاريع المؤسسة. يأتي المفعّل دائمًا مشغّلًا في كل دردشة، ويظهر المحظور معطّلًا في أذونات الدردشة مع \"محظور بواسطة <المؤسسة>\"؛ ولا يحصل الوكيل على المحظور أبدًا."$json$::jsonb),
  ('fr', 'docs.chatPermissions.summary', $json$"Les propriétaires et mainteneurs choisissent sur le site JayV, pour chaque autorisation du chat (exécuter des commandes, écrire dans Git, utiliser le réseau), si elle est libre, toujours activée ou bloquée dans les projets de l'organisation. Celle toujours activée est active dans tout chat et celle bloquée apparaît grisée dans les Autorisations du chat avec « Bloqué par <organisation> » ; l'agent ne reçoit jamais une autorisation bloquée."$json$::jsonb),
  ('ru', 'docs.chatPermissions.summary', $json$"Владельцы и мейнтейнеры выбирают на сайте JayV для каждого разрешения чата (запуск команд, запись в Git, использование сети), будет ли оно свободным, всегда включённым или заблокированным в проектах организации. Всегда включённое включено в каждом чате, а заблокированное отображается в разрешениях чата неактивным с пометкой «Заблокировано: <организация>»; агент заблокированное никогда не получает."$json$::jsonb),
  ('ja', 'docs.chatPermissions.summary', $json$"オーナーとメンテナーは JayV のサイトで、チャットの権限（コマンドの実行、Git への書き込み、ネットワークの利用）ごとに、組織のプロジェクトで自由、常にオン、ブロックのどれにするかを選びます。常にオンの権限はすべてのチャットで有効になり、ブロックした権限はチャットの権限で「<組織> がブロック中」と表示されて無効になります。ブロックした権限はエージェントに決して渡されません。"$json$::jsonb),
  ('de', 'docs.chatPermissions.summary', $json$"Eigentümer und Maintainer wählen auf der JayV-Website für jede Chat-Berechtigung (Befehle ausführen, in Git schreiben, Netzwerk nutzen), ob sie in den Projekten der Organisation frei, immer an oder blockiert ist. Eine immer eingeschaltete ist in jedem Chat an, eine blockierte erscheint in den Chat-Berechtigungen deaktiviert als „Blockiert von <Organisation>“; der Agent erhält eine blockierte nie."$json$::jsonb),
  ('pt-BR', 'docs.chatPermissions.usage', $json$"No site, abra a organização, aba Permissões, e use o quadro Permissões do chat: para rodar comandos, escrever no Git e usar a rede escolha Livre (a pessoa liga quando quiser), Sempre ligada ou Bloqueada, e salve. Logo abaixo ficam os comandos específicos bloqueados, na mesma tela. No app, em Permissões ao lado do modo de trabalho (ou Ctrl+K › Permissões de comandos), a sempre ligada aparece ligada e travada com \"Sempre ligada por <organização>\" e vale para todas as mensagens do chat; a bloqueada fica desativada com \"Bloqueado por <organização>\". Bloquear rodar comandos tira também os comandos liberados um a um; bloquear o Git tira todos os comandos git; bloquear a rede tira os que acessam a rede. Se o agente pedir um comando assim, o JayV não pergunta: o passo diz quem o bloqueia. Se duas organizações do projeto discordarem, a bloqueada vence. Vale para a organização inteira e chega ao app na próxima sincronização. Pela paleta (Ctrl+K), \"<organização>: permissões do chat (site)\" abre a aba."$json$::jsonb),
  ('en', 'docs.chatPermissions.usage', $json$"On the site, open the organization, Permissions tab, and use the Chat permissions box: for run commands, write to Git and use the network pick Free (people switch it on when they want), Always on or Blocked, and save. Right below are the blocked specific commands, on the same screen. In the app, under Permissions beside the work mode (or Ctrl+K › Command permissions), an always-on permission shows switched on and locked as \"Always on by <organization>\" and applies to every message of the chat; a blocked one shows disabled as \"Blocked by <organization>\". Blocking run commands also removes the commands granted one by one; blocking Git removes every git command; blocking the network removes the ones that reach the network. If an agent asks for such a command, JayV does not ask you: the step says who blocks it. If two organizations of the project disagree, the blocked one wins. It applies to the whole organization and reaches the app at the next sync. In the palette (Ctrl+K), \"<organization>: chat permissions (site)\" opens the tab."$json$::jsonb),
  ('es', 'docs.chatPermissions.usage', $json$"En el sitio, abre la organización, pestaña Permisos, y usa el cuadro Permisos del chat: para ejecutar comandos, escribir en Git y usar la red elige Libre (la persona lo activa cuando quiera), Siempre activado o Bloqueado, y guarda. Justo debajo están los comandos concretos bloqueados, en la misma pantalla. En la app, en Permisos junto al modo de trabajo (o Ctrl+K › Permisos de comandos), el siempre activado aparece activado y bloqueado con \"Siempre activado por <organización>\" y vale para todos los mensajes del chat; el bloqueado queda desactivado con \"Bloqueado por <organización>\". Bloquear la ejecución de comandos quita también los comandos concedidos uno a uno; bloquear Git quita todos los comandos git; bloquear la red quita los que acceden a la red. Si el agente pide un comando así, JayV no pregunta: el paso dice quién lo bloquea. Si dos organizaciones del proyecto discrepan, gana el bloqueado. Vale para toda la organización y llega a la app en la siguiente sincronización. En la paleta (Ctrl+K), \"<organización>: permisos del chat (sitio)\" abre la pestaña."$json$::jsonb),
  ('zh-CN', 'docs.chatPermissions.usage', $json$"在网站上打开组织的“权限”标签页，使用“聊天权限”区块：对运行命令、写入 Git、使用网络分别选择“自由”（成员按需开启）、“始终开启”或“阻止”，然后保存。具体被阻止的命令就在下方，同一屏幕。在应用中，工作模式旁的“权限”（或 Ctrl+K › 命令权限）里，始终开启的权限显示为已开启且锁定，标注“由 <组织> 始终开启”，对该聊天的所有消息生效；被阻止的显示为禁用并标注“被 <组织> 阻止”。阻止运行命令也会移除逐条授予的命令；阻止 Git 会移除所有 git 命令；阻止网络会移除访问网络的命令。如果智能体请求这样的命令，JayV 不会询问：该步骤会说明是谁阻止的。项目的两个组织意见不一致时，以阻止为准。它对整个组织生效，并在下次同步时到达应用。在命令面板（Ctrl+K）中，“<组织>：聊天权限（网站）”会打开该标签页。"$json$::jsonb),
  ('hi', 'docs.chatPermissions.usage', $json$"साइट पर संगठन खोलें, अनुमतियाँ टैब में, और चैट अनुमतियाँ बॉक्स का उपयोग करें: कमांड चलाना, Git में लिखना और नेटवर्क के लिए मुक्त (व्यक्ति जब चाहे चालू करे), हमेशा चालू या अवरुद्ध चुनें और सहेजें। विशिष्ट अवरुद्ध कमांड ठीक नीचे उसी स्क्रीन पर हैं। ऐप में कार्य मोड के पास अनुमतियाँ (या Ctrl+K › कमांड अनुमतियाँ) में हमेशा चालू अनुमति \"<संगठन> द्वारा हमेशा चालू\" के साथ चालू और लॉक दिखती है और चैट के हर संदेश पर लागू होती है; अवरुद्ध अनुमति \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है। कमांड चलाना अवरुद्ध करने पर एक-एक करके दिए गए कमांड भी हट जाते हैं; Git अवरुद्ध करने पर सभी git कमांड हट जाते हैं; नेटवर्क अवरुद्ध करने पर नेटवर्क वाले कमांड हट जाते हैं। यदि एजेंट ऐसा कमांड माँगे तो JayV नहीं पूछता: चरण बताता है कि उसे किसने अवरुद्ध किया। प्रोजेक्ट के दो संगठन असहमत हों तो अवरुद्ध जीतता है। यह पूरे संगठन पर लागू होता है और अगले सिंक पर ऐप तक पहुँचता है। पैलेट (Ctrl+K) में \"<संगठन>: चैट अनुमतियाँ (साइट)\" यह टैब खोलता है।"$json$::jsonb),
  ('ar', 'docs.chatPermissions.usage', $json$"في الموقع افتح المؤسسة، تبويب الأذونات، واستخدم مربع أذونات الدردشة: لتشغيل الأوامر والكتابة في Git واستخدام الشبكة اختر حرّ (يشغّله الشخص متى شاء) أو مفعّل دائمًا أو محظور ثم احفظ. تجد الأوامر المحددة المحظورة أسفل ذلك مباشرة في الشاشة نفسها. في التطبيق، ضمن الأذونات بجانب وضع العمل (أو Ctrl+K › أذونات الأوامر)، يظهر المفعّل دائمًا مشغّلًا ومقفلًا مع \"مفعّل دائمًا بواسطة <المؤسسة>\" ويسري على كل رسائل الدردشة؛ ويظهر المحظور معطّلًا مع \"محظور بواسطة <المؤسسة>\". حظر تشغيل الأوامر يزيل أيضًا الأوامر الممنوحة واحدًا تلو الآخر؛ وحظر Git يزيل كل أوامر git؛ وحظر الشبكة يزيل الأوامر التي تصل إلى الشبكة. إذا طلب الوكيل أمرًا كهذا فلن يسألك JayV: تذكر الخطوة من يحظره. إذا اختلفت مؤسستان في المشروع فالمحظور هو الأقوى. يسري على المؤسسة كلها ويصل إلى التطبيق عند المزامنة التالية. في اللوحة (Ctrl+K) يفتح \"<المؤسسة>: أذونات الدردشة (الموقع)\" التبويب."$json$::jsonb),
  ('fr', 'docs.chatPermissions.usage', $json$"Sur le site, ouvrez l'organisation, onglet Autorisations, et utilisez le cadre Autorisations du chat : pour exécuter des commandes, écrire dans Git et utiliser le réseau, choisissez Libre (la personne l'active quand elle veut), Toujours activée ou Bloquée, puis enregistrez. Juste en dessous se trouvent les commandes précises bloquées, sur le même écran. Dans l'app, sous Autorisations à côté du mode de travail (ou Ctrl+K › Autorisations de commandes), une autorisation toujours activée apparaît activée et verrouillée avec « Toujours activée par <organisation> » et vaut pour tous les messages du chat ; une autorisation bloquée apparaît grisée avec « Bloqué par <organisation> ». Bloquer l'exécution de commandes retire aussi les commandes accordées une par une ; bloquer Git retire toutes les commandes git ; bloquer le réseau retire celles qui accèdent au réseau. Si l'agent demande une telle commande, JayV ne demande rien : l'étape dit qui la bloque. Si deux organisations du projet ne sont pas d'accord, la bloquée l'emporte. Cela vaut pour toute l'organisation et arrive dans l'app à la prochaine synchronisation. Dans la palette (Ctrl+K), « <organisation> : autorisations du chat (site) » ouvre l'onglet."$json$::jsonb),
  ('ru', 'docs.chatPermissions.usage', $json$"На сайте откройте организацию, вкладку «Разрешения», и используйте блок «Разрешения чата»: для запуска команд, записи в Git и использования сети выберите «Свободно» (человек включает по желанию), «Всегда включено» или «Заблокировано» и сохраните. Отдельные заблокированные команды находятся ниже, на том же экране. В приложении, в «Разрешениях» рядом с режимом работы (или Ctrl+K › Разрешения для команд), всегда включённое разрешение отображается включённым и заблокированным для изменения с пометкой «Всегда включено: <организация>» и действует для всех сообщений чата; заблокированное отображается неактивным с пометкой «Заблокировано: <организация>». Блокировка запуска команд убирает и команды, выданные по одной; блокировка Git убирает все команды git; блокировка сети убирает команды, обращающиеся к сети. Если агент просит такую команду, JayV не спрашивает: шаг говорит, кто её блокирует. Если две организации проекта расходятся, побеждает блокировка. Действует для всей организации и приходит в приложение при следующей синхронизации. В палитре (Ctrl+K) «<организация>: разрешения чата (сайт)» открывает вкладку."$json$::jsonb),
  ('ja', 'docs.chatPermissions.usage', $json$"サイトで組織の「権限」タブを開き、「チャットの権限」ボックスを使います。コマンドの実行、Git への書き込み、ネットワークの利用のそれぞれについて、自由（メンバーが必要なときに有効化）、常にオン、ブロックのどれかを選んで保存します。個別にブロックするコマンドはすぐ下の同じ画面にあります。アプリでは、作業モードの横の「権限」（または Ctrl+K ›コマンドの権限）で、常にオンの権限は「<組織> が常にオン」と表示されてオンのまま固定され、そのチャットのすべてのメッセージに適用されます。ブロックした権限は「<組織> がブロック中」と表示されて無効になります。コマンドの実行をブロックすると、個別に許可したコマンドも外れます。Git をブロックするとすべての git コマンドが、ネットワークをブロックするとネットワークに接続するコマンドが外れます。エージェントがそうしたコマンドを求めても JayV は確認せず、ステップに誰がブロックしているかが表示されます。プロジェクトの二つの組織で意見が分かれたときは、ブロックが優先されます。組織全体に適用され、次の同期でアプリに届きます。パレット（Ctrl+K）の「<組織>：チャットの権限（サイト）」でタブを開けます。"$json$::jsonb),
  ('de', 'docs.chatPermissions.usage', $json$"Öffnen Sie auf der Website die Organisation, Tab Berechtigungen, und nutzen Sie das Feld Chat-Berechtigungen: Wählen Sie für Befehle ausführen, in Git schreiben und Netzwerk nutzen Frei (Person schaltet bei Bedarf ein), Immer an oder Blockiert und speichern Sie. Direkt darunter stehen auf demselben Bildschirm die bestimmten blockierten Befehle. In der App erscheint unter Berechtigungen neben dem Arbeitsmodus (oder Ctrl+K › Befehlsberechtigungen) eine immer eingeschaltete Berechtigung eingeschaltet und gesperrt als „Immer an durch <Organisation>“ und gilt für alle Nachrichten des Chats; eine blockierte erscheint deaktiviert als „Blockiert von <Organisation>“. Das Blockieren von Befehlsausführung entfernt auch einzeln erlaubte Befehle; das Blockieren von Git entfernt alle Git-Befehle; das Blockieren des Netzwerks entfernt Befehle mit Netzwerkzugriff. Fragt der Agent nach so einem Befehl, fragt JayV nicht nach: Der Schritt nennt, wer ihn blockiert. Sind sich zwei Organisationen des Projekts uneinig, gewinnt die Blockierung. Es gilt für die ganze Organisation und erreicht die App bei der nächsten Synchronisierung. In der Palette (Ctrl+K) öffnet „<Organisation>: Chat-Berechtigungen (Website)“ den Tab."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.chatPermissionsOn.title', $json$"Permissões do chat sempre ligadas pela organização"$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissionsOn.title', $json$"Chat permissions the organization keeps always on"$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissionsOn.title', $json$"Permisos del chat siempre activados por la organización"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissionsOn.title', $json$"组织始终开启的聊天权限"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissionsOn.title', $json$"संगठन द्वारा हमेशा चालू चैट अनुमतियाँ"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissionsOn.title', $json$"أذونات دردشة تُبقيها المؤسسة مفعّلة دائمًا"$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissionsOn.title', $json$"Autorisations du chat toujours activées par l'organisation"$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissionsOn.title', $json$"Разрешения чата, всегда включённые организацией"$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissionsOn.title', $json$"組織が常にオンにするチャット権限"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissionsOn.title', $json$"Chat-Berechtigungen, die die Organisation immer eingeschaltet lässt"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.chatPermissionsOn.detail', $json$"Na aba Permissões do site, cada permissão do chat (rodar comandos, Git, rede) agora pode ficar Livre, Sempre ligada ou Bloqueada, e o quadro fica na mesma tela dos comandos bloqueados. No app, a sempre ligada já vem ligada e travada em todo chat do projeto da organização; a bloqueada continua desativada."$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissionsOn.detail', $json$"In the site's Permissions tab, each chat permission (run commands, Git, network) can now be Free, Always on or Blocked, and the box sits on the same screen as the blocked commands. In the app, an always-on one comes switched on and locked in every chat of the organization's project; a blocked one stays disabled."$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissionsOn.detail', $json$"En la pestaña Permisos del sitio, cada permiso del chat (ejecutar comandos, Git, red) ahora puede ser Libre, Siempre activado o Bloqueado, y el cuadro está en la misma pantalla que los comandos bloqueados. En la app, el siempre activado viene activado y bloqueado en todo chat del proyecto de la organización; el bloqueado sigue desactivado."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissionsOn.detail', $json$"在网站的“权限”标签页中，每项聊天权限（运行命令、Git、网络）现在可设为“自由”“始终开启”或“阻止”，该区块与被阻止的命令在同一屏幕。在应用中，始终开启的权限在组织项目的每个聊天里都已开启并锁定；被阻止的仍为禁用。"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissionsOn.detail', $json$"साइट के अनुमतियाँ टैब में हर चैट अनुमति (कमांड चलाना, Git, नेटवर्क) अब मुक्त, हमेशा चालू या अवरुद्ध हो सकती है, और यह बॉक्स अवरुद्ध कमांड वाली स्क्रीन पर ही है। ऐप में हमेशा चालू अनुमति संगठन के प्रोजेक्ट के हर चैट में चालू और लॉक मिलती है; अवरुद्ध अनुमति निष्क्रिय ही रहती है।"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissionsOn.detail', $json$"في تبويب الأذونات بالموقع صار بإمكان كل إذن دردشة (تشغيل الأوامر، Git، الشبكة) أن يكون حرًّا أو مفعّلًا دائمًا أو محظورًا، والمربع في الشاشة نفسها مع الأوامر المحظورة. في التطبيق يأتي المفعّل دائمًا مشغّلًا ومقفلًا في كل دردشة بمشروع المؤسسة، ويبقى المحظور معطّلًا."$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissionsOn.detail', $json$"Dans l'onglet Autorisations du site, chaque autorisation du chat (exécuter des commandes, Git, réseau) peut maintenant être Libre, Toujours activée ou Bloquée, et le cadre est sur le même écran que les commandes bloquées. Dans l'app, une autorisation toujours activée est activée et verrouillée dans tout chat du projet de l'organisation ; une bloquée reste désactivée."$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissionsOn.detail', $json$"На вкладке «Разрешения» сайта каждое разрешение чата (запуск команд, Git, сеть) теперь может быть «Свободно», «Всегда включено» или «Заблокировано», а блок находится на одном экране с заблокированными командами. В приложении всегда включённое разрешение включено и заблокировано для изменения в каждом чате проекта организации; заблокированное остаётся неактивным."$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissionsOn.detail', $json$"サイトの「権限」タブで、チャットの各権限（コマンドの実行、Git、ネットワーク）を自由、常にオン、ブロックから選べるようになり、ブロックしたコマンドと同じ画面に表示されます。アプリでは、常にオンの権限が組織のプロジェクトのすべてのチャットでオンのまま固定され、ブロックした権限は無効のままです。"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissionsOn.detail', $json$"Im Tab Berechtigungen der Website kann jede Chat-Berechtigung (Befehle ausführen, Git, Netzwerk) jetzt Frei, Immer an oder Blockiert sein, und das Feld steht auf demselben Bildschirm wie die blockierten Befehle. In der App ist eine immer eingeschaltete Berechtigung in jedem Chat des Organisationsprojekts eingeschaltet und gesperrt; eine blockierte bleibt deaktiviert."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
