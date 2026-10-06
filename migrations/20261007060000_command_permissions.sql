-- v0.77.0: permissões de comandos da organização. O dono ou mantenedor
-- escolhe no site quais comandos os agentes nunca rodam nos projetos da
-- organização (`git push`, `npm publish`, `docker`…), para a organização
-- inteira e, mais apertado, para cada repositório. O projeto roda sob a
-- união das duas listas (e das de todas as organizações dele): a regra de um
-- repositório só bloqueia a mais, nunca libera o que a organização bloqueou.
--
-- Cada regra é o programa e até dois subcomandos (`git`, `git push`): bloquear
-- `git` bloqueia todos os subcomandos dele. O app recebe a lista junto da
-- política do projeto (`my_project_policies`, chave `blocked_commands`) e
-- quem bloqueia cada regra (`command_sources`).
--
-- Leitura por RLS (membro lê); escrita só pela RPC, que confere o papel.

-- Até 200 regras: programa e até dois subcomandos, só com os caracteres que
-- um comando de terminal usa.
create function public.command_rules_ok(rules text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(rules) <= 200
    and not exists (
      select 1 from unnest(rules) r
      where r is null or r !~ '^[A-Za-z0-9._+][A-Za-z0-9._+@/:-]{0,39}( [A-Za-z0-9._+][A-Za-z0-9._+@/:-]{0,39}){0,2}$'
    );
$$;

create table public.organization_command_rules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations on delete cascade,
  repository_id uuid references public.organization_repositories on delete cascade,
  blocked text[] not null default '{}' check (public.command_rules_ok(blocked)),
  updated_by uuid references auth.users on delete set null,
  updated_at timestamptz not null default now()
);
create unique index organization_command_rules_org on public.organization_command_rules (org_id) where repository_id is null;
create unique index organization_command_rules_repository on public.organization_command_rules (repository_id) where repository_id is not null;

alter table public.organization_command_rules enable row level security;
create policy "membro lê" on public.organization_command_rules for select to authenticated
  using ((select public.org_role(org_id)) is not null);

-- Grava as regras bloqueadas da organização (`repository` nulo) ou de um
-- repositório dela, trocando as que houver. Lista vazia apaga a linha.
create function public.set_command_rules(org uuid, repository uuid, rules jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  listed text[];
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if repository is not null and not exists (select 1 from public.organization_repositories where id = repository and org_id = org) then
    raise exception 'policy.repository';
  end if;
  if jsonb_typeof(rules) is distinct from 'array' then raise exception 'policy.invalid'; end if;
  listed := public.policy_list(rules);
  delete from public.organization_command_rules c where c.org_id = org and c.repository_id is not distinct from repository;
  if cardinality(listed) = 0 then return; end if;
  begin
    insert into public.organization_command_rules (org_id, repository_id, blocked, updated_by) values (org, repository, listed, auth.uid());
  exception
    when check_violation then raise exception 'policy.invalid';
  end;
end;
$$;

-- Quem bloqueia o quê: `{"git push": ["acme"]}`. Da organização e, quando
-- `repository` vem, também do repositório; sem `repository`, de todos os
-- repositórios dela (o chat geral da organização). Interna: não confere papel.
create function public.command_sources_of(org uuid, repository uuid, all_repositories boolean) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(rule, jsonb_build_array(o.slug)), '{}'::jsonb)
  from public.organizations o
  cross join lateral (
    select distinct unnest(c.blocked) as rule
    from public.organization_command_rules c
    where c.org_id = o.id and (c.repository_id is null or all_repositories or c.repository_id = repository)
  ) rules
  where o.id = org;
$$;

-- Junta duas tabelas de quem bloqueia: as regras pela união, e cada regra com
-- as organizações das duas.
create function public.command_sources_merge(a jsonb, b jsonb) returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, (
    select jsonb_agg(distinct s order by s)
    from (
      select jsonb_array_elements_text(coalesce(a->k, '[]'::jsonb)) as s
      union
      select jsonb_array_elements_text(coalesce(b->k, '[]'::jsonb))
    ) both_sides
  )), '{}'::jsonb)
  from (
    select jsonb_object_keys(coalesce(a, '{}'::jsonb)) as k
    union
    select jsonb_object_keys(coalesce(b, '{}'::jsonb))
  ) keys;
$$;

create aggregate public.command_sources_merge_all(jsonb) (sfunc = public.command_sources_merge, stype = jsonb);

-- A mesma `my_project_policies` de antes, com `blocked_commands` e
-- `command_sources` na política do projeto. Projeto que só tem regra de
-- comando (sem política de LLM) também aparece, com a política vazia.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  with linked as (
    -- A organização do projeto, quando quem chama é membro dela: valem as
    -- regras dela e as de todos os repositórios dela.
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy,
           public.command_sources_of(pr.org_id, null, true) as sources, true as own
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    -- Cada repositório do projeto que uma organização de quem chama
    -- cadastrou, não só o primeiro.
    select pr.id, r.org_id, public.llm_policy_of(r.org_id, r.id), public.command_sources_of(r.org_id, r.id, false), false
    from public.projects pr
    cross join lateral jsonb_array_elements_text(
      case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
    ) as k(repo_key)
    join public.organization_repositories r on r.repo_key = k.repo_key
    join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
  ), merged as (
    select l.project_id,
           (array_agg(l.org_id order by l.own desc, o.slug))[1] as org_id,
           string_agg(distinct o.slug, ', ') as org_slug,
           public.policy_merge_all(l.policy order by l.own desc, o.slug) as policy,
           public.command_sources_merge_all(l.sources order by l.own desc, o.slug) as sources
    from linked l
    join public.organizations o on o.id = l.org_id
    group by l.project_id
  )
  select m.project_id, m.org_id, m.org_slug,
         coalesce(m.policy, '{}'::jsonb) || case
           when m.sources = '{}'::jsonb then '{}'::jsonb
           else jsonb_build_object(
             'blocked_commands', (select jsonb_agg(k order by k) from jsonb_object_keys(m.sources) k),
             'command_sources', m.sources)
         end
  from merged m
  where m.policy is not null or m.sources <> '{}'::jsonb;
$$;

