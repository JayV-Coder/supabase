-- O chat da organização: um projeto cuja pasta, neste computador, é a pasta da
-- organização, onde ficam os clones dos repositórios dela. O agente trabalha
-- com essa pasta como raiz e enxerga todos os repositórios de uma vez.
--
-- A pasta não tem remote próprio, então o vínculo com a organização não sai
-- de `repo_keys`: o projeto o diz em `org_id`. Sem chave estrangeira de
-- propósito: a organização excluída antes da subida não pode travar a fila de
-- sync do app. Quem lê o vínculo confere que o dono do projeto é membro.

alter table public.projects add column org_id uuid;

-- A organização do projeto: a que ele diz em `org_id`, se o dono for membro
-- dela; senão, a do primeiro remote que casa (como antes).
create or replace function public.project_organization(project text) returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (
      select pr.org_id
      from public.projects pr
      join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
      where pr.id = project and pr.row_deleted_at is null
        and (pr.user_id = auth.uid() or public.org_role(pr.org_id) is not null)
    ),
    (
      select r.org_id
      from public.projects pr
      cross join lateral jsonb_array_elements_text(
        case when pr.repo_keys ~ '^\s*\[' then pr.repo_keys::jsonb else '[]'::jsonb end
      ) with ordinality as k(repo_key, position)
      join public.organization_repositories r on r.repo_key = k.repo_key
      join public.organization_members m on m.org_id = r.org_id and m.user_id = pr.user_id
      where pr.id = project and pr.row_deleted_at is null
        and (pr.user_id = auth.uid() or public.org_role(r.org_id) is not null)
      order by k.position, r.created_at
      limit 1
    )
  );
$$;

