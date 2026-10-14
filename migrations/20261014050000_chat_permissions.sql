-- v0.100.0: permissões do chat da organização. O dono ou mantenedor escolhe
-- no site quais permissões do seletor do chat (rodar comandos, Git, rede) as
-- pessoas podem ligar nos projetos da organização. A desligada aparece
-- desativada no app com "Bloqueado por <organização>", e o app nunca a passa
-- ao agente: a política chega por `my_project_policies` (chaves
-- `blocked_grants` e `grant_sources`), junto das regras de comandos.
--
-- Valem para a organização inteira (sem escopo por repositório) e o projeto
-- roda sob a união das de todas as organizações dele. Leitura por RLS
-- (membro lê); escrita só pela RPC, que confere o papel.

create table public.organization_chat_permissions (
  org_id uuid primary key references public.organizations on delete cascade,
  blocked text[] not null default '{}' check (blocked <@ array['shell', 'git', 'network']::text[]),
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.organization_chat_permissions enable row level security;
create policy "membro lê" on public.organization_chat_permissions for select to authenticated
  using ((select public.org_role(org_id)) is not null);

-- Grava as permissões do chat bloqueadas da organização, trocando as que
-- houver. Lista vazia apaga a linha.
create function public.set_chat_permissions(org uuid, blocked jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  listed text[];
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if jsonb_typeof(blocked) is distinct from 'array' then raise exception 'policy.invalid'; end if;
  listed := public.policy_list(blocked);
  if not (listed <@ array['shell', 'git', 'network']::text[]) then raise exception 'policy.invalid'; end if;
  delete from public.organization_chat_permissions c where c.org_id = org;
  if cardinality(listed) = 0 then return; end if;
  insert into public.organization_chat_permissions (org_id, blocked, updated_by) values (org, listed, auth.uid());
end;
$$;

-- Quem bloqueia o quê: `{"git": ["acme"]}`. Interna: não confere papel.
create function public.grant_sources_of(org uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(kind, jsonb_build_array(o.slug)), '{}'::jsonb)
  from public.organizations o
  join public.organization_chat_permissions c on c.org_id = o.id
  cross join lateral unnest(c.blocked) as kind
  where o.id = org;
$$;

-- A mesma `my_project_policies` da v0.87.0, com `blocked_grants` e
-- `grant_sources` na política do projeto. Projeto que só tem permissão de chat
-- bloqueada (sem política de LLM nem regra de comando) também aparece.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy,
           public.command_sources_of(pr.org_id, null, true) as sources,
           public.grant_sources_of(pr.org_id) as grants, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and pr.environment_id = pr.org_id::text
    union all
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), public.command_sources_of(r.org_id, r.id, false),
           public.grant_sources_of(r.org_id), false
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
           public.command_sources_merge_all(l.grants order by l.own desc, o.slug) as grants
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
  from merged m
  where m.policy is not null or m.sources <> '{}'::jsonb or m.grants <> '{}'::jsonb;
$$;

revoke execute on function public.grant_sources_of(uuid) from public, anon, authenticated;
revoke execute on function public.set_chat_permissions(uuid, jsonb) from public, anon;
grant execute on function public.set_chat_permissions(uuid, jsonb) to authenticated;

-- Os textos da v0.100.0 (app e site), nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.org.tab.chat', $json$"Chat"$json$::jsonb),
  ('en', 'site.org.tab.chat', $json$"Chat"$json$::jsonb),
  ('es', 'site.org.tab.chat', $json$"Chat"$json$::jsonb),
  ('zh-CN', 'site.org.tab.chat', $json$"聊天"$json$::jsonb),
  ('hi', 'site.org.tab.chat', $json$"चैट"$json$::jsonb),
  ('ar', 'site.org.tab.chat', $json$"الدردشة"$json$::jsonb),
  ('fr', 'site.org.tab.chat', $json$"Chat"$json$::jsonb),
  ('ru', 'site.org.tab.chat', $json$"Чат"$json$::jsonb),
  ('ja', 'site.org.tab.chat', $json$"チャット"$json$::jsonb),
  ('de', 'site.org.tab.chat', $json$"Chat"$json$::jsonb),
  ('pt-BR', 'site.chatperm.title', $json$"Permissões do chat"$json$::jsonb),
  ('en', 'site.chatperm.title', $json$"Chat permissions"$json$::jsonb),
  ('es', 'site.chatperm.title', $json$"Permisos del chat"$json$::jsonb),
  ('zh-CN', 'site.chatperm.title', $json$"聊天权限"$json$::jsonb),
  ('hi', 'site.chatperm.title', $json$"चैट अनुमतियाँ"$json$::jsonb),
  ('ar', 'site.chatperm.title', $json$"أذونات الدردشة"$json$::jsonb),
  ('fr', 'site.chatperm.title', $json$"Autorisations du chat"$json$::jsonb),
  ('ru', 'site.chatperm.title', $json$"Разрешения чата"$json$::jsonb),
  ('ja', 'site.chatperm.title', $json$"チャットの権限"$json$::jsonb),
  ('de', 'site.chatperm.title', $json$"Chat-Berechtigungen"$json$::jsonb),
  ('pt-BR', 'site.chatperm.description', $json$"Escolha quais permissões do chat as pessoas podem ligar nos projetos desta organização. A permissão desligada aparece desativada no app como \"Bloqueado por <organização>\" e o agente nunca a recebe. Comandos específicos se bloqueiam na aba Permissões."$json$::jsonb),
  ('en', 'site.chatperm.description', $json$"Choose which chat permissions people may switch on in this organization's projects. A switched-off permission shows as disabled in the app as \"Blocked by <organization>\" and the agent is never given it. Specific commands are blocked in the Permissions tab."$json$::jsonb),
  ('es', 'site.chatperm.description', $json$"Elige qué permisos del chat pueden activar las personas en los proyectos de esta organización. El permiso desactivado aparece deshabilitado en la app como \"Bloqueado por <organización>\" y el agente nunca lo recibe. Los comandos concretos se bloquean en la pestaña Permisos."$json$::jsonb),
  ('zh-CN', 'site.chatperm.description', $json$"选择成员可以在本组织项目的聊天中开启哪些权限。关闭的权限在应用中显示为禁用，并标注“被 <组织> 阻止”，智能体永远得不到它。具体命令请在“权限”标签页中阻止。"$json$::jsonb),
  ('hi', 'site.chatperm.description', $json$"चुनें कि इस संगठन के प्रोजेक्ट के चैट में लोग कौन-सी अनुमतियाँ चालू कर सकते हैं। बंद की गई अनुमति ऐप में \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है और एजेंट को कभी नहीं मिलती। विशिष्ट कमांड \"अनुमतियाँ\" टैब में अवरुद्ध किए जाते हैं।"$json$::jsonb),
  ('ar', 'site.chatperm.description', $json$"اختر أذونات الدردشة التي يمكن للأشخاص تشغيلها في مشاريع هذه المؤسسة. يظهر الإذن المُعطَّل في التطبيق معطّلًا مع عبارة \"محظور بواسطة <المؤسسة>\" ولا يحصل عليه الوكيل أبدًا. تُحظر الأوامر المحددة في تبويب الأذونات."$json$::jsonb),
  ('fr', 'site.chatperm.description', $json$"Choisissez les autorisations du chat que les personnes peuvent activer dans les projets de cette organisation. Une autorisation désactivée apparaît grisée dans l'app avec « Bloqué par <organisation> » et l'agent ne la reçoit jamais. Les commandes précises se bloquent dans l'onglet Autorisations."$json$::jsonb),
  ('ru', 'site.chatperm.description', $json$"Выберите, какие разрешения чата можно включать в проектах этой организации. Отключённое разрешение отображается в приложении неактивным с пометкой «Заблокировано: <организация>», и агент его никогда не получает. Отдельные команды блокируются на вкладке «Разрешения»."$json$::jsonb),
  ('ja', 'site.chatperm.description', $json$"この組織のプロジェクトのチャットで、メンバーが有効にできる権限を選びます。オフにした権限はアプリで「<組織> がブロック中」と表示されて無効になり、エージェントには決して渡されません。個別のコマンドは「権限」タブでブロックします。"$json$::jsonb),
  ('de', 'site.chatperm.description', $json$"Wählen Sie, welche Chat-Berechtigungen Personen in den Projekten dieser Organisation einschalten dürfen. Eine ausgeschaltete Berechtigung erscheint in der App deaktiviert als „Blockiert von <Organisation>“, und der Agent erhält sie nie. Bestimmte Befehle werden im Tab Berechtigungen blockiert."$json$::jsonb),
  ('pt-BR', 'site.chatperm.on', $json$"Permitida"$json$::jsonb),
  ('en', 'site.chatperm.on', $json$"Allowed"$json$::jsonb),
  ('es', 'site.chatperm.on', $json$"Permitida"$json$::jsonb),
  ('zh-CN', 'site.chatperm.on', $json$"允许"$json$::jsonb),
  ('hi', 'site.chatperm.on', $json$"अनुमत"$json$::jsonb),
  ('ar', 'site.chatperm.on', $json$"مسموح"$json$::jsonb),
  ('fr', 'site.chatperm.on', $json$"Autorisée"$json$::jsonb),
  ('ru', 'site.chatperm.on', $json$"Разрешено"$json$::jsonb),
  ('ja', 'site.chatperm.on', $json$"許可"$json$::jsonb),
  ('de', 'site.chatperm.on', $json$"Erlaubt"$json$::jsonb),
  ('pt-BR', 'site.chatperm.off', $json$"Bloqueada"$json$::jsonb),
  ('en', 'site.chatperm.off', $json$"Blocked"$json$::jsonb),
  ('es', 'site.chatperm.off', $json$"Bloqueada"$json$::jsonb),
  ('zh-CN', 'site.chatperm.off', $json$"已阻止"$json$::jsonb),
  ('hi', 'site.chatperm.off', $json$"अवरुद्ध"$json$::jsonb),
  ('ar', 'site.chatperm.off', $json$"محظور"$json$::jsonb),
  ('fr', 'site.chatperm.off', $json$"Bloquée"$json$::jsonb),
  ('ru', 'site.chatperm.off', $json$"Заблокировано"$json$::jsonb),
  ('ja', 'site.chatperm.off', $json$"ブロック中"$json$::jsonb),
  ('de', 'site.chatperm.off', $json$"Blockiert"$json$::jsonb),
  ('pt-BR', 'site.chatperm.shell', $json$"Rodar comandos"$json$::jsonb),
  ('en', 'site.chatperm.shell', $json$"Run commands"$json$::jsonb),
  ('es', 'site.chatperm.shell', $json$"Ejecutar comandos"$json$::jsonb),
  ('zh-CN', 'site.chatperm.shell', $json$"运行命令"$json$::jsonb),
  ('hi', 'site.chatperm.shell', $json$"कमांड चलाना"$json$::jsonb),
  ('ar', 'site.chatperm.shell', $json$"تشغيل الأوامر"$json$::jsonb),
  ('fr', 'site.chatperm.shell', $json$"Exécuter des commandes"$json$::jsonb),
  ('ru', 'site.chatperm.shell', $json$"Запускать команды"$json$::jsonb),
  ('ja', 'site.chatperm.shell', $json$"コマンドの実行"$json$::jsonb),
  ('de', 'site.chatperm.shell', $json$"Befehle ausführen"$json$::jsonb),
  ('pt-BR', 'site.chatperm.shell.hint', $json$"Testes, builds e scripts sem perguntar. Bloqueada, nenhum comando é liberado ao agente, nem um a um."$json$::jsonb),
  ('en', 'site.chatperm.shell.hint', $json$"Tests, builds and scripts without asking. When blocked, no command is granted to the agent, not even one by one."$json$::jsonb),
  ('es', 'site.chatperm.shell.hint', $json$"Pruebas, builds y scripts sin preguntar. Si se bloquea, no se concede ningún comando al agente, ni uno a uno."$json$::jsonb),
  ('zh-CN', 'site.chatperm.shell.hint', $json$"无需询问即可运行测试、构建和脚本。被阻止后，不会向智能体授予任何命令，逐条授予也不行。"$json$::jsonb),
  ('hi', 'site.chatperm.shell.hint', $json$"बिना पूछे टेस्ट, बिल्ड और स्क्रिप्ट। अवरुद्ध होने पर एजेंट को कोई कमांड नहीं मिलता, एक-एक करके भी नहीं।"$json$::jsonb),
  ('ar', 'site.chatperm.shell.hint', $json$"الاختبارات وعمليات البناء والسكربتات دون سؤال. عند الحظر لا يُمنح الوكيل أي أمر، ولا حتى واحدًا تلو الآخر."$json$::jsonb),
  ('fr', 'site.chatperm.shell.hint', $json$"Tests, builds et scripts sans demander. Bloquée, aucune commande n'est accordée à l'agent, pas même une par une."$json$::jsonb),
  ('ru', 'site.chatperm.shell.hint', $json$"Тесты, сборки и скрипты без вопросов. При блокировке агенту не выдаётся ни одна команда, даже по одной."$json$::jsonb),
  ('ja', 'site.chatperm.shell.hint', $json$"テスト、ビルド、スクリプトを確認なしで実行します。ブロックすると、個別にもコマンドはエージェントに許可されません。"$json$::jsonb),
  ('de', 'site.chatperm.shell.hint', $json$"Tests, Builds und Skripte ohne Nachfrage. Bei Blockierung wird dem Agenten kein Befehl erlaubt, auch nicht einzeln."$json$::jsonb),
  ('pt-BR', 'site.chatperm.git', $json$"Escrever no Git"$json$::jsonb),
  ('en', 'site.chatperm.git', $json$"Write to Git"$json$::jsonb),
  ('es', 'site.chatperm.git', $json$"Escribir en Git"$json$::jsonb),
  ('zh-CN', 'site.chatperm.git', $json$"写入 Git"$json$::jsonb),
  ('hi', 'site.chatperm.git', $json$"Git में लिखना"$json$::jsonb),
  ('ar', 'site.chatperm.git', $json$"الكتابة في Git"$json$::jsonb),
  ('fr', 'site.chatperm.git', $json$"Écrire dans Git"$json$::jsonb),
  ('ru', 'site.chatperm.git', $json$"Писать в Git"$json$::jsonb),
  ('ja', 'site.chatperm.git', $json$"Git への書き込み"$json$::jsonb),
  ('de', 'site.chatperm.git', $json$"In Git schreiben"$json$::jsonb),
  ('pt-BR', 'site.chatperm.git.hint', $json$"git add, commit e outros comandos que mudam o .git. Bloqueada, nenhum comando git é liberado ao agente."$json$::jsonb),
  ('en', 'site.chatperm.git.hint', $json$"git add, commit and other commands that change .git. When blocked, no git command is granted to the agent."$json$::jsonb),
  ('es', 'site.chatperm.git.hint', $json$"git add, commit y otros comandos que modifican .git. Si se bloquea, no se concede ningún comando git al agente."$json$::jsonb),
  ('zh-CN', 'site.chatperm.git.hint', $json$"git add、commit 以及其他修改 .git 的命令。被阻止后，不会向智能体授予任何 git 命令。"$json$::jsonb),
  ('hi', 'site.chatperm.git.hint', $json$"git add, commit और .git बदलने वाले अन्य कमांड। अवरुद्ध होने पर एजेंट को कोई git कमांड नहीं मिलता।"$json$::jsonb),
  ('ar', 'site.chatperm.git.hint', $json$"git add وcommit وغيرها من الأوامر التي تغيّر .git. عند الحظر لا يُمنح الوكيل أي أمر git."$json$::jsonb),
  ('fr', 'site.chatperm.git.hint', $json$"git add, commit et les autres commandes qui modifient .git. Bloquée, aucune commande git n'est accordée à l'agent."$json$::jsonb),
  ('ru', 'site.chatperm.git.hint', $json$"git add, commit и другие команды, меняющие .git. При блокировке агенту не выдаётся ни одна команда git."$json$::jsonb),
  ('ja', 'site.chatperm.git.hint', $json$"git add、commit など .git を変更するコマンド。ブロックすると、git コマンドはエージェントに許可されません。"$json$::jsonb),
  ('de', 'site.chatperm.git.hint', $json$"git add, commit und weitere Befehle, die .git ändern. Bei Blockierung wird dem Agenten kein Git-Befehl erlaubt."$json$::jsonb),
  ('pt-BR', 'site.chatperm.network', $json$"Usar a rede"$json$::jsonb),
  ('en', 'site.chatperm.network', $json$"Use the network"$json$::jsonb),
  ('es', 'site.chatperm.network', $json$"Usar la red"$json$::jsonb),
  ('zh-CN', 'site.chatperm.network', $json$"使用网络"$json$::jsonb),
  ('hi', 'site.chatperm.network', $json$"नेटवर्क का उपयोग"$json$::jsonb),
  ('ar', 'site.chatperm.network', $json$"استخدام الشبكة"$json$::jsonb),
  ('fr', 'site.chatperm.network', $json$"Utiliser le réseau"$json$::jsonb),
  ('ru', 'site.chatperm.network', $json$"Использовать сеть"$json$::jsonb),
  ('ja', 'site.chatperm.network', $json$"ネットワークの利用"$json$::jsonb),
  ('de', 'site.chatperm.network', $json$"Netzwerk nutzen"$json$::jsonb),
  ('pt-BR', 'site.chatperm.network.hint', $json$"Instalar pacotes e baixar arquivos. Bloqueada, os comandos que acessam a rede também não são liberados."$json$::jsonb),
  ('en', 'site.chatperm.network.hint', $json$"Install packages and download files. When blocked, commands that reach the network are not granted either."$json$::jsonb),
  ('es', 'site.chatperm.network.hint', $json$"Instalar paquetes y descargar archivos. Si se bloquea, tampoco se conceden los comandos que acceden a la red."$json$::jsonb),
  ('zh-CN', 'site.chatperm.network.hint', $json$"安装软件包和下载文件。被阻止后，访问网络的命令同样不会被授予。"$json$::jsonb),
  ('hi', 'site.chatperm.network.hint', $json$"पैकेज इंस्टॉल करना और फ़ाइलें डाउनलोड करना। अवरुद्ध होने पर नेटवर्क तक पहुँचने वाले कमांड भी नहीं मिलते।"$json$::jsonb),
  ('ar', 'site.chatperm.network.hint', $json$"تثبيت الحزم وتنزيل الملفات. عند الحظر لا تُمنح أيضًا الأوامر التي تصل إلى الشبكة."$json$::jsonb),
  ('fr', 'site.chatperm.network.hint', $json$"Installer des paquets et télécharger des fichiers. Bloquée, les commandes qui accèdent au réseau ne sont pas accordées non plus."$json$::jsonb),
  ('ru', 'site.chatperm.network.hint', $json$"Установка пакетов и загрузка файлов. При блокировке команды, обращающиеся к сети, тоже не выдаются."$json$::jsonb),
  ('ja', 'site.chatperm.network.hint', $json$"パッケージのインストールとファイルのダウンロード。ブロックすると、ネットワークに接続するコマンドも許可されません。"$json$::jsonb),
  ('de', 'site.chatperm.network.hint', $json$"Pakete installieren und Dateien herunterladen. Bei Blockierung werden auch Befehle mit Netzwerkzugriff nicht erlaubt."$json$::jsonb),
  ('pt-BR', 'site.chatperm.save', $json$"Salvar permissões do chat"$json$::jsonb),
  ('en', 'site.chatperm.save', $json$"Save chat permissions"$json$::jsonb),
  ('es', 'site.chatperm.save', $json$"Guardar permisos del chat"$json$::jsonb),
  ('zh-CN', 'site.chatperm.save', $json$"保存聊天权限"$json$::jsonb),
  ('hi', 'site.chatperm.save', $json$"चैट अनुमतियाँ सहेजें"$json$::jsonb),
  ('ar', 'site.chatperm.save', $json$"حفظ أذونات الدردشة"$json$::jsonb),
  ('fr', 'site.chatperm.save', $json$"Enregistrer les autorisations du chat"$json$::jsonb),
  ('ru', 'site.chatperm.save', $json$"Сохранить разрешения чата"$json$::jsonb),
  ('ja', 'site.chatperm.save', $json$"チャットの権限を保存"$json$::jsonb),
  ('de', 'site.chatperm.save', $json$"Chat-Berechtigungen speichern"$json$::jsonb),
  ('pt-BR', 'site.chatperm.saved', $json$"Permissões do chat salvas"$json$::jsonb),
  ('en', 'site.chatperm.saved', $json$"Chat permissions saved"$json$::jsonb),
  ('es', 'site.chatperm.saved', $json$"Permisos del chat guardados"$json$::jsonb),
  ('zh-CN', 'site.chatperm.saved', $json$"聊天权限已保存"$json$::jsonb),
  ('hi', 'site.chatperm.saved', $json$"चैट अनुमतियाँ सहेजी गईं"$json$::jsonb),
  ('ar', 'site.chatperm.saved', $json$"تم حفظ أذونات الدردشة"$json$::jsonb),
  ('fr', 'site.chatperm.saved', $json$"Autorisations du chat enregistrées"$json$::jsonb),
  ('ru', 'site.chatperm.saved', $json$"Разрешения чата сохранены"$json$::jsonb),
  ('ja', 'site.chatperm.saved', $json$"チャットの権限を保存しました"$json$::jsonb),
  ('de', 'site.chatperm.saved', $json$"Chat-Berechtigungen gespeichert"$json$::jsonb),
  ('pt-BR', 'site.chatperm.count', $json$"Bloqueadas: {count} de 3"$json$::jsonb),
  ('en', 'site.chatperm.count', $json$"Blocked: {count} of 3"$json$::jsonb),
  ('es', 'site.chatperm.count', $json$"Bloqueados: {count} de 3"$json$::jsonb),
  ('zh-CN', 'site.chatperm.count', $json$"已阻止：{count} / 3"$json$::jsonb),
  ('hi', 'site.chatperm.count', $json$"अवरुद्ध: 3 में से {count}"$json$::jsonb),
  ('ar', 'site.chatperm.count', $json$"محظور: {count} من 3"$json$::jsonb),
  ('fr', 'site.chatperm.count', $json$"Bloquées : {count} sur 3"$json$::jsonb),
  ('ru', 'site.chatperm.count', $json$"Заблокировано: {count} из 3"$json$::jsonb),
  ('ja', 'site.chatperm.count', $json$"ブロック中：3 件中 {count} 件"$json$::jsonb),
  ('de', 'site.chatperm.count', $json$"Blockiert: {count} von 3"$json$::jsonb),
  ('pt-BR', 'palette.orgSiteChat', $json$"{org}: permissões do chat (site)"$json$::jsonb),
  ('en', 'palette.orgSiteChat', $json$"{org}: chat permissions (site)"$json$::jsonb),
  ('es', 'palette.orgSiteChat', $json$"{org}: permisos del chat (sitio)"$json$::jsonb),
  ('zh-CN', 'palette.orgSiteChat', $json$"{org}：聊天权限（网站）"$json$::jsonb),
  ('hi', 'palette.orgSiteChat', $json$"{org}: चैट अनुमतियाँ (साइट)"$json$::jsonb),
  ('ar', 'palette.orgSiteChat', $json$"{org}: أذونات الدردشة (الموقع)"$json$::jsonb),
  ('fr', 'palette.orgSiteChat', $json$"{org} : autorisations du chat (site)"$json$::jsonb),
  ('ru', 'palette.orgSiteChat', $json$"{org}: разрешения чата (сайт)"$json$::jsonb),
  ('ja', 'palette.orgSiteChat', $json$"{org}：チャットの権限（サイト）"$json$::jsonb),
  ('de', 'palette.orgSiteChat', $json$"{org}: Chat-Berechtigungen (Website)"$json$::jsonb),
  ('pt-BR', 'docs.chatPermissions.title', $json$"Permissões do chat da organização"$json$::jsonb),
  ('en', 'docs.chatPermissions.title', $json$"Chat permissions of the organization"$json$::jsonb),
  ('es', 'docs.chatPermissions.title', $json$"Permisos del chat de la organización"$json$::jsonb),
  ('zh-CN', 'docs.chatPermissions.title', $json$"组织的聊天权限"$json$::jsonb),
  ('hi', 'docs.chatPermissions.title', $json$"संगठन की चैट अनुमतियाँ"$json$::jsonb),
  ('ar', 'docs.chatPermissions.title', $json$"أذونات الدردشة للمؤسسة"$json$::jsonb),
  ('fr', 'docs.chatPermissions.title', $json$"Autorisations du chat de l'organisation"$json$::jsonb),
  ('ru', 'docs.chatPermissions.title', $json$"Разрешения чата организации"$json$::jsonb),
  ('ja', 'docs.chatPermissions.title', $json$"組織のチャット権限"$json$::jsonb),
  ('de', 'docs.chatPermissions.title', $json$"Chat-Berechtigungen der Organisation"$json$::jsonb),
  ('pt-BR', 'docs.chatPermissions.summary', $json$"Donos e mantenedores escolhem no site do JayV quais permissões do chat (rodar comandos, escrever no Git, usar a rede) as pessoas podem ligar nos projetos da organização. A permissão bloqueada aparece desativada em Permissões do chat como \"Bloqueado por <organização>\" e o agente nunca a recebe."$json$::jsonb),
  ('en', 'docs.chatPermissions.summary', $json$"Owners and maintainers choose on the JayV site which chat permissions (run commands, write to Git, use the network) people may switch on in the organization's projects. A blocked permission shows disabled in the chat's Permissions as \"Blocked by <organization>\" and the agent is never given it."$json$::jsonb),
  ('es', 'docs.chatPermissions.summary', $json$"Los propietarios y mantenedores eligen en el sitio de JayV qué permisos del chat (ejecutar comandos, escribir en Git, usar la red) pueden activar las personas en los proyectos de la organización. El permiso bloqueado aparece desactivado en Permisos del chat como \"Bloqueado por <organización>\" y el agente nunca lo recibe."$json$::jsonb),
  ('zh-CN', 'docs.chatPermissions.summary', $json$"所有者和维护者在 JayV 网站上选择成员可在组织项目中开启哪些聊天权限（运行命令、写入 Git、使用网络）。被阻止的权限在聊天的“权限”中显示为禁用，并标注“被 <组织> 阻止”，智能体永远得不到它。"$json$::jsonb),
  ('hi', 'docs.chatPermissions.summary', $json$"स्वामी और मेंटेनर JayV साइट पर चुनते हैं कि संगठन के प्रोजेक्ट में लोग कौन-सी चैट अनुमतियाँ (कमांड चलाना, Git में लिखना, नेटवर्क का उपयोग) चालू कर सकते हैं। अवरुद्ध अनुमति चैट की अनुमतियों में \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है और एजेंट को कभी नहीं मिलती।"$json$::jsonb),
  ('ar', 'docs.chatPermissions.summary', $json$"يختار المالكون والمشرفون في موقع JayV أذونات الدردشة (تشغيل الأوامر، الكتابة في Git، استخدام الشبكة) التي يمكن للأشخاص تشغيلها في مشاريع المؤسسة. يظهر الإذن المحظور معطّلًا في أذونات الدردشة مع عبارة \"محظور بواسطة <المؤسسة>\" ولا يحصل عليه الوكيل أبدًا."$json$::jsonb),
  ('fr', 'docs.chatPermissions.summary', $json$"Les propriétaires et mainteneurs choisissent sur le site JayV quelles autorisations du chat (exécuter des commandes, écrire dans Git, utiliser le réseau) les personnes peuvent activer dans les projets de l'organisation. Une autorisation bloquée apparaît grisée dans les Autorisations du chat avec « Bloqué par <organisation> » et l'agent ne la reçoit jamais."$json$::jsonb),
  ('ru', 'docs.chatPermissions.summary', $json$"Владельцы и мейнтейнеры выбирают на сайте JayV, какие разрешения чата (запуск команд, запись в Git, использование сети) можно включать в проектах организации. Заблокированное разрешение отображается в разрешениях чата неактивным с пометкой «Заблокировано: <организация>», и агент его никогда не получает."$json$::jsonb),
  ('ja', 'docs.chatPermissions.summary', $json$"オーナーとメンテナーは JayV のサイトで、組織のプロジェクトでメンバーが有効にできるチャットの権限（コマンドの実行、Git への書き込み、ネットワークの利用）を選びます。ブロックした権限はチャットの権限で「<組織> がブロック中」と表示されて無効になり、エージェントには決して渡されません。"$json$::jsonb),
  ('de', 'docs.chatPermissions.summary', $json$"Eigentümer und Maintainer wählen auf der JayV-Website, welche Chat-Berechtigungen (Befehle ausführen, in Git schreiben, Netzwerk nutzen) Personen in den Projekten der Organisation einschalten dürfen. Eine blockierte Berechtigung erscheint in den Chat-Berechtigungen deaktiviert als „Blockiert von <Organisation>“, und der Agent erhält sie nie."$json$::jsonb),
  ('pt-BR', 'docs.chatPermissions.usage', $json$"No site, abra a organização e use a aba Chat: deixe ligada cada permissão que as pessoas podem usar e desligue as que não podem (rodar comandos, escrever no Git, usar a rede) e salve. No app, em Permissões ao lado do modo de trabalho (ou Ctrl+K › Permissões de comandos), a permissão bloqueada fica desativada com \"Bloqueado por <organização>\". Bloquear rodar comandos tira também os comandos liberados um a um; bloquear o Git tira todos os comandos git; bloquear a rede tira os comandos que acessam a rede. Se o agente pedir um comando assim, o JayV não pergunta: o passo diz quem o bloqueia. Vale para a organização inteira, se soma ao bloqueio de comandos da aba Permissões e chega ao app na próxima sincronização. Pela paleta (Ctrl+K), \"<organização>: permissões do chat (site)\" abre a aba."$json$::jsonb),
  ('en', 'docs.chatPermissions.usage', $json$"On the site, open the organization and use the Chat tab: leave on each permission people may use, switch off the ones they may not (run commands, write to Git, use the network) and save. In the app, under Permissions beside the work mode (or Ctrl+K › Command permissions), a blocked permission shows disabled as \"Blocked by <organization>\". Blocking run commands also removes the commands granted one by one; blocking Git removes every git command; blocking the network removes the commands that reach the network. If an agent asks for such a command, JayV does not ask you: the step says who blocks it. It applies to the whole organization, adds to the command blocks of the Permissions tab and reaches the app at the next sync. In the palette (Ctrl+K), \"<organization>: chat permissions (site)\" opens the tab."$json$::jsonb),
  ('es', 'docs.chatPermissions.usage', $json$"En el sitio, abre la organización y usa la pestaña Chat: deja activado cada permiso que las personas pueden usar, desactiva los que no (ejecutar comandos, escribir en Git, usar la red) y guarda. En la app, en Permisos junto al modo de trabajo (o Ctrl+K › Permisos de comandos), el permiso bloqueado aparece desactivado con \"Bloqueado por <organización>\". Bloquear la ejecución de comandos quita también los comandos concedidos uno a uno; bloquear Git quita todos los comandos git; bloquear la red quita los comandos que acceden a la red. Si el agente pide un comando así, JayV no pregunta: el paso dice quién lo bloquea. Vale para toda la organización, se suma al bloqueo de comandos de la pestaña Permisos y llega a la app en la siguiente sincronización. En la paleta (Ctrl+K), \"<organización>: permisos del chat (sitio)\" abre la pestaña."$json$::jsonb),
  ('zh-CN', 'docs.chatPermissions.usage', $json$"在网站上打开组织并使用“聊天”标签页：保持开启成员可以使用的权限，关闭不允许的权限（运行命令、写入 Git、使用网络），然后保存。在应用中，工作模式旁的“权限”（或 Ctrl+K › 命令权限）里，被阻止的权限会显示为禁用并标注“被 <组织> 阻止”。阻止运行命令也会移除逐条授予的命令；阻止 Git 会移除所有 git 命令；阻止网络会移除访问网络的命令。如果智能体请求这样的命令，JayV 不会询问：该步骤会说明是谁阻止的。它对整个组织生效，与“权限”标签页中的命令阻止叠加，并在下次同步时到达应用。在命令面板（Ctrl+K）中，“<组织>：聊天权限（网站）”会打开该标签页。"$json$::jsonb),
  ('hi', 'docs.chatPermissions.usage', $json$"साइट पर संगठन खोलें और चैट टैब का उपयोग करें: जो अनुमतियाँ लोग इस्तेमाल कर सकते हैं उन्हें चालू रखें, बाकी (कमांड चलाना, Git में लिखना, नेटवर्क का उपयोग) बंद करें और सहेजें। ऐप में, कार्य मोड के पास अनुमतियाँ (या Ctrl+K › कमांड अनुमतियाँ) में अवरुद्ध अनुमति \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है। कमांड चलाना अवरुद्ध करने पर एक-एक करके दिए गए कमांड भी हट जाते हैं; Git अवरुद्ध करने पर सभी git कमांड हट जाते हैं; नेटवर्क अवरुद्ध करने पर नेटवर्क तक पहुँचने वाले कमांड हट जाते हैं। यदि एजेंट ऐसा कमांड माँगे तो JayV नहीं पूछता: चरण बताता है कि उसे किसने अवरुद्ध किया। यह पूरे संगठन पर लागू होता है, अनुमतियाँ टैब के कमांड ब्लॉक में जुड़ता है और अगले सिंक पर ऐप तक पहुँचता है। पैलेट (Ctrl+K) में \"<संगठन>: चैट अनुमतियाँ (साइट)\" यह टैब खोलता है।"$json$::jsonb),
  ('ar', 'docs.chatPermissions.usage', $json$"في الموقع افتح المؤسسة واستخدم تبويب الدردشة: أبقِ مفعّلة كل إذن يمكن للأشخاص استخدامه وعطّل ما لا يجوز (تشغيل الأوامر، الكتابة في Git، استخدام الشبكة) ثم احفظ. في التطبيق، ضمن الأذونات بجانب وضع العمل (أو Ctrl+K › أذونات الأوامر)، يظهر الإذن المحظور معطّلًا مع عبارة \"محظور بواسطة <المؤسسة>\". حظر تشغيل الأوامر يزيل أيضًا الأوامر الممنوحة واحدًا تلو الآخر؛ وحظر Git يزيل كل أوامر git؛ وحظر الشبكة يزيل الأوامر التي تصل إلى الشبكة. إذا طلب الوكيل أمرًا كهذا فلن يسألك JayV: تذكر الخطوة من يحظره. يسري على المؤسسة كلها ويُضاف إلى حظر الأوامر في تبويب الأذونات ويصل إلى التطبيق عند المزامنة التالية. في اللوحة (Ctrl+K) يفتح \"<المؤسسة>: أذونات الدردشة (الموقع)\" التبويب."$json$::jsonb),
  ('fr', 'docs.chatPermissions.usage', $json$"Sur le site, ouvrez l'organisation et utilisez l'onglet Chat : laissez activée chaque autorisation que les personnes peuvent utiliser, désactivez les autres (exécuter des commandes, écrire dans Git, utiliser le réseau) et enregistrez. Dans l'app, sous Autorisations à côté du mode de travail (ou Ctrl+K › Autorisations de commandes), l'autorisation bloquée apparaît grisée avec « Bloqué par <organisation> ». Bloquer l'exécution de commandes retire aussi les commandes accordées une par une ; bloquer Git retire toutes les commandes git ; bloquer le réseau retire les commandes qui accèdent au réseau. Si l'agent demande une telle commande, JayV ne demande rien : l'étape dit qui la bloque. Cela vaut pour toute l'organisation, s'ajoute au blocage de commandes de l'onglet Autorisations et arrive dans l'app à la prochaine synchronisation. Dans la palette (Ctrl+K), « <organisation> : autorisations du chat (site) » ouvre l'onglet."$json$::jsonb),
  ('ru', 'docs.chatPermissions.usage', $json$"На сайте откройте организацию и перейдите на вкладку «Чат»: оставьте включёнными разрешения, которыми можно пользоваться, отключите остальные (запуск команд, запись в Git, использование сети) и сохраните. В приложении, в «Разрешениях» рядом с режимом работы (или Ctrl+K › Разрешения для команд), заблокированное разрешение отображается неактивным с пометкой «Заблокировано: <организация>». Блокировка запуска команд убирает и команды, выданные по одной; блокировка Git убирает все команды git; блокировка сети убирает команды, обращающиеся к сети. Если агент просит такую команду, JayV не спрашивает: шаг говорит, кто её блокирует. Действует для всей организации, дополняет блокировку команд на вкладке «Разрешения» и приходит в приложение при следующей синхронизации. В палитре (Ctrl+K) «<организация>: разрешения чата (сайт)» открывает вкладку."$json$::jsonb),
  ('ja', 'docs.chatPermissions.usage', $json$"サイトで組織を開き、「チャット」タブを使います。メンバーが使える権限はオンのままにし、使えないもの（コマンドの実行、Git への書き込み、ネットワークの利用）をオフにして保存します。アプリでは、作業モードの横の「権限」（または Ctrl+K ›コマンドの権限）で、ブロックされた権限が「<組織> がブロック中」と表示されて無効になります。コマンドの実行をブロックすると、個別に許可したコマンドも外れます。Git をブロックするとすべての git コマンドが、ネットワークをブロックするとネットワークに接続するコマンドが外れます。エージェントがそうしたコマンドを求めても JayV は確認せず、ステップに誰がブロックしているかが表示されます。組織全体に適用され、「権限」タブのコマンドのブロックに加わり、次の同期でアプリに届きます。パレット（Ctrl+K）の「<組織>：チャットの権限（サイト）」でタブを開けます。"$json$::jsonb),
  ('de', 'docs.chatPermissions.usage', $json$"Öffnen Sie auf der Website die Organisation und nutzen Sie den Tab Chat: Lassen Sie jede Berechtigung eingeschaltet, die Personen nutzen dürfen, schalten Sie die übrigen aus (Befehle ausführen, in Git schreiben, Netzwerk nutzen) und speichern Sie. In der App erscheint die blockierte Berechtigung unter Berechtigungen neben dem Arbeitsmodus (oder Ctrl+K › Befehlsberechtigungen) deaktiviert als „Blockiert von <Organisation>“. Das Blockieren von Befehlsausführung entfernt auch einzeln erlaubte Befehle; das Blockieren von Git entfernt alle Git-Befehle; das Blockieren des Netzwerks entfernt Befehle mit Netzwerkzugriff. Fragt der Agent nach so einem Befehl, fragt JayV nicht nach: Der Schritt nennt, wer ihn blockiert. Es gilt für die ganze Organisation, ergänzt die Befehlssperren im Tab Berechtigungen und erreicht die App bei der nächsten Synchronisierung. In der Palette (Ctrl+K) öffnet „<Organisation>: Chat-Berechtigungen (Website)“ den Tab."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.chatPermissions.title', $json$"Permissões do chat da organização"$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissions.title', $json$"Chat permissions of the organization"$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissions.title', $json$"Permisos del chat de la organización"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissions.title', $json$"组织的聊天权限"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissions.title', $json$"संगठन की चैट अनुमतियाँ"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissions.title', $json$"أذونات الدردشة للمؤسسة"$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissions.title', $json$"Autorisations du chat de l'organisation"$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissions.title', $json$"Разрешения чата организации"$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissions.title', $json$"組織のチャット権限"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissions.title', $json$"Chat-Berechtigungen der Organisation"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.chatPermissions.detail', $json$"Donos e mantenedores escolhem na nova aba Chat do site quais permissões do chat (rodar comandos, escrever no Git, usar a rede) as pessoas podem ligar nos projetos da organização. No app, a permissão bloqueada fica desativada em Permissões como \"Bloqueado por <organização>\" e o agente nunca a recebe."$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissions.detail', $json$"Owners and maintainers choose in the site's new Chat tab which chat permissions (run commands, write to Git, use the network) people may switch on in the organization's projects. In the app, a blocked permission shows disabled in Permissions as \"Blocked by <organization>\" and the agent is never given it."$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissions.detail', $json$"Los propietarios y mantenedores eligen en la nueva pestaña Chat del sitio qué permisos del chat (ejecutar comandos, escribir en Git, usar la red) pueden activar las personas en los proyectos de la organización. En la app, el permiso bloqueado aparece desactivado en Permisos como \"Bloqueado por <organización>\" y el agente nunca lo recibe."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissions.detail', $json$"所有者和维护者可在网站新的“聊天”标签页中选择成员能在组织项目里开启哪些聊天权限（运行命令、写入 Git、使用网络）。在应用中，被阻止的权限在“权限”里显示为禁用，并标注“被 <组织> 阻止”，智能体永远得不到它。"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissions.detail', $json$"स्वामी और मेंटेनर साइट के नए चैट टैब में चुनते हैं कि संगठन के प्रोजेक्ट में लोग कौन-सी चैट अनुमतियाँ (कमांड चलाना, Git में लिखना, नेटवर्क का उपयोग) चालू कर सकते हैं। ऐप में अवरुद्ध अनुमति अनुमतियों में \"<संगठन> द्वारा अवरुद्ध\" के साथ निष्क्रिय दिखती है और एजेंट को कभी नहीं मिलती।"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissions.detail', $json$"يختار المالكون والمشرفون في تبويب الدردشة الجديد بالموقع أذونات الدردشة (تشغيل الأوامر، الكتابة في Git، استخدام الشبكة) التي يمكن للأشخاص تشغيلها في مشاريع المؤسسة. في التطبيق يظهر الإذن المحظور معطّلًا ضمن الأذونات مع عبارة \"محظور بواسطة <المؤسسة>\" ولا يحصل عليه الوكيل أبدًا."$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissions.detail', $json$"Les propriétaires et mainteneurs choisissent dans le nouvel onglet Chat du site quelles autorisations du chat (exécuter des commandes, écrire dans Git, utiliser le réseau) les personnes peuvent activer dans les projets de l'organisation. Dans l'app, une autorisation bloquée apparaît grisée dans Autorisations avec « Bloqué par <organisation> » et l'agent ne la reçoit jamais."$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissions.detail', $json$"Владельцы и мейнтейнеры выбирают на новой вкладке «Чат» сайта, какие разрешения чата (запуск команд, запись в Git, использование сети) можно включать в проектах организации. В приложении заблокированное разрешение отображается в «Разрешениях» неактивным с пометкой «Заблокировано: <организация>», и агент его никогда не получает."$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissions.detail', $json$"オーナーとメンテナーは、サイトの新しい「チャット」タブで、組織のプロジェクトでメンバーが有効にできるチャットの権限（コマンドの実行、Git への書き込み、ネットワークの利用）を選びます。アプリではブロックした権限が「権限」で「<組織> がブロック中」と表示されて無効になり、エージェントには決して渡されません。"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissions.detail', $json$"Eigentümer und Maintainer wählen im neuen Tab Chat der Website, welche Chat-Berechtigungen (Befehle ausführen, in Git schreiben, Netzwerk nutzen) Personen in den Projekten der Organisation einschalten dürfen. In der App erscheint die blockierte Berechtigung unter Berechtigungen deaktiviert als „Blockiert von <Organisation>“, und der Agent erhält sie nie."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