revoke execute on function public.command_rules_ok(text[]) from public, anon, authenticated;
revoke execute on function public.command_sources_of(uuid, uuid, boolean) from public, anon, authenticated;
revoke execute on function public.command_sources_merge(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.set_command_rules(uuid, uuid, jsonb) from public, anon;
grant execute on function public.set_command_rules(uuid, uuid, jsonb) to authenticated;

-- Os textos da v0.77.0 (app e site), nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'grants.blockedBy', $json$"Bloqueado por {orgs}"$json$::jsonb),
  ('en', 'grants.blockedBy', $json$"Blocked by {orgs}"$json$::jsonb),
  ('es', 'grants.blockedBy', $json$"Bloqueado por {orgs}"$json$::jsonb),
  ('zh-CN', 'grants.blockedBy', $json$"被 {orgs} 阻止"$json$::jsonb),
  ('hi', 'grants.blockedBy', $json$"{orgs} द्वारा अवरुद्ध"$json$::jsonb),
  ('ar', 'grants.blockedBy', $json$"محظور بواسطة {orgs}"$json$::jsonb),
  ('fr', 'grants.blockedBy', $json$"Bloqué par {orgs}"$json$::jsonb),
  ('ru', 'grants.blockedBy', $json$"Заблокировано: {orgs}"$json$::jsonb),
  ('ja', 'grants.blockedBy', $json$"{orgs} がブロック中"$json$::jsonb),
  ('de', 'grants.blockedBy', $json$"Blockiert von {orgs}"$json$::jsonb),
  ('pt-BR', 'grants.commands', $json$"Comandos específicos"$json$::jsonb),
  ('en', 'grants.commands', $json$"Specific commands"$json$::jsonb),
  ('es', 'grants.commands', $json$"Comandos concretos"$json$::jsonb),
  ('zh-CN', 'grants.commands', $json$"指定命令"$json$::jsonb),
  ('hi', 'grants.commands', $json$"विशिष्ट कमांड"$json$::jsonb),
  ('ar', 'grants.commands', $json$"أوامر محددة"$json$::jsonb),
  ('fr', 'grants.commands', $json$"Commandes précises"$json$::jsonb),
  ('ru', 'grants.commands', $json$"Отдельные команды"$json$::jsonb),
  ('ja', 'grants.commands', $json$"個別のコマンド"$json$::jsonb),
  ('de', 'grants.commands', $json$"Bestimmte Befehle"$json$::jsonb),
  ('pt-BR', 'grants.commands.hint', $json$"Escolha os comandos a permitir, só para a próxima mensagem."$json$::jsonb),
  ('en', 'grants.commands.hint', $json$"Pick the commands to allow, only for the next message."$json$::jsonb),
  ('es', 'grants.commands.hint', $json$"Elige los comandos que permitir, solo para el próximo mensaje."$json$::jsonb),
  ('zh-CN', 'grants.commands.hint', $json$"选择要允许的命令，仅对下一条消息有效。"$json$::jsonb),
  ('hi', 'grants.commands.hint', $json$"अनुमति देने के लिए कमांड चुनें, केवल अगले संदेश के लिए।"$json$::jsonb),
  ('ar', 'grants.commands.hint', $json$"اختر الأوامر المسموح بها، للرسالة التالية فقط."$json$::jsonb),
  ('fr', 'grants.commands.hint', $json$"Choisissez les commandes à autoriser, uniquement pour le prochain message."$json$::jsonb),
  ('ru', 'grants.commands.hint', $json$"Выберите команды, которые нужно разрешить, только для следующего сообщения."$json$::jsonb),
  ('ja', 'grants.commands.hint', $json$"許可するコマンドを選びます。次のメッセージにだけ有効です。"$json$::jsonb),
  ('de', 'grants.commands.hint', $json$"Wählen Sie die erlaubten Befehle, nur für die nächste Nachricht."$json$::jsonb),
  ('pt-BR', 'grants.commands.blockedHint', $json$"Escolha os comandos a permitir. Os que a sua organização bloqueia ficam desativados e o agente nunca os recebe."$json$::jsonb),
  ('en', 'grants.commands.blockedHint', $json$"Pick the commands to allow. The ones your organization blocks are disabled and the agent never gets them."$json$::jsonb),
  ('es', 'grants.commands.blockedHint', $json$"Elige los comandos que permitir. Los que bloquea tu organización aparecen desactivados y el agente nunca los recibe."$json$::jsonb),
  ('zh-CN', 'grants.commands.blockedHint', $json$"选择要允许的命令。你所在组织阻止的命令会被禁用，智能体永远得不到它们。"$json$::jsonb),
  ('hi', 'grants.commands.blockedHint', $json$"अनुमति देने के लिए कमांड चुनें। आपके संगठन द्वारा अवरुद्ध कमांड बंद रहते हैं और एजेंट को कभी नहीं मिलते।"$json$::jsonb),
  ('ar', 'grants.commands.blockedHint', $json$"اختر الأوامر المسموح بها. الأوامر التي تحظرها مؤسستك معطّلة ولن يحصل عليها الوكيل أبدًا."$json$::jsonb),
  ('fr', 'grants.commands.blockedHint', $json$"Choisissez les commandes à autoriser. Celles que votre organisation bloque sont désactivées et l'agent ne les reçoit jamais."$json$::jsonb),
  ('ru', 'grants.commands.blockedHint', $json$"Выберите команды, которые нужно разрешить. Те, что блокирует ваша организация, отключены, и агент их никогда не получит."$json$::jsonb),
  ('ja', 'grants.commands.blockedHint', $json$"許可するコマンドを選びます。組織がブロックしているものは無効で、エージェントには決して渡されません。"$json$::jsonb),
  ('de', 'grants.commands.blockedHint', $json$"Wählen Sie die erlaubten Befehle. Die von Ihrer Organisation blockierten sind deaktiviert, und der Agent erhält sie nie."$json$::jsonb),
  ('pt-BR', 'grants.command.all', $json$"Todos os comandos {tool}"$json$::jsonb),
  ('en', 'grants.command.all', $json$"Every {tool} command"$json$::jsonb),
  ('es', 'grants.command.all', $json$"Todos los comandos de {tool}"$json$::jsonb),
  ('zh-CN', 'grants.command.all', $json$"所有 {tool} 命令"$json$::jsonb),
  ('hi', 'grants.command.all', $json$"{tool} के सभी कमांड"$json$::jsonb),
  ('ar', 'grants.command.all', $json$"جميع أوامر {tool}"$json$::jsonb),
  ('fr', 'grants.command.all', $json$"Toutes les commandes {tool}"$json$::jsonb),
  ('ru', 'grants.command.all', $json$"Все команды {tool}"$json$::jsonb),
  ('ja', 'grants.command.all', $json$"{tool} のすべてのコマンド"$json$::jsonb),
  ('de', 'grants.command.all', $json$"Alle {tool}-Befehle"$json$::jsonb),
  ('pt-BR', 'beat.permissionBlocked', $json$"Bloqueado por {org}: {commands}. O agente não pode rodá-los neste projeto."$json$::jsonb),
  ('en', 'beat.permissionBlocked', $json$"Blocked by {org}: {commands}. The agent can't run them in this project."$json$::jsonb),
  ('es', 'beat.permissionBlocked', $json$"Bloqueado por {org}: {commands}. El agente no puede ejecutarlos en este proyecto."$json$::jsonb),
  ('zh-CN', 'beat.permissionBlocked', $json$"被 {org} 阻止：{commands}。智能体不能在此项目中运行它们。"$json$::jsonb),
  ('hi', 'beat.permissionBlocked', $json$"{org} द्वारा अवरुद्ध: {commands}। एजेंट इस प्रोजेक्ट में इन्हें नहीं चला सकता।"$json$::jsonb),
  ('ar', 'beat.permissionBlocked', $json$"محظور بواسطة {org}: {commands}. لا يستطيع الوكيل تشغيلها في هذا المشروع."$json$::jsonb),
  ('fr', 'beat.permissionBlocked', $json$"Bloqué par {org} : {commands}. L'agent ne peut pas les exécuter dans ce projet."$json$::jsonb),
  ('ru', 'beat.permissionBlocked', $json$"Заблокировано организацией {org}: {commands}. Агент не может выполнять их в этом проекте."$json$::jsonb),
  ('ja', 'beat.permissionBlocked', $json$"{org} がブロック: {commands}。このプロジェクトではエージェントは実行できません。"$json$::jsonb),
  ('de', 'beat.permissionBlocked', $json$"Blockiert von {org}: {commands}. Der Agent darf sie in diesem Projekt nicht ausführen."$json$::jsonb),
  ('pt-BR', 'palette.commandPermissions', $json$"Permissões de comandos da próxima mensagem"$json$::jsonb),
  ('en', 'palette.commandPermissions', $json$"Command permissions for the next message"$json$::jsonb),
  ('es', 'palette.commandPermissions', $json$"Permisos de comandos del próximo mensaje"$json$::jsonb),
  ('zh-CN', 'palette.commandPermissions', $json$"下一条消息的命令权限"$json$::jsonb),
  ('hi', 'palette.commandPermissions', $json$"अगले संदेश की कमांड अनुमतियाँ"$json$::jsonb),
  ('ar', 'palette.commandPermissions', $json$"أذونات الأوامر للرسالة التالية"$json$::jsonb),
  ('fr', 'palette.commandPermissions', $json$"Autorisations de commandes du prochain message"$json$::jsonb),
  ('ru', 'palette.commandPermissions', $json$"Разрешения на команды для следующего сообщения"$json$::jsonb),
  ('ja', 'palette.commandPermissions', $json$"次のメッセージのコマンド許可"$json$::jsonb),
  ('de', 'palette.commandPermissions', $json$"Befehlsberechtigungen für die nächste Nachricht"$json$::jsonb),
  ('pt-BR', 'palette.orgSitePermissions', $json$"{org}: permissões de comandos (site)"$json$::jsonb),
  ('en', 'palette.orgSitePermissions', $json$"{org}: command permissions (site)"$json$::jsonb),
  ('es', 'palette.orgSitePermissions', $json$"{org}: permisos de comandos (sitio)"$json$::jsonb),
  ('zh-CN', 'palette.orgSitePermissions', $json$"{org}：命令权限（网站）"$json$::jsonb),
  ('hi', 'palette.orgSitePermissions', $json$"{org}: कमांड अनुमतियाँ (साइट)"$json$::jsonb),
  ('ar', 'palette.orgSitePermissions', $json$"{org}: أذونات الأوامر (الموقع)"$json$::jsonb),
  ('fr', 'palette.orgSitePermissions', $json$"{org} : autorisations de commandes (site)"$json$::jsonb),
  ('ru', 'palette.orgSitePermissions', $json$"{org}: разрешения на команды (сайт)"$json$::jsonb),
  ('ja', 'palette.orgSitePermissions', $json$"{org}: コマンド許可（サイト）"$json$::jsonb),
  ('de', 'palette.orgSitePermissions', $json$"{org}: Befehlsberechtigungen (Website)"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.commandPermissions.title', $json$"Permissões de comandos da organização"$json$::jsonb),
  ('en', 'whatsNew.item.commandPermissions.title', $json$"Command permissions of the organization"$json$::jsonb),
  ('es', 'whatsNew.item.commandPermissions.title', $json$"Permisos de comandos de la organización"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.commandPermissions.title', $json$"组织的命令权限"$json$::jsonb),
  ('hi', 'whatsNew.item.commandPermissions.title', $json$"संगठन की कमांड अनुमतियाँ"$json$::jsonb),
  ('ar', 'whatsNew.item.commandPermissions.title', $json$"أذونات الأوامر في المؤسسة"$json$::jsonb),
  ('fr', 'whatsNew.item.commandPermissions.title', $json$"Autorisations de commandes de l'organisation"$json$::jsonb),
  ('ru', 'whatsNew.item.commandPermissions.title', $json$"Разрешения на команды в организации"$json$::jsonb),
  ('ja', 'whatsNew.item.commandPermissions.title', $json$"組織のコマンド許可"$json$::jsonb),
  ('de', 'whatsNew.item.commandPermissions.title', $json$"Befehlsberechtigungen der Organisation"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.commandPermissions.detail', $json$"Donos e mantenedores escolhem no site quais comandos os agentes nunca rodam nos projetos da organização, para a organização inteira e para cada repositório. Nas Permissões do chat você libera comandos específicos para a próxima mensagem; os bloqueados aparecem desativados como \"Bloqueado por <organização>\" e o agente nunca os recebe. O Claude e o Copilot recusam cada comando bloqueado; o Codex, o Cursor e o Kilo, que não têm lista de comandos, rodam no modo mais travado nesses projetos."$json$::jsonb),
  ('en', 'whatsNew.item.commandPermissions.detail', $json$"Owners and maintainers choose on the site which commands agents never run in the organization's projects, for the whole organization and for each repository. In the chat's Permissions you can allow specific commands for the next message; the blocked ones show disabled as \"Blocked by <organization>\", and the agent is never given them. Claude and Copilot refuse each blocked command; Codex, Cursor and Kilo, which have no per-command list, run in their safest mode in those projects."$json$::jsonb),
  ('es', 'whatsNew.item.commandPermissions.detail', $json$"Los propietarios y mantenedores eligen en el sitio qué comandos nunca ejecutan los agentes en los proyectos de la organización, para toda la organización y para cada repositorio. En los Permisos del chat puedes permitir comandos concretos para el próximo mensaje; los bloqueados aparecen desactivados como \"Bloqueado por <organización>\" y el agente nunca los recibe. Claude y Copilot rechazan cada comando bloqueado; Codex, Cursor y Kilo, que no tienen lista de comandos, se ejecutan en su modo más restringido en esos proyectos."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.commandPermissions.detail', $json$"所有者和维护者在网站上选择智能体在组织项目中永远不能运行的命令，可针对整个组织，也可针对每个仓库。在聊天的权限中，你可以为下一条消息允许特定命令；被阻止的命令会显示为禁用，并标注“被 <组织> 阻止”，智能体永远得不到它们。Claude 和 Copilot 会拒绝每条被阻止的命令；没有命令列表的 Codex、Cursor 和 Kilo 在这些项目中以最严格的模式运行。"$json$::jsonb),
  ('hi', 'whatsNew.item.commandPermissions.detail', $json$"स्वामी और मेंटेनर साइट पर चुनते हैं कि एजेंट संगठन के प्रोजेक्ट में कौन-से कमांड कभी नहीं चलाएँगे, पूरे संगठन के लिए और हर रिपॉज़िटरी के लिए। चैट की अनुमतियों में आप अगले संदेश के लिए विशिष्ट कमांड की अनुमति दे सकते हैं; अवरुद्ध कमांड \"<संगठन> द्वारा अवरुद्ध\" के साथ बंद दिखते हैं और एजेंट को कभी नहीं मिलते। Claude और Copilot हर अवरुद्ध कमांड को अस्वीकार करते हैं; Codex, Cursor और Kilo में कमांड सूची नहीं होती, इसलिए वे इन प्रोजेक्ट में अपने सबसे सख़्त मोड में चलते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.commandPermissions.detail', $json$"يختار المالكون والمشرفون في الموقع الأوامر التي لا ينفذها الوكلاء أبدًا في مشاريع المؤسسة، للمؤسسة كلها ولكل مستودع. في أذونات المحادثة يمكنك السماح بأوامر محددة للرسالة التالية؛ وتظهر المحظورة معطّلة بعبارة \"محظور بواسطة <المؤسسة>\" ولا يحصل عليها الوكيل أبدًا. يرفض Claude وCopilot كل أمر محظور؛ أما Codex وCursor وKilo، التي ليس لها قائمة أوامر، فتعمل في هذه المشاريع بأكثر أوضاعها تقييدًا."$json$::jsonb),
  ('fr', 'whatsNew.item.commandPermissions.detail', $json$"Les propriétaires et mainteneurs choisissent sur le site les commandes que les agents n'exécutent jamais dans les projets de l'organisation, pour toute l'organisation et pour chaque dépôt. Dans les Autorisations du chat, vous pouvez autoriser des commandes précises pour le prochain message ; celles qui sont bloquées apparaissent désactivées avec « Bloqué par <organisation> » et l'agent ne les reçoit jamais. Claude et Copilot refusent chaque commande bloquée ; Codex, Cursor et Kilo, qui n'ont pas de liste de commandes, s'exécutent dans leur mode le plus restreint dans ces projets."$json$::jsonb),
  ('ru', 'whatsNew.item.commandPermissions.detail', $json$"Владельцы и мейнтейнеры выбирают на сайте, какие команды агенты никогда не выполняют в проектах организации, для всей организации и для каждого репозитория. В разрешениях чата можно разрешить отдельные команды для следующего сообщения; заблокированные отображаются отключёнными с пометкой «Заблокировано: <организация>», и агент их никогда не получает. Claude и Copilot отклоняют каждую заблокированную команду; Codex, Cursor и Kilo, у которых нет списка команд, работают в таких проектах в самом строгом режиме."$json$::jsonb),
  ('ja', 'whatsNew.item.commandPermissions.detail', $json$"オーナーとメンテナーは、サイトで、組織のプロジェクトでエージェントが決して実行しないコマンドを、組織全体とリポジトリごとに選べます。チャットの許可では、次のメッセージに限って特定のコマンドを許可できます。ブロックされたものは「<組織> がブロック中」と表示されて無効になり、エージェントには決して渡されません。Claude と Copilot はブロックされたコマンドをそれぞれ拒否します。コマンド一覧を持たない Codex、Cursor、Kilo は、そのプロジェクトでは最も制限の厳しいモードで動作します。"$json$::jsonb),
  ('de', 'whatsNew.item.commandPermissions.detail', $json$"Eigentümer und Maintainer legen auf der Website fest, welche Befehle Agenten in den Projekten der Organisation nie ausführen, für die ganze Organisation und für jedes Repository. In den Berechtigungen des Chats können Sie einzelne Befehle für die nächste Nachricht erlauben; blockierte erscheinen deaktiviert als „Blockiert von <Organisation>“, und der Agent erhält sie nie. Claude und Copilot lehnen jeden blockierten Befehl ab; Codex, Cursor und Kilo, die keine Befehlsliste haben, laufen in diesen Projekten im restriktivsten Modus."$json$::jsonb),
  ('pt-BR', 'docs.commandPermissions.title', $json$"Permissões de comandos da organização"$json$::jsonb),
  ('en', 'docs.commandPermissions.title', $json$"Command permissions of the organization"$json$::jsonb),
  ('es', 'docs.commandPermissions.title', $json$"Permisos de comandos de la organización"$json$::jsonb),
  ('zh-CN', 'docs.commandPermissions.title', $json$"组织的命令权限"$json$::jsonb),
  ('hi', 'docs.commandPermissions.title', $json$"संगठन की कमांड अनुमतियाँ"$json$::jsonb),
  ('ar', 'docs.commandPermissions.title', $json$"أذونات الأوامر في المؤسسة"$json$::jsonb),
  ('fr', 'docs.commandPermissions.title', $json$"Autorisations de commandes de l'organisation"$json$::jsonb),
  ('ru', 'docs.commandPermissions.title', $json$"Разрешения на команды в организации"$json$::jsonb),
  ('ja', 'docs.commandPermissions.title', $json$"組織のコマンド許可"$json$::jsonb),
  ('de', 'docs.commandPermissions.title', $json$"Befehlsberechtigungen der Organisation"$json$::jsonb),
  ('pt-BR', 'docs.commandPermissions.summary', $json$"Donos e mantenedores escolhem no site do JayV quais comandos os agentes nunca rodam nos projetos da organização (git push, npm publish, docker…), para a organização inteira e, de forma mais restrita, para cada repositório. Nas Permissões do chat, os comandos permitidos podem ser liberados um a um e os bloqueados aparecem desativados como \"Bloqueado por <organização>\"; o agente nunca recebe um comando bloqueado."$json$::jsonb),
  ('en', 'docs.commandPermissions.summary', $json$"Owners and maintainers choose on the JayV site which commands the agents never run in the organization's projects (git push, npm publish, docker…), for the whole organization and, tighter, for each repository. In the chat's Permissions, the allowed commands can be granted one by one and the blocked ones show disabled as \"Blocked by <organization>\"; the agent is never given a blocked command."$json$::jsonb),
  ('es', 'docs.commandPermissions.summary', $json$"Los propietarios y mantenedores eligen en el sitio de JayV qué comandos nunca ejecutan los agentes en los proyectos de la organización (git push, npm publish, docker…), para toda la organización y, de forma más restrictiva, para cada repositorio. En los Permisos del chat, los comandos permitidos se pueden conceder uno a uno y los bloqueados aparecen desactivados como \"Bloqueado por <organización>\"; el agente nunca recibe un comando bloqueado."$json$::jsonb),
  ('zh-CN', 'docs.commandPermissions.summary', $json$"所有者和维护者在 JayV 网站上选择智能体在组织项目中永远不能运行的命令（git push、npm publish、docker…），可针对整个组织，也可更严格地针对每个仓库。在聊天的权限中，被允许的命令可以逐条授予，被阻止的命令显示为禁用并标注“被 <组织> 阻止”；智能体永远不会得到被阻止的命令。"$json$::jsonb),
  ('hi', 'docs.commandPermissions.summary', $json$"स्वामी और मेंटेनर JayV साइट पर चुनते हैं कि एजेंट संगठन के प्रोजेक्ट में कौन-से कमांड कभी नहीं चलाएँगे (git push, npm publish, docker…), पूरे संगठन के लिए और अधिक सख़्ती से हर रिपॉज़िटरी के लिए। चैट की अनुमतियों में अनुमत कमांड एक-एक करके दिए जा सकते हैं और अवरुद्ध कमांड \"<संगठन> द्वारा अवरुद्ध\" के साथ बंद दिखते हैं; एजेंट को अवरुद्ध कमांड कभी नहीं मिलता।"$json$::jsonb),
  ('ar', 'docs.commandPermissions.summary', $json$"يختار المالكون والمشرفون في موقع JayV الأوامر التي لا ينفذها الوكلاء أبدًا في مشاريع المؤسسة (git push وnpm publish وdocker…)، للمؤسسة كلها وبصرامة أكبر لكل مستودع. في أذونات المحادثة يمكن منح الأوامر المسموح بها واحدًا تلو الآخر، وتظهر المحظورة معطّلة بعبارة \"محظور بواسطة <المؤسسة>\"؛ ولا يحصل الوكيل أبدًا على أمر محظور."$json$::jsonb),
  ('fr', 'docs.commandPermissions.summary', $json$"Les propriétaires et mainteneurs choisissent sur le site JayV les commandes que les agents n'exécutent jamais dans les projets de l'organisation (git push, npm publish, docker…), pour toute l'organisation et, de façon plus restrictive, pour chaque dépôt. Dans les Autorisations du chat, les commandes autorisées peuvent être accordées une à une et celles qui sont bloquées apparaissent désactivées avec « Bloqué par <organisation> » ; l'agent ne reçoit jamais une commande bloquée."$json$::jsonb),
  ('ru', 'docs.commandPermissions.summary', $json$"Владельцы и мейнтейнеры выбирают на сайте JayV, какие команды агенты никогда не выполняют в проектах организации (git push, npm publish, docker…), для всей организации и, более строго, для каждого репозитория. В разрешениях чата разрешённые команды можно выдавать по одной, а заблокированные отображаются отключёнными с пометкой «Заблокировано: <организация>»; агент никогда не получает заблокированную команду."$json$::jsonb),
  ('ja', 'docs.commandPermissions.summary', $json$"オーナーとメンテナーは、JayV のサイトで、組織のプロジェクトでエージェントが決して実行しないコマンド（git push、npm publish、docker など）を、組織全体と、より厳しくリポジトリごとに選べます。チャットの許可では、許可されたコマンドを一つずつ付与でき、ブロックされたものは「<組織> がブロック中」と表示されて無効になります。エージェントにブロックされたコマンドが渡されることはありません。"$json$::jsonb),
  ('de', 'docs.commandPermissions.summary', $json$"Eigentümer und Maintainer legen auf der JayV-Website fest, welche Befehle Agenten in den Projekten der Organisation nie ausführen (git push, npm publish, docker …), für die ganze Organisation und, enger gefasst, für jedes Repository. In den Berechtigungen des Chats lassen sich erlaubte Befehle einzeln freigeben, blockierte erscheinen deaktiviert als „Blockiert von <Organisation>“; der Agent erhält nie einen blockierten Befehl."$json$::jsonb),
  ('pt-BR', 'docs.commandPermissions.usage', $json$"No site, abra a organização e use a aba Permissões: escolha o escopo (a organização inteira ou um repositório), marque um programa para bloquear todos os subcomandos dele ou só os subcomandos que não devem rodar, acrescente outros comandos, um por linha, e salve. Um repositório só pode bloquear mais do que a organização. No chat, abra Permissões ao lado do modo de trabalho (ou Ctrl+K › Permissões de comandos) para liberar comandos específicos para a próxima mensagem. Se um agente pedir um comando bloqueado, o JayV não pergunta a você: a etapa diz quem o bloqueou. O Claude e o Copilot recusam cada comando bloqueado; o Codex, o Cursor e o Kilo não têm lista de comandos, então nesses projetos rodam no modo mais travado. A mudança chega na próxima sincronização."$json$::jsonb),
  ('en', 'docs.commandPermissions.usage', $json$"On the site, open the organization and use the Permissions tab: pick the scope (the whole organization or one repository), check a program to block all of its subcommands or only the subcommands that must not run, add other commands one per line, and save. A repository can only block more than the organization does. In a chat, open Permissions beside the work mode (or Ctrl+K › Command permissions) to allow specific commands for the next message. If an agent asks to run a blocked command, JayV does not ask you: the step says who blocked it. Claude and Copilot refuse each blocked command; Codex, Cursor and Kilo have no per-command list, so in these projects they run in their safest mode. The change arrives at the next sync."$json$::jsonb),
  ('es', 'docs.commandPermissions.usage', $json$"En el sitio, abre la organización y usa la pestaña Permisos: elige el alcance (toda la organización o un repositorio), marca un programa para bloquear todos sus subcomandos o solo los que no deben ejecutarse, añade otros comandos, uno por línea, y guarda. Un repositorio solo puede bloquear más que la organización. En el chat, abre Permisos junto al modo de trabajo (o Ctrl+K › Permisos de comandos) para permitir comandos concretos para el próximo mensaje. Si un agente pide un comando bloqueado, JayV no te pregunta: el paso indica quién lo bloqueó. Claude y Copilot rechazan cada comando bloqueado; Codex, Cursor y Kilo no tienen lista de comandos, así que en estos proyectos se ejecutan en su modo más restringido. El cambio llega en la próxima sincronización."$json$::jsonb),
  ('zh-CN', 'docs.commandPermissions.usage', $json$"在网站上打开组织，使用“权限”选项卡：选择范围（整个组织或某个仓库），勾选一个程序以阻止它的所有子命令，或只阻止不应运行的子命令，再逐行添加其他命令并保存。仓库只能比组织阻止得更多。在聊天中，打开工作模式旁边的“权限”（或 Ctrl+K › 命令权限），可为下一条消息允许特定命令。如果智能体请求被阻止的命令，JayV 不会询问你：该步骤会说明是谁阻止的。Claude 和 Copilot 会拒绝每条被阻止的命令；Codex、Cursor 和 Kilo 没有命令列表，因此在这些项目中以最严格的模式运行。更改会在下次同步时生效。"$json$::jsonb),
  ('hi', 'docs.commandPermissions.usage', $json$"साइट पर संगठन खोलें और अनुमतियाँ टैब इस्तेमाल करें: दायरा चुनें (पूरा संगठन या कोई रिपॉज़िटरी), किसी प्रोग्राम को चिह्नित करके उसके सभी सबकमांड, या केवल वे सबकमांड अवरुद्ध करें जो नहीं चलने चाहिए, अन्य कमांड एक-एक पंक्ति में जोड़ें और सहेजें। रिपॉज़िटरी संगठन से केवल अधिक अवरुद्ध कर सकती है। चैट में कार्य मोड के बगल में अनुमतियाँ खोलें (या Ctrl+K › कमांड अनुमतियाँ) ताकि अगले संदेश के लिए विशिष्ट कमांड की अनुमति दी जा सके। यदि कोई एजेंट अवरुद्ध कमांड माँगता है, तो JayV आपसे नहीं पूछता: चरण बताता है कि उसे किसने अवरुद्ध किया। Claude और Copilot हर अवरुद्ध कमांड को अस्वीकार करते हैं; Codex, Cursor और Kilo में कमांड सूची नहीं होती, इसलिए वे इन प्रोजेक्ट में अपने सबसे सख़्त मोड में चलते हैं। बदलाव अगली सिंक पर पहुँचता है।"$json$::jsonb),
  ('ar', 'docs.commandPermissions.usage', $json$"في الموقع افتح المؤسسة واستخدم تبويب الأذونات: اختر النطاق (المؤسسة كلها أو مستودعًا)، وحدد برنامجًا لحظر كل أوامره الفرعية أو الأوامر الفرعية التي يجب ألا تعمل فقط، وأضف أوامر أخرى، واحدًا في كل سطر، ثم احفظ. لا يستطيع المستودع إلا أن يحظر أكثر مما تحظره المؤسسة. في المحادثة افتح الأذونات بجانب وضع العمل (أو Ctrl+K › أذونات الأوامر) للسماح بأوامر محددة للرسالة التالية. إذا طلب وكيل أمرًا محظورًا فلن يسألك JayV: تذكر الخطوة من حظره. يرفض Claude وCopilot كل أمر محظور؛ أما Codex وCursor وKilo فليس لها قائمة أوامر، لذلك تعمل في هذه المشاريع بأكثر أوضاعها تقييدًا. يصل التغيير مع المزامنة التالية."$json$::jsonb),
  ('fr', 'docs.commandPermissions.usage', $json$"Sur le site, ouvrez l'organisation et utilisez l'onglet Autorisations : choisissez la portée (toute l'organisation ou un dépôt), cochez un programme pour bloquer toutes ses sous-commandes ou seulement celles qui ne doivent pas s'exécuter, ajoutez d'autres commandes, une par ligne, puis enregistrez. Un dépôt ne peut que bloquer davantage que l'organisation. Dans le chat, ouvrez Autorisations à côté du mode de travail (ou Ctrl+K › Autorisations de commandes) pour autoriser des commandes précises pour le prochain message. Si un agent demande une commande bloquée, JayV ne vous interroge pas : l'étape indique qui l'a bloquée. Claude et Copilot refusent chaque commande bloquée ; Codex, Cursor et Kilo n'ont pas de liste de commandes, donc dans ces projets ils s'exécutent dans leur mode le plus restreint. Le changement arrive à la prochaine synchronisation."$json$::jsonb),
  ('ru', 'docs.commandPermissions.usage', $json$"На сайте откройте организацию и перейдите на вкладку «Разрешения»: выберите область действия (вся организация или один репозиторий), отметьте программу, чтобы заблокировать все её подкоманды или только те, что не должны выполняться, добавьте другие команды по одной в строке и сохраните. Репозиторий может блокировать только больше, чем организация. В чате откройте «Разрешения» рядом с режимом работы (или Ctrl+K › «Разрешения на команды»), чтобы разрешить отдельные команды для следующего сообщения. Если агент просит заблокированную команду, JayV вас не спрашивает: шаг показывает, кто её заблокировал. Claude и Copilot отклоняют каждую заблокированную команду; у Codex, Cursor и Kilo нет списка команд, поэтому в таких проектах они работают в самом строгом режиме. Изменение приходит при следующей синхронизации."$json$::jsonb),
  ('ja', 'docs.commandPermissions.usage', $json$"サイトで組織を開き、「許可」タブを使います。範囲（組織全体または一つのリポジトリ）を選び、プログラムにチェックを入れてそのすべてのサブコマンド、または実行してはならないサブコマンドだけをブロックし、ほかのコマンドを一行に一つずつ追加して保存します。リポジトリは組織よりも多くをブロックすることしかできません。チャットでは、作業モードの横の「許可」（または Ctrl+K › コマンド許可）から、次のメッセージに限って特定のコマンドを許可できます。エージェントがブロックされたコマンドを求めても、JayV はあなたに尋ねません。ステップに誰がブロックしたかが表示されます。Claude と Copilot はブロックされたコマンドをそれぞれ拒否します。コマンド一覧を持たない Codex、Cursor、Kilo は、そのプロジェクトでは最も制限の厳しいモードで動作します。変更は次の同期で届きます。"$json$::jsonb),
  ('de', 'docs.commandPermissions.usage', $json$"Öffnen Sie auf der Website die Organisation und nutzen Sie den Tab Berechtigungen: Wählen Sie den Geltungsbereich (die ganze Organisation oder ein Repository), markieren Sie ein Programm, um alle seine Unterbefehle oder nur die nicht erlaubten zu blockieren, fügen Sie weitere Befehle hinzu, einen pro Zeile, und speichern Sie. Ein Repository kann nur mehr blockieren als die Organisation. Öffnen Sie im Chat neben dem Arbeitsmodus die Berechtigungen (oder Ctrl+K › Befehlsberechtigungen), um bestimmte Befehle für die nächste Nachricht zu erlauben. Fragt ein Agent nach einem blockierten Befehl, fragt JayV Sie nicht: Der Schritt nennt, wer ihn blockiert hat. Claude und Copilot lehnen jeden blockierten Befehl ab; Codex, Cursor und Kilo haben keine Befehlsliste und laufen in diesen Projekten im restriktivsten Modus. Die Änderung kommt bei der nächsten Synchronisierung an."$json$::jsonb),
  ('pt-BR', 'site.org.tab.permissions', $json$"Permissões"$json$::jsonb),
  ('en', 'site.org.tab.permissions', $json$"Permissions"$json$::jsonb),
  ('es', 'site.org.tab.permissions', $json$"Permisos"$json$::jsonb),
  ('zh-CN', 'site.org.tab.permissions', $json$"权限"$json$::jsonb),
  ('hi', 'site.org.tab.permissions', $json$"अनुमतियाँ"$json$::jsonb),
  ('ar', 'site.org.tab.permissions', $json$"الأذونات"$json$::jsonb),
  ('fr', 'site.org.tab.permissions', $json$"Autorisations"$json$::jsonb),
  ('ru', 'site.org.tab.permissions', $json$"Разрешения"$json$::jsonb),
  ('ja', 'site.org.tab.permissions', $json$"許可"$json$::jsonb),
  ('de', 'site.org.tab.permissions', $json$"Berechtigungen"$json$::jsonb),
  ('pt-BR', 'site.perm.title', $json$"Permissões de comandos"$json$::jsonb),
  ('en', 'site.perm.title', $json$"Command permissions"$json$::jsonb),
  ('es', 'site.perm.title', $json$"Permisos de comandos"$json$::jsonb),
  ('zh-CN', 'site.perm.title', $json$"命令权限"$json$::jsonb),
  ('hi', 'site.perm.title', $json$"कमांड अनुमतियाँ"$json$::jsonb),
  ('ar', 'site.perm.title', $json$"أذونات الأوامر"$json$::jsonb),
  ('fr', 'site.perm.title', $json$"Autorisations de commandes"$json$::jsonb),
  ('ru', 'site.perm.title', $json$"Разрешения на команды"$json$::jsonb),
  ('ja', 'site.perm.title', $json$"コマンド許可"$json$::jsonb),
  ('de', 'site.perm.title', $json$"Befehlsberechtigungen"$json$::jsonb),
  ('pt-BR', 'site.perm.description', $json$"Escolha os comandos que os agentes nunca rodam nos projetos desta organização. Os bloqueados aparecem desativados nas permissões do chat e nunca são liberados ao agente."$json$::jsonb),
  ('en', 'site.perm.description', $json$"Choose the commands that agents may never run in this organization's projects. Blocked commands show as disabled in the chat's permissions and are never granted to the agent."$json$::jsonb),
  ('es', 'site.perm.description', $json$"Elige los comandos que los agentes nunca ejecutan en los proyectos de esta organización. Los bloqueados aparecen desactivados en los permisos del chat y nunca se conceden al agente."$json$::jsonb),
  ('zh-CN', 'site.perm.description', $json$"选择智能体在此组织的项目中永远不能运行的命令。被阻止的命令会在聊天权限中显示为禁用，也永远不会授予智能体。"$json$::jsonb),
  ('hi', 'site.perm.description', $json$"चुनें कि इस संगठन के प्रोजेक्ट में एजेंट कौन-से कमांड कभी नहीं चलाएँगे। अवरुद्ध कमांड चैट की अनुमतियों में बंद दिखते हैं और एजेंट को कभी नहीं दिए जाते।"$json$::jsonb),
  ('ar', 'site.perm.description', $json$"اختر الأوامر التي لا ينفذها الوكلاء أبدًا في مشاريع هذه المؤسسة. تظهر الأوامر المحظورة معطّلة في أذونات المحادثة ولا تُمنح للوكيل أبدًا."$json$::jsonb),
  ('fr', 'site.perm.description', $json$"Choisissez les commandes que les agents n'exécutent jamais dans les projets de cette organisation. Les commandes bloquées apparaissent désactivées dans les autorisations du chat et ne sont jamais accordées à l'agent."$json$::jsonb),
  ('ru', 'site.perm.description', $json$"Выберите команды, которые агенты никогда не выполняют в проектах этой организации. Заблокированные отображаются отключёнными в разрешениях чата и никогда не выдаются агенту."$json$::jsonb),
  ('ja', 'site.perm.description', $json$"この組織のプロジェクトでエージェントが決して実行しないコマンドを選びます。ブロックされたコマンドはチャットの許可で無効と表示され、エージェントには決して付与されません。"$json$::jsonb),
  ('de', 'site.perm.description', $json$"Wählen Sie die Befehle, die Agenten in den Projekten dieser Organisation nie ausführen. Blockierte erscheinen deaktiviert in den Chat-Berechtigungen und werden dem Agenten nie gewährt."$json$::jsonb),
  ('pt-BR', 'site.perm.repoNote', $json$"Um repositório só pode bloquear mais: o que a organização bloqueou aparece marcado e travado."$json$::jsonb),
  ('en', 'site.perm.repoNote', $json$"A repository can only block more: what the organization blocked appears checked and locked."$json$::jsonb),
  ('es', 'site.perm.repoNote', $json$"Un repositorio solo puede bloquear más: lo que bloqueó la organización aparece marcado y bloqueado."$json$::jsonb),
  ('zh-CN', 'site.perm.repoNote', $json$"仓库只能阻止得更多：组织已阻止的命令会显示为已勾选并锁定。"$json$::jsonb),
  ('hi', 'site.perm.repoNote', $json$"रिपॉज़िटरी केवल अधिक अवरुद्ध कर सकती है: संगठन ने जो अवरुद्ध किया वह चिह्नित और बंद दिखता है।"$json$::jsonb),
  ('ar', 'site.perm.repoNote', $json$"لا يستطيع المستودع إلا أن يحظر أكثر: ما حظرته المؤسسة يظهر محددًا ومقفلًا."$json$::jsonb),
  ('fr', 'site.perm.repoNote', $json$"Un dépôt ne peut que bloquer davantage : ce que l'organisation a bloqué apparaît coché et verrouillé."$json$::jsonb),
  ('ru', 'site.perm.repoNote', $json$"Репозиторий может блокировать только больше: то, что заблокировала организация, отмечено и недоступно для изменения."$json$::jsonb),
  ('ja', 'site.perm.repoNote', $json$"リポジトリはより多くをブロックすることしかできません。組織がブロックしたものはチェック済みでロックされて表示されます。"$json$::jsonb),
  ('de', 'site.perm.repoNote', $json$"Ein Repository kann nur mehr blockieren: Was die Organisation blockiert hat, erscheint markiert und gesperrt."$json$::jsonb),
  ('pt-BR', 'site.perm.scope.set', $json$"tem comandos bloqueados"$json$::jsonb),
  ('en', 'site.perm.scope.set', $json$"has blocked commands"$json$::jsonb),
  ('es', 'site.perm.scope.set', $json$"tiene comandos bloqueados"$json$::jsonb),
  ('zh-CN', 'site.perm.scope.set', $json$"有被阻止的命令"$json$::jsonb),
  ('hi', 'site.perm.scope.set', $json$"अवरुद्ध कमांड हैं"$json$::jsonb),
  ('ar', 'site.perm.scope.set', $json$"لديه أوامر محظورة"$json$::jsonb),
  ('fr', 'site.perm.scope.set', $json$"a des commandes bloquées"$json$::jsonb),
  ('ru', 'site.perm.scope.set', $json$"есть заблокированные команды"$json$::jsonb),
  ('ja', 'site.perm.scope.set', $json$"ブロック済みコマンドあり"$json$::jsonb),
  ('de', 'site.perm.scope.set', $json$"hat blockierte Befehle"$json$::jsonb),
  ('pt-BR', 'site.perm.scope.unset', $json$"nada bloqueado"$json$::jsonb),
  ('en', 'site.perm.scope.unset', $json$"nothing blocked"$json$::jsonb),
  ('es', 'site.perm.scope.unset', $json$"nada bloqueado"$json$::jsonb),
  ('zh-CN', 'site.perm.scope.unset', $json$"未阻止任何命令"$json$::jsonb),
  ('hi', 'site.perm.scope.unset', $json$"कुछ अवरुद्ध नहीं"$json$::jsonb),
  ('ar', 'site.perm.scope.unset', $json$"لا شيء محظور"$json$::jsonb),
  ('fr', 'site.perm.scope.unset', $json$"rien de bloqué"$json$::jsonb),
  ('ru', 'site.perm.scope.unset', $json$"ничего не заблокировано"$json$::jsonb),
  ('ja', 'site.perm.scope.unset', $json$"ブロックなし"$json$::jsonb),
  ('de', 'site.perm.scope.unset', $json$"nichts blockiert"$json$::jsonb),
  ('pt-BR', 'site.perm.catalog', $json$"Comandos bloqueados"$json$::jsonb),
  ('en', 'site.perm.catalog', $json$"Blocked commands"$json$::jsonb),
  ('es', 'site.perm.catalog', $json$"Comandos bloqueados"$json$::jsonb),
  ('zh-CN', 'site.perm.catalog', $json$"被阻止的命令"$json$::jsonb),
  ('hi', 'site.perm.catalog', $json$"अवरुद्ध कमांड"$json$::jsonb),
  ('ar', 'site.perm.catalog', $json$"الأوامر المحظورة"$json$::jsonb),
  ('fr', 'site.perm.catalog', $json$"Commandes bloquées"$json$::jsonb),
  ('ru', 'site.perm.catalog', $json$"Заблокированные команды"$json$::jsonb),
  ('ja', 'site.perm.catalog', $json$"ブロックするコマンド"$json$::jsonb),
  ('de', 'site.perm.catalog', $json$"Blockierte Befehle"$json$::jsonb),
  ('pt-BR', 'site.perm.catalog.hint', $json$"Marque um programa para bloquear todos os subcomandos dele, ou só os subcomandos que não devem rodar."$json$::jsonb),
  ('en', 'site.perm.catalog.hint', $json$"Check a program to block all of its subcommands, or only the subcommands that must not run."$json$::jsonb),
  ('es', 'site.perm.catalog.hint', $json$"Marca un programa para bloquear todos sus subcomandos, o solo los subcomandos que no deben ejecutarse."$json$::jsonb),
  ('zh-CN', 'site.perm.catalog.hint', $json$"勾选一个程序以阻止它的所有子命令，或只阻止不应运行的子命令。"$json$::jsonb),
  ('hi', 'site.perm.catalog.hint', $json$"किसी प्रोग्राम को चिह्नित करें ताकि उसके सभी सबकमांड, या केवल वे सबकमांड अवरुद्ध हों जो नहीं चलने चाहिए।"$json$::jsonb),
  ('ar', 'site.perm.catalog.hint', $json$"حدّد برنامجًا لحظر كل أوامره الفرعية، أو الأوامر الفرعية التي يجب ألا تعمل فقط."$json$::jsonb),
  ('fr', 'site.perm.catalog.hint', $json$"Cochez un programme pour bloquer tous ses sous-commandes, ou seulement celles qui ne doivent pas s'exécuter."$json$::jsonb),
  ('ru', 'site.perm.catalog.hint', $json$"Отметьте программу, чтобы заблокировать все её подкоманды, или только те подкоманды, которые не должны выполняться."$json$::jsonb),
  ('ja', 'site.perm.catalog.hint', $json$"プログラムにチェックを入れるとそのすべてのサブコマンドを、個別に入れると実行してはならないサブコマンドだけをブロックします。"$json$::jsonb),
  ('de', 'site.perm.catalog.hint', $json$"Markieren Sie ein Programm, um alle seine Unterbefehle zu blockieren, oder nur die Unterbefehle, die nicht laufen dürfen."$json$::jsonb),
  ('pt-BR', 'site.perm.inherited', $json$"bloqueado pela organização"$json$::jsonb),
  ('en', 'site.perm.inherited', $json$"blocked by the organization"$json$::jsonb),
  ('es', 'site.perm.inherited', $json$"bloqueado por la organización"$json$::jsonb),
  ('zh-CN', 'site.perm.inherited', $json$"被组织阻止"$json$::jsonb),
  ('hi', 'site.perm.inherited', $json$"संगठन द्वारा अवरुद्ध"$json$::jsonb),
  ('ar', 'site.perm.inherited', $json$"محظور من المؤسسة"$json$::jsonb),
  ('fr', 'site.perm.inherited', $json$"bloqué par l'organisation"$json$::jsonb),
  ('ru', 'site.perm.inherited', $json$"заблокировано организацией"$json$::jsonb),
  ('ja', 'site.perm.inherited', $json$"組織がブロック"$json$::jsonb),
  ('de', 'site.perm.inherited', $json$"von der Organisation blockiert"$json$::jsonb),
  ('pt-BR', 'site.perm.all', $json$"todos os subcomandos"$json$::jsonb),
  ('en', 'site.perm.all', $json$"all subcommands"$json$::jsonb),
  ('es', 'site.perm.all', $json$"todos los subcomandos"$json$::jsonb),
  ('zh-CN', 'site.perm.all', $json$"所有子命令"$json$::jsonb),
  ('hi', 'site.perm.all', $json$"सभी सबकमांड"$json$::jsonb),
  ('ar', 'site.perm.all', $json$"كل الأوامر الفرعية"$json$::jsonb),
  ('fr', 'site.perm.all', $json$"toutes les sous-commandes"$json$::jsonb),
  ('ru', 'site.perm.all', $json$"все подкоманды"$json$::jsonb),
  ('ja', 'site.perm.all', $json$"すべてのサブコマンド"$json$::jsonb),
  ('de', 'site.perm.all', $json$"alle Unterbefehle"$json$::jsonb),
  ('pt-BR', 'site.perm.other', $json$"Outros comandos"$json$::jsonb),
  ('en', 'site.perm.other', $json$"Other commands"$json$::jsonb),
  ('es', 'site.perm.other', $json$"Otros comandos"$json$::jsonb),
  ('zh-CN', 'site.perm.other', $json$"其他命令"$json$::jsonb),
  ('hi', 'site.perm.other', $json$"अन्य कमांड"$json$::jsonb),
  ('ar', 'site.perm.other', $json$"أوامر أخرى"$json$::jsonb),
  ('fr', 'site.perm.other', $json$"Autres commandes"$json$::jsonb),
  ('ru', 'site.perm.other', $json$"Другие команды"$json$::jsonb),
  ('ja', 'site.perm.other', $json$"その他のコマンド"$json$::jsonb),
  ('de', 'site.perm.other', $json$"Weitere Befehle"$json$::jsonb),
  ('pt-BR', 'site.perm.other.label', $json$"Um comando por linha"$json$::jsonb),
  ('en', 'site.perm.other.label', $json$"One command per line"$json$::jsonb),
  ('es', 'site.perm.other.label', $json$"Un comando por línea"$json$::jsonb),
  ('zh-CN', 'site.perm.other.label', $json$"每行一个命令"$json$::jsonb),
  ('hi', 'site.perm.other.label', $json$"प्रति पंक्ति एक कमांड"$json$::jsonb),
  ('ar', 'site.perm.other.label', $json$"أمر واحد في كل سطر"$json$::jsonb),
  ('fr', 'site.perm.other.label', $json$"Une commande par ligne"$json$::jsonb),
  ('ru', 'site.perm.other.label', $json$"Одна команда в строке"$json$::jsonb),
  ('ja', 'site.perm.other.label', $json$"1行に1コマンド"$json$::jsonb),
  ('de', 'site.perm.other.label', $json$"Ein Befehl pro Zeile"$json$::jsonb),
  ('pt-BR', 'site.perm.other.hint', $json$"O programa e até duas palavras a mais, como terraform destroy. Bloqueia esse comando e tudo que vem depois dele."$json$::jsonb),
  ('en', 'site.perm.other.hint', $json$"The program and up to two more words, like terraform destroy. It blocks that command and anything that follows it."$json$::jsonb),
  ('es', 'site.perm.other.hint', $json$"El programa y hasta dos palabras más, como terraform destroy. Bloquea ese comando y todo lo que le sigue."$json$::jsonb),
  ('zh-CN', 'site.perm.other.hint', $json$"程序名加最多两个词，例如 terraform destroy。会阻止该命令及其后面的所有内容。"$json$::jsonb),
  ('hi', 'site.perm.other.hint', $json$"प्रोग्राम और अधिकतम दो और शब्द, जैसे terraform destroy। यह उस कमांड और उसके बाद आने वाली हर चीज़ को अवरुद्ध करता है।"$json$::jsonb),
  ('ar', 'site.perm.other.hint', $json$"البرنامج وحتى كلمتين إضافيتين، مثل terraform destroy. يحظر هذا الأمر وكل ما يليه."$json$::jsonb),
  ('fr', 'site.perm.other.hint', $json$"Le programme et jusqu'à deux mots de plus, comme terraform destroy. Cela bloque cette commande et tout ce qui la suit."$json$::jsonb),
  ('ru', 'site.perm.other.hint', $json$"Программа и до двух дополнительных слов, например terraform destroy. Блокирует эту команду и всё, что идёт после неё."$json$::jsonb),
  ('ja', 'site.perm.other.hint', $json$"プログラム名とその後ろ最大2語（例: terraform destroy）。そのコマンドと、それに続くものすべてをブロックします。"$json$::jsonb),
  ('de', 'site.perm.other.hint', $json$"Das Programm und bis zu zwei weitere Wörter, etwa terraform destroy. Blockiert diesen Befehl und alles, was ihm folgt."$json$::jsonb),
  ('pt-BR', 'site.perm.invalid', $json$"Use até três palavras por linha, com letras, dígitos e . _ + - @ / : (no máximo 200 linhas)."$json$::jsonb),
  ('en', 'site.perm.invalid', $json$"Use up to three words per line, with letters, digits and . _ + - @ / : (at most 200 lines)."$json$::jsonb),
  ('es', 'site.perm.invalid', $json$"Usa hasta tres palabras por línea, con letras, dígitos y . _ + - @ / : (como máximo 200 líneas)."$json$::jsonb),
  ('zh-CN', 'site.perm.invalid', $json$"每行最多三个词，可用字母、数字和 . _ + - @ / :（最多 200 行）。"$json$::jsonb),
  ('hi', 'site.perm.invalid', $json$"प्रति पंक्ति अधिकतम तीन शब्द, अक्षरों, अंकों और . _ + - @ / : के साथ (अधिकतम 200 पंक्तियाँ)।"$json$::jsonb),
  ('ar', 'site.perm.invalid', $json$"استخدم حتى ثلاث كلمات في كل سطر، بحروف وأرقام و . _ + - @ / : (200 سطر على الأكثر)."$json$::jsonb),
  ('fr', 'site.perm.invalid', $json$"Utilisez jusqu'à trois mots par ligne, avec des lettres, des chiffres et . _ + - @ / : (200 lignes au plus)."$json$::jsonb),
  ('ru', 'site.perm.invalid', $json$"Не более трёх слов в строке: буквы, цифры и . _ + - @ / : (не более 200 строк)."$json$::jsonb),
  ('ja', 'site.perm.invalid', $json$"1行に最大3語、英数字と . _ + - @ / : が使えます（最大200行）。"$json$::jsonb),
  ('de', 'site.perm.invalid', $json$"Verwenden Sie bis zu drei Wörter pro Zeile, mit Buchstaben, Ziffern und . _ + - @ / : (höchstens 200 Zeilen)."$json$::jsonb),
  ('pt-BR', 'site.perm.save', $json$"Salvar permissões"$json$::jsonb),
  ('en', 'site.perm.save', $json$"Save permissions"$json$::jsonb),
  ('es', 'site.perm.save', $json$"Guardar permisos"$json$::jsonb),
  ('zh-CN', 'site.perm.save', $json$"保存权限"$json$::jsonb),
  ('hi', 'site.perm.save', $json$"अनुमतियाँ सहेजें"$json$::jsonb),
  ('ar', 'site.perm.save', $json$"حفظ الأذونات"$json$::jsonb),
  ('fr', 'site.perm.save', $json$"Enregistrer les autorisations"$json$::jsonb),
  ('ru', 'site.perm.save', $json$"Сохранить разрешения"$json$::jsonb),
  ('ja', 'site.perm.save', $json$"許可を保存"$json$::jsonb),
  ('de', 'site.perm.save', $json$"Berechtigungen speichern"$json$::jsonb),
  ('pt-BR', 'site.perm.saved', $json$"Permissões salvas"$json$::jsonb),
  ('en', 'site.perm.saved', $json$"Permissions saved"$json$::jsonb),
  ('es', 'site.perm.saved', $json$"Permisos guardados"$json$::jsonb),
  ('zh-CN', 'site.perm.saved', $json$"权限已保存"$json$::jsonb),
  ('hi', 'site.perm.saved', $json$"अनुमतियाँ सहेजी गईं"$json$::jsonb),
  ('ar', 'site.perm.saved', $json$"تم حفظ الأذونات"$json$::jsonb),
  ('fr', 'site.perm.saved', $json$"Autorisations enregistrées"$json$::jsonb),
  ('ru', 'site.perm.saved', $json$"Разрешения сохранены"$json$::jsonb),
  ('ja', 'site.perm.saved', $json$"許可を保存しました"$json$::jsonb),
  ('de', 'site.perm.saved', $json$"Berechtigungen gespeichert"$json$::jsonb),
  ('pt-BR', 'site.perm.count', $json$"Regras bloqueadas: {count}"$json$::jsonb),
  ('en', 'site.perm.count', $json$"Blocked rules: {count}"$json$::jsonb),
  ('es', 'site.perm.count', $json$"Reglas bloqueadas: {count}"$json$::jsonb),
  ('zh-CN', 'site.perm.count', $json$"已阻止的规则：{count}"$json$::jsonb),
  ('hi', 'site.perm.count', $json$"अवरुद्ध नियम: {count}"$json$::jsonb),
  ('ar', 'site.perm.count', $json$"القواعد المحظورة: {count}"$json$::jsonb),
  ('fr', 'site.perm.count', $json$"Règles bloquées : {count}"$json$::jsonb),
  ('ru', 'site.perm.count', $json$"Заблокированных правил: {count}"$json$::jsonb),
  ('ja', 'site.perm.count', $json$"ブロック中のルール: {count}"$json$::jsonb),
  ('de', 'site.perm.count', $json$"Blockierte Regeln: {count}"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