-- A política de quem pode mexer em qualquer repositório da organização: a da
-- organização junto com a de todos os repositórios dela, pela mais rígida.
-- Nulo quando não há nenhuma. Interna: não confere papel.
create function public.llm_policy_of_organization(org uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  p public.organization_llm_policies;
  found boolean := false;
  agents text[];
  agents_set boolean := false;
  blocked text[] := '{}';
  deny text[] := '{}';
  local_only text[] := '{}';
  safe boolean := false;
  redact boolean := false;
  min_read text := 'allow';
  min_write text := 'allow';
  min_shell text := 'allow';
begin
  for p in
    select * from public.organization_llm_policies x where x.org_id = org
    order by x.repository_id nulls first, x.id
  loop
    found := true;
    -- Nulo é "todos": a interseção só corta quando as duas listam.
    if p.agents is not null then
      agents := case when agents_set then array(select a from unnest(agents) a where a = any (p.agents)) else p.agents end;
      agents_set := true;
    end if;
    blocked := public.policy_union(blocked, p.blocked_models);
    deny := public.policy_union(deny, p.deny);
    local_only := public.policy_union(local_only, p.local_only);
    safe := safe or p.safe_agents;
    redact := redact or p.redact_secrets;
    min_read := public.policy_strictest(min_read, p.min_read);
    min_write := public.policy_strictest(min_write, p.min_write);
    min_shell := public.policy_strictest(min_shell, p.min_shell);
  end loop;
  if not found then return null; end if;
  return jsonb_build_object(
    'agents', case when agents_set then to_jsonb(agents) end,
    'blocked_models', to_jsonb(blocked),
    'deny', to_jsonb(deny),
    'local_only', to_jsonb(local_only),
    'safe_agents', safe,
    'redact_secrets', redact,
    'min_read', min_read,
    'min_write', min_write,
    'min_shell', min_shell
  );
end;
$$;

-- Os projetos de quem chama que rodam sob uma política, com a efetiva. O
-- projeto da organização roda sob a de todos os repositórios dela.
create or replace function public.my_project_policies()
returns table (project_id text, org_id uuid, org_slug text, policy jsonb)
language sql stable security definer set search_path = '' as $$
  select linked.project_id, linked.org_id, o.slug, linked.policy
  from (
    select pr.id as project_id, pr.org_id, public.llm_policy_of_organization(pr.org_id) as policy
    from public.projects pr
    join public.organization_members m on m.org_id = pr.org_id and m.user_id = pr.user_id
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
    union all
    select pr.id as project_id, r.org_id, public.llm_policy_of(r.org_id, r.id) as policy
    from public.projects pr
    join public.organization_repositories r on r.id = public.project_repository(pr.id)
    where pr.user_id = auth.uid() and pr.row_deleted_at is null
      and not exists (select 1 from public.organization_members m where m.org_id = pr.org_id and m.user_id = pr.user_id)
  ) linked
  join public.organizations o on o.id = linked.org_id
  where linked.policy is not null;
$$;

revoke execute on function public.llm_policy_of_organization(uuid) from public, anon, authenticated;

-- O botão e a janela do chat da organização, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'orgChat.open', $json$"Chat da organização"$json$::jsonb),
  ('pt-BR', 'orgChat.title', $json$"Trabalhe em vários repositórios ao mesmo tempo"$json$::jsonb),
  ('pt-BR', 'orgChat.description', $json$"O chat trabalha na pasta de {org} neste computador e enxerga todos os clones que estão dentro dela. Vale a política de LLM da organização e a de todos os repositórios dela, pela mais rígida."$json$::jsonb),
  ('pt-BR', 'orgChat.inside', $json$"Neste chat"$json$::jsonb),
  ('pt-BR', 'orgChat.elsewhere', $json$"De fora: clonado fora desta pasta"$json$::jsonb),
  ('pt-BR', 'orgChat.missing', $json$"De fora: não está neste computador"$json$::jsonb),
  ('pt-BR', 'orgChat.none', $json$"Nenhum repositório desta organização está clonado dentro desta pasta ainda. Clone-os na aba Repositórios."$json$::jsonb),
  ('pt-BR', 'orgChat.start', $json$"Abrir chat"$json$::jsonb),
  ('en', 'orgChat.open', $json$"Organization chat"$json$::jsonb),
  ('en', 'orgChat.title', $json$"Work on several repositories at once"$json$::jsonb),
  ('en', 'orgChat.description', $json$"The chat works in the folder of {org} on this computer and sees every clone inside it. The LLM policy of the organization and of all its repositories applies, whichever is stricter."$json$::jsonb),
  ('en', 'orgChat.inside', $json$"In this chat"$json$::jsonb),
  ('en', 'orgChat.elsewhere', $json$"Left out: cloned outside this folder"$json$::jsonb),
  ('en', 'orgChat.missing', $json$"Left out: not on this computer"$json$::jsonb),
  ('en', 'orgChat.none', $json$"No repository of this organization is cloned inside this folder yet. Clone them in the Repositories tab."$json$::jsonb),
  ('en', 'orgChat.start', $json$"Open chat"$json$::jsonb),
  ('es', 'orgChat.open', $json$"Chat de la organización"$json$::jsonb),
  ('es', 'orgChat.title', $json$"Trabaja en varios repositorios a la vez"$json$::jsonb),
  ('es', 'orgChat.description', $json$"El chat trabaja en la carpeta de {org} en este equipo y ve todos los clones que hay dentro. Se aplica la política de LLM de la organización y la de todos sus repositorios, la más estricta."$json$::jsonb),
  ('es', 'orgChat.inside', $json$"En este chat"$json$::jsonb),
  ('es', 'orgChat.elsewhere', $json$"Fuera: clonado fuera de esta carpeta"$json$::jsonb),
  ('es', 'orgChat.missing', $json$"Fuera: no está en este equipo"$json$::jsonb),
  ('es', 'orgChat.none', $json$"Ningún repositorio de esta organización está clonado dentro de esta carpeta todavía. Clónalos en la pestaña Repositorios."$json$::jsonb),
  ('es', 'orgChat.start', $json$"Abrir chat"$json$::jsonb),
  ('zh-CN', 'orgChat.open', $json$"组织聊天"$json$::jsonb),
  ('zh-CN', 'orgChat.title', $json$"同时处理多个仓库"$json$::jsonb),
  ('zh-CN', 'orgChat.description', $json$"此聊天在本机 {org} 的文件夹中工作，可以看到其中的所有克隆。适用组织及其所有仓库的 LLM 策略，以最严格者为准。"$json$::jsonb),
  ('zh-CN', 'orgChat.inside', $json$"在此聊天中"$json$::jsonb),
  ('zh-CN', 'orgChat.elsewhere', $json$"未包含：克隆在此文件夹之外"$json$::jsonb),
  ('zh-CN', 'orgChat.missing', $json$"未包含：不在此计算机上"$json$::jsonb),
  ('zh-CN', 'orgChat.none', $json$"此组织的仓库尚未克隆到此文件夹中。请在“仓库”标签页中克隆。"$json$::jsonb),
  ('zh-CN', 'orgChat.start', $json$"打开聊天"$json$::jsonb),
  ('hi', 'orgChat.open', $json$"संगठन चैट"$json$::jsonb),
  ('hi', 'orgChat.title', $json$"एक साथ कई रिपॉज़िटरी पर काम करें"$json$::jsonb),
  ('hi', 'orgChat.description', $json$"यह चैट इस कंप्यूटर पर {org} के फ़ोल्डर में काम करता है और उसके अंदर के सभी क्लोन देखता है। संगठन और उसकी सभी रिपॉज़िटरी की LLM नीति लागू होती है, जो सबसे सख़्त हो।"$json$::jsonb),
  ('hi', 'orgChat.inside', $json$"इस चैट में"$json$::jsonb),
  ('hi', 'orgChat.elsewhere', $json$"बाहर: इस फ़ोल्डर के बाहर क्लोन किया गया"$json$::jsonb),
  ('hi', 'orgChat.missing', $json$"बाहर: इस कंप्यूटर पर नहीं है"$json$::jsonb),
  ('hi', 'orgChat.none', $json$"इस संगठन की कोई रिपॉज़िटरी अभी इस फ़ोल्डर में क्लोन नहीं है। उन्हें रिपॉज़िटरी टैब में क्लोन करें।"$json$::jsonb),
  ('hi', 'orgChat.start', $json$"चैट खोलें"$json$::jsonb),
  ('ar', 'orgChat.open', $json$"دردشة المؤسسة"$json$::jsonb),
  ('ar', 'orgChat.title', $json$"اعمل على عدة مستودعات في وقت واحد"$json$::jsonb),
  ('ar', 'orgChat.description', $json$"تعمل الدردشة في مجلد {org} على هذا الحاسوب وترى كل النسخ الموجودة داخله. تُطبَّق سياسة LLM الخاصة بالمؤسسة وبكل مستودعاتها، الأشد منها."$json$::jsonb),
  ('ar', 'orgChat.inside', $json$"في هذه الدردشة"$json$::jsonb),
  ('ar', 'orgChat.elsewhere', $json$"مستبعد: مستنسخ خارج هذا المجلد"$json$::jsonb),
  ('ar', 'orgChat.missing', $json$"مستبعد: غير موجود على هذا الحاسوب"$json$::jsonb),
  ('ar', 'orgChat.none', $json$"لا يوجد بعد أي مستودع لهذه المؤسسة مستنسخ داخل هذا المجلد. استنسخها من تبويب المستودعات."$json$::jsonb),
  ('ar', 'orgChat.start', $json$"فتح الدردشة"$json$::jsonb),
  ('fr', 'orgChat.open', $json$"Chat de l’organisation"$json$::jsonb),
  ('fr', 'orgChat.title', $json$"Travaillez sur plusieurs dépôts à la fois"$json$::jsonb),
  ('fr', 'orgChat.description', $json$"Le chat travaille dans le dossier de {org} sur cet ordinateur et voit tous les clones qu’il contient. La politique LLM de l’organisation et de tous ses dépôts s’applique, la plus stricte l’emportant."$json$::jsonb),
  ('fr', 'orgChat.inside', $json$"Dans ce chat"$json$::jsonb),
  ('fr', 'orgChat.elsewhere', $json$"Exclu : cloné hors de ce dossier"$json$::jsonb),
  ('fr', 'orgChat.missing', $json$"Exclu : absent de cet ordinateur"$json$::jsonb),
  ('fr', 'orgChat.none', $json$"Aucun dépôt de cette organisation n’est encore cloné dans ce dossier. Clonez-les dans l’onglet Dépôts."$json$::jsonb),
  ('fr', 'orgChat.start', $json$"Ouvrir le chat"$json$::jsonb),
  ('ru', 'orgChat.open', $json$"Чат организации"$json$::jsonb),
  ('ru', 'orgChat.title', $json$"Работайте с несколькими репозиториями сразу"$json$::jsonb),
  ('ru', 'orgChat.description', $json$"Чат работает в папке {org} на этом компьютере и видит все клоны внутри неё. Действует политика LLM организации и всех её репозиториев, самая строгая из них."$json$::jsonb),
  ('ru', 'orgChat.inside', $json$"В этом чате"$json$::jsonb),
  ('ru', 'orgChat.elsewhere', $json$"Не входит: клонирован вне этой папки"$json$::jsonb),
  ('ru', 'orgChat.missing', $json$"Не входит: нет на этом компьютере"$json$::jsonb),
  ('ru', 'orgChat.none', $json$"Ни один репозиторий этой организации ещё не клонирован в эту папку. Клонируйте их на вкладке «Репозитории»."$json$::jsonb),
  ('ru', 'orgChat.start', $json$"Открыть чат"$json$::jsonb),
  ('ja', 'orgChat.open', $json$"組織チャット"$json$::jsonb),
  ('ja', 'orgChat.title', $json$"複数のリポジトリを同時に扱う"$json$::jsonb),
  ('ja', 'orgChat.description', $json$"このチャットはこのコンピューター上の {org} のフォルダーで動き、その中のすべてのクローンを参照します。組織とそのすべてのリポジトリの LLM ポリシーのうち、最も厳しいものが適用されます。"$json$::jsonb),
  ('ja', 'orgChat.inside', $json$"このチャットに含む"$json$::jsonb),
  ('ja', 'orgChat.elsewhere', $json$"対象外：このフォルダーの外にクローン"$json$::jsonb),
  ('ja', 'orgChat.missing', $json$"対象外：このコンピューターにない"$json$::jsonb),
  ('ja', 'orgChat.none', $json$"この組織のリポジトリはまだこのフォルダーにクローンされていません。「リポジトリ」タブでクローンしてください。"$json$::jsonb),
  ('ja', 'orgChat.start', $json$"チャットを開く"$json$::jsonb),
  ('de', 'orgChat.open', $json$"Organisations-Chat"$json$::jsonb),
  ('de', 'orgChat.title', $json$"An mehreren Repositorys gleichzeitig arbeiten"$json$::jsonb),
  ('de', 'orgChat.description', $json$"Der Chat arbeitet im Ordner von {org} auf diesem Computer und sieht alle Klone darin. Es gilt die LLM-Richtlinie der Organisation und aller ihrer Repositorys, jeweils die strengste."$json$::jsonb),
  ('de', 'orgChat.inside', $json$"In diesem Chat"$json$::jsonb),
  ('de', 'orgChat.elsewhere', $json$"Nicht dabei: außerhalb dieses Ordners geklont"$json$::jsonb),
  ('de', 'orgChat.missing', $json$"Nicht dabei: nicht auf diesem Computer"$json$::jsonb),
  ('de', 'orgChat.none', $json$"Noch kein Repository dieser Organisation ist in diesem Ordner geklont. Klone sie im Tab Repositorys."$json$::jsonb),
  ('de', 'orgChat.start', $json$"Chat öffnen"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
