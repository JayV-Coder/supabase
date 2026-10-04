-- v0.52.0: o que cada agente pode fazer além de ler e editar o projeto —
-- buscar na web, abrir páginas, rodar comandos, as ferramentas do GitHub —
-- e a organização bloqueando cada um nos projetos dela.
--
-- O app roda o agente sem terminal, e ninguém responde ao pedido de
-- aprovação dele: o que não vem liberado na linha de comando é negado. Os
-- mecanismos ficam em Configurações › Agentes, por agente; a política de LLM
-- ganha `blocked_mechanisms` (`agente/mecanismo`), que o app tira das
-- configurações de quem usa nos projetos da organização.

-- Até 50 mecanismos no formato `agente/mecanismo`.
create function public.policy_mechanisms_ok(mechanisms text[]) returns boolean language sql immutable set search_path = '' as $$
  select cardinality(mechanisms) <= 50
    and not exists (select 1 from unnest(mechanisms) m where m is null or m !~ '^(claude|codex|copilot|cursor)/[A-Za-z]{1,40}$');
$$;
revoke execute on function public.policy_mechanisms_ok(text[]) from public, anon, authenticated;

alter table public.organization_llm_policies
  add column blocked_mechanisms text[] not null default '{}' check (public.policy_mechanisms_ok(blocked_mechanisms));

create or replace function public.set_llm_policy(org uuid, repository uuid, policy jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  agents text[];
begin
  perform public.org_require(org, array['owner', 'maintainer']);
  if repository is not null and not exists (select 1 from public.organization_repositories where id = repository and org_id = org) then
    raise exception 'policy.repository';
  end if;
  if jsonb_typeof(policy) is distinct from 'object' then raise exception 'policy.invalid'; end if;
  if coalesce(jsonb_typeof(policy->'agents'), 'null') <> 'null' then
    -- Na ordem do app, para a mesma escolha gravar sempre igual.
    agents := array(select a from unnest(array['claude', 'codex', 'copilot', 'cursor']) a where a = any (public.policy_list(policy->'agents')));
    if cardinality(agents) <> cardinality(public.policy_list(policy->'agents')) then raise exception 'policy.invalid'; end if;
  end if;
  delete from public.organization_llm_policies p where p.org_id = org and p.repository_id is not distinct from repository;
  begin
    insert into public.organization_llm_policies
      (org_id, repository_id, agents, blocked_models, blocked_mechanisms, deny, local_only, safe_agents, redact_secrets, min_read, min_write, min_shell, updated_by)
    values (
      org, repository, agents,
      public.policy_list(policy->'blocked_models'), public.policy_list(policy->'blocked_mechanisms'),
      public.policy_list(policy->'deny'), public.policy_list(policy->'local_only'),
      coalesce((policy->>'safe_agents')::boolean, false), coalesce((policy->>'redact_secrets')::boolean, false),
      coalesce(policy->>'min_read', 'allow'), coalesce(policy->>'min_write', 'allow'), coalesce(policy->>'min_shell', 'allow'),
      auth.uid()
    );
  exception
    when check_violation or invalid_text_representation then raise exception 'policy.invalid';
  end;
end;
$$;

-- A da organização junto com a do repositório: os mecanismos pela união.
create or replace function public.llm_policy_of(org uuid, repository uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  o public.organization_llm_policies;
  r public.organization_llm_policies;
begin
  select * into o from public.organization_llm_policies p where p.org_id = org and p.repository_id is null;
  if repository is not null then
    select * into r from public.organization_llm_policies p where p.org_id = org and p.repository_id = repository;
  end if;
  if o.id is null and r.id is null then return null; end if;
  return jsonb_build_object(
    -- Nulo é "todos": a interseção só corta quando as duas listam.
    'agents', case
      when o.agents is null then to_jsonb(r.agents)
      when r.agents is null then to_jsonb(o.agents)
      else to_jsonb(array(select a from unnest(o.agents) a where a = any (r.agents)))
    end,
    'blocked_models', to_jsonb(public.policy_union(o.blocked_models, r.blocked_models)),
    'blocked_mechanisms', to_jsonb(public.policy_union(o.blocked_mechanisms, r.blocked_mechanisms)),
    'deny', to_jsonb(public.policy_union(o.deny, r.deny)),
    'local_only', to_jsonb(public.policy_union(o.local_only, r.local_only)),
    'safe_agents', coalesce(o.safe_agents, false) or coalesce(r.safe_agents, false),
    'redact_secrets', coalesce(o.redact_secrets, false) or coalesce(r.redact_secrets, false),
    'min_read', public.policy_strictest(o.min_read, r.min_read),
    'min_write', public.policy_strictest(o.min_write, r.min_write),
    'min_shell', public.policy_strictest(o.min_shell, r.min_shell)
  );
end;
$$;

-- A da organização junto com a de todos os repositórios dela.
create or replace function public.llm_policy_of_organization(org uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  p public.organization_llm_policies;
  found boolean := false;
  agents text[];
  agents_set boolean := false;
  blocked text[] := '{}';
  mechanisms text[] := '{}';
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
    mechanisms := public.policy_union(mechanisms, p.blocked_mechanisms);
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
    'blocked_mechanisms', to_jsonb(mechanisms),
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

-- A junção de duas políticas efetivas (projeto em mais de uma organização):
-- os mecanismos bloqueados pela união, como os modelos.
create or replace function public.policy_merge(a jsonb, b jsonb) returns jsonb language sql immutable set search_path = '' as $$
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
      'blocked_mechanisms', to_jsonb(public.policy_union(
        array(select jsonb_array_elements_text(coalesce(a->'blocked_mechanisms', '[]'))),
        array(select jsonb_array_elements_text(coalesce(b->'blocked_mechanisms', '[]'))))),
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

-- Os textos da v0.52.0, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'chat.thoughts.more', $json${"one":"+ {count} mensagem anterior","other":"+ {count} mensagens anteriores"}$json$::jsonb),
  ('pt-BR', 'chat.thoughts.less', $json$"mostrar só a mais recente"$json$::jsonb),
  ('pt-BR', 'agent.mechanisms', $json$"O que o agente pode fazer"$json$::jsonb),
  ('pt-BR', 'agent.mechanisms.hint', $json$"O JayV roda o agente sem terminal, e ninguém responde aos pedidos de aprovação dele: o que não estiver ligado aqui é negado. Só aparece o que a linha de comando deste agente sabe ligar."$json$::jsonb),
  ('pt-BR', 'agent.mechanisms.blocked', $json$"Bloqueado por {orgs} nos projetos dela."$json$::jsonb),
  ('pt-BR', 'mechanism.webSearch', $json$"Buscar na web"$json$::jsonb),
  ('pt-BR', 'mechanism.webFetch', $json$"Abrir páginas da web"$json$::jsonb),
  ('pt-BR', 'mechanism.shell', $json$"Rodar comandos sem perguntar"$json$::jsonb),
  ('pt-BR', 'mechanism.githubTools', $json$"Todas as ferramentas do GitHub"$json$::jsonb),
  ('pt-BR', 'mechanism.webSearch.hint.claude', $json$"Deixa o Claude Code usar o WebSearch sem perguntar."$json$::jsonb),
  ('pt-BR', 'mechanism.webFetch.hint.claude', $json$"Deixa o Claude Code ler qualquer página com o WebFetch sem perguntar."$json$::jsonb),
  ('pt-BR', 'mechanism.shell.hint.claude', $json$"Deixa o Claude Code rodar comandos no terminal (Bash) sem perguntar. Não vale no modo Planejamento."$json$::jsonb),
  ('pt-BR', 'mechanism.webSearch.hint.codex', $json$"Busca na web ao vivo (web_search = \"live\"). Desligado, a busca fica desligada de vez."$json$::jsonb),
  ('pt-BR', 'mechanism.webFetch.hint.copilot', $json$"Deixa o Copilot acessar qualquer URL sem perguntar (--allow-all-urls)."$json$::jsonb),
  ('pt-BR', 'mechanism.shell.hint.copilot', $json$"Deixa o Copilot rodar comandos no shell sem perguntar. As ferramentas bloqueadas continuam valendo. Não vale no modo Planejamento."$json$::jsonb),
  ('pt-BR', 'mechanism.githubTools.hint.copilot', $json$"Liga todas as ferramentas do servidor MCP do GitHub, e não só o conjunto padrão."$json$::jsonb),
  ('pt-BR', 'cursor.mechanisms.none', $json$"O Cursor não tem flag de linha de comando para ligar ou desligar a busca na web ou outras ferramentas: ele segue as configurações do próprio Cursor."$json$::jsonb),
  ('pt-BR', 'settings.field.claude.mechanisms', $json$"os mecanismos do Claude Code"$json$::jsonb),
  ('pt-BR', 'settings.field.codex.mechanisms', $json$"os mecanismos do Codex"$json$::jsonb),
  ('pt-BR', 'settings.field.copilot.mechanisms', $json$"os mecanismos do Copilot"$json$::jsonb),
  ('pt-BR', 'policy.mechanisms', $json$"Mecanismos bloqueados"$json$::jsonb),
  ('pt-BR', 'policy.mechanisms.hint', $json$"Os marcados ficam desligados nos projetos desta organização, mesmo para quem os ligou em Configurações › Agentes."$json$::jsonb),
  ('pt-BR', 'policy.safe.hint', $json$"Nada de bypassPermissions no Claude Code, danger-full-access no Codex, todas as ferramentas no Copilot nem --force no Cursor. O Claude Code e o Copilot também deixam de rodar comandos sem perguntar."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.unsavedAbove.title', $json$"\"Alterações não salvas\" não empurra mais os botões"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.unsavedAbove.detail', $json$"Em Configurações, o aviso aparecia ao lado dos botões e os empurrava para baixo. Agora ele fica em cima deles, num espaço que está sempre lá."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.thoughtsCollapsed.title', $json$"O que o agente disse no caminho fica recolhido"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.thoughtsCollapsed.detail', $json$"No balão do JayV, só a mensagem mais recente que o agente escreveu enquanto trabalhava aparece acima da resposta. Um botão abre as anteriores."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.agentMechanisms.title', $json$"Busca na web e outras ferramentas por agente"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.agentMechanisms.detail', $json$"Configurações › Agentes ganhou a lista \"O que o agente pode fazer\" para Claude Code, Codex e Copilot: buscar na web, abrir páginas, rodar comandos e ferramentas do GitHub, cada um só onde a linha de comando do agente suporta. A busca na web agora vem ligada. A organização pode bloquear cada um na política de LLM."$json$::jsonb),
  ('en', 'chat.thoughts.more', $json${"one":"+ {count} earlier message","other":"+ {count} earlier messages"}$json$::jsonb),
  ('en', 'chat.thoughts.less', $json$"show only the latest"$json$::jsonb),
  ('en', 'agent.mechanisms', $json$"What the agent can do"$json$::jsonb),
  ('en', 'agent.mechanisms.hint', $json$"JayV runs the agent without a terminal, so nobody answers its approval prompts: whatever is not turned on here is denied. Only what this agent's command line can turn on is listed."$json$::jsonb),
  ('en', 'agent.mechanisms.blocked', $json$"Blocked by {orgs} in their projects."$json$::jsonb),
  ('en', 'mechanism.webSearch', $json$"Search the web"$json$::jsonb),
  ('en', 'mechanism.webFetch', $json$"Open web pages"$json$::jsonb),
  ('en', 'mechanism.shell', $json$"Run commands without asking"$json$::jsonb),
  ('en', 'mechanism.githubTools', $json$"All GitHub tools"$json$::jsonb),
  ('en', 'mechanism.webSearch.hint.claude', $json$"Lets Claude Code use WebSearch without asking."$json$::jsonb),
  ('en', 'mechanism.webFetch.hint.claude', $json$"Lets Claude Code read any page with WebFetch without asking."$json$::jsonb),
  ('en', 'mechanism.shell.hint.claude', $json$"Lets Claude Code run terminal commands (Bash) without asking. Not used in Plan mode."$json$::jsonb),
  ('en', 'mechanism.webSearch.hint.codex', $json$"Live web search (web_search = \"live\"). Off turns search off entirely."$json$::jsonb),
  ('en', 'mechanism.webFetch.hint.copilot', $json$"Lets Copilot access any URL without asking (--allow-all-urls)."$json$::jsonb),
  ('en', 'mechanism.shell.hint.copilot', $json$"Lets Copilot run shell commands without asking. Blocked tools still win. Not used in Plan mode."$json$::jsonb),
  ('en', 'mechanism.githubTools.hint.copilot', $json$"Turns on every tool of the GitHub MCP server instead of the default subset."$json$::jsonb),
  ('en', 'cursor.mechanisms.none', $json$"Cursor has no command-line flag to turn web search or other tools on or off: it follows Cursor's own settings."$json$::jsonb),
  ('en', 'settings.field.claude.mechanisms', $json$"the Claude Code mechanisms"$json$::jsonb),
  ('en', 'settings.field.codex.mechanisms', $json$"the Codex mechanisms"$json$::jsonb),
  ('en', 'settings.field.copilot.mechanisms', $json$"the Copilot mechanisms"$json$::jsonb),
  ('en', 'policy.mechanisms', $json$"Blocked mechanisms"$json$::jsonb),
  ('en', 'policy.mechanisms.hint', $json$"Checked ones stay off in this organization's projects, even for members who turned them on in Settings › Agents."$json$::jsonb),
  ('en', 'policy.safe.hint', $json$"No bypassPermissions in Claude Code, no danger-full-access in Codex, no all-tools access in Copilot and no --force in Cursor. Claude Code and Copilot also stop running commands without asking."$json$::jsonb),
  ('en', 'whatsNew.item.unsavedAbove.title', $json$"\"Unsaved changes\" no longer pushes the buttons"$json$::jsonb),
  ('en', 'whatsNew.item.unsavedAbove.detail', $json$"In Settings, the notice appeared beside the buttons and pushed them down. It now sits above them, in a space that is always there."$json$::jsonb),
  ('en', 'whatsNew.item.thoughtsCollapsed.title', $json$"What the agent said along the way stays collapsed"$json$::jsonb),
  ('en', 'whatsNew.item.thoughtsCollapsed.detail', $json$"In JayV's bubble, only the latest message the agent wrote while working shows above the answer. A button opens the earlier ones."$json$::jsonb),
  ('en', 'whatsNew.item.agentMechanisms.title', $json$"Web search and other tools per agent"$json$::jsonb),
  ('en', 'whatsNew.item.agentMechanisms.detail', $json$"Settings › Agents has a \"What the agent can do\" list for Claude Code, Codex and Copilot: web search, opening pages, running commands and GitHub tools, each only where the agent's command line supports it. Web search now comes on by default. Organizations can block each one in the LLM policy."$json$::jsonb),
  ('es', 'chat.thoughts.more', $json${"one":"+ {count} mensaje anterior","other":"+ {count} mensajes anteriores"}$json$::jsonb),
  ('es', 'chat.thoughts.less', $json$"mostrar solo el más reciente"$json$::jsonb),
  ('es', 'agent.mechanisms', $json$"Lo que el agente puede hacer"$json$::jsonb),
  ('es', 'agent.mechanisms.hint', $json$"JayV ejecuta el agente sin terminal y nadie responde a sus solicitudes de aprobación: lo que no esté activado aquí se deniega. Solo aparece lo que la línea de comandos de este agente sabe activar."$json$::jsonb),
  ('es', 'agent.mechanisms.blocked', $json$"Bloqueado por {orgs} en sus proyectos."$json$::jsonb),
  ('es', 'mechanism.webSearch', $json$"Buscar en la web"$json$::jsonb),
  ('es', 'mechanism.webFetch', $json$"Abrir páginas web"$json$::jsonb),
  ('es', 'mechanism.shell', $json$"Ejecutar comandos sin preguntar"$json$::jsonb),
  ('es', 'mechanism.githubTools', $json$"Todas las herramientas de GitHub"$json$::jsonb),
  ('es', 'mechanism.webSearch.hint.claude', $json$"Permite que Claude Code use WebSearch sin preguntar."$json$::jsonb),
  ('es', 'mechanism.webFetch.hint.claude', $json$"Permite que Claude Code lea cualquier página con WebFetch sin preguntar."$json$::jsonb),
  ('es', 'mechanism.shell.hint.claude', $json$"Permite que Claude Code ejecute comandos de terminal (Bash) sin preguntar. No se usa en el modo Planificación."$json$::jsonb),
  ('es', 'mechanism.webSearch.hint.codex', $json$"Búsqueda web en vivo (web_search = \"live\"). Desactivada, la búsqueda queda apagada por completo."$json$::jsonb),
  ('es', 'mechanism.webFetch.hint.copilot', $json$"Permite que Copilot acceda a cualquier URL sin preguntar (--allow-all-urls)."$json$::jsonb),
  ('es', 'mechanism.shell.hint.copilot', $json$"Permite que Copilot ejecute comandos de shell sin preguntar. Las herramientas bloqueadas siguen valiendo. No se usa en el modo Planificación."$json$::jsonb),
  ('es', 'mechanism.githubTools.hint.copilot', $json$"Activa todas las herramientas del servidor MCP de GitHub en lugar del subconjunto predeterminado."$json$::jsonb),
  ('es', 'cursor.mechanisms.none', $json$"Cursor no tiene una opción de línea de comandos para activar o desactivar la búsqueda web u otras herramientas: sigue la configuración del propio Cursor."$json$::jsonb),
  ('es', 'settings.field.claude.mechanisms', $json$"los mecanismos de Claude Code"$json$::jsonb),
  ('es', 'settings.field.codex.mechanisms', $json$"los mecanismos de Codex"$json$::jsonb),
  ('es', 'settings.field.copilot.mechanisms', $json$"los mecanismos de Copilot"$json$::jsonb),
  ('es', 'policy.mechanisms', $json$"Mecanismos bloqueados"$json$::jsonb),
  ('es', 'policy.mechanisms.hint', $json$"Los marcados quedan desactivados en los proyectos de esta organización, incluso para quien los activó en Configuración › Agentes."$json$::jsonb),
  ('es', 'policy.safe.hint', $json$"Sin bypassPermissions en Claude Code, sin danger-full-access en Codex, sin acceso a todas las herramientas en Copilot y sin --force en Cursor. Claude Code y Copilot también dejan de ejecutar comandos sin preguntar."$json$::jsonb),
  ('es', 'whatsNew.item.unsavedAbove.title', $json$"\"Cambios sin guardar\" ya no empuja los botones"$json$::jsonb),
  ('es', 'whatsNew.item.unsavedAbove.detail', $json$"En Configuración, el aviso aparecía junto a los botones y los empujaba hacia abajo. Ahora está encima de ellos, en un espacio que siempre está ahí."$json$::jsonb),
  ('es', 'whatsNew.item.thoughtsCollapsed.title', $json$"Lo que el agente dijo por el camino queda contraído"$json$::jsonb),
  ('es', 'whatsNew.item.thoughtsCollapsed.detail', $json$"En la burbuja de JayV, solo el mensaje más reciente que el agente escribió mientras trabajaba aparece encima de la respuesta. Un botón abre los anteriores."$json$::jsonb),
  ('es', 'whatsNew.item.agentMechanisms.title', $json$"Búsqueda web y otras herramientas por agente"$json$::jsonb),
  ('es', 'whatsNew.item.agentMechanisms.detail', $json$"Configuración › Agentes tiene la lista \"Lo que el agente puede hacer\" para Claude Code, Codex y Copilot: buscar en la web, abrir páginas, ejecutar comandos y herramientas de GitHub, cada una solo donde la línea de comandos del agente lo admite. La búsqueda web ahora viene activada. Las organizaciones pueden bloquear cada una en la política de LLM."$json$::jsonb),
  ('zh-CN', 'chat.thoughts.more', $json${"other":"+ {count} 条更早的消息"}$json$::jsonb),
  ('zh-CN', 'chat.thoughts.less', $json$"只显示最新的"$json$::jsonb),
  ('zh-CN', 'agent.mechanisms', $json$"代理可以做什么"$json$::jsonb),
  ('zh-CN', 'agent.mechanisms.hint', $json$"JayV 在没有终端的情况下运行代理，没有人回应它的批准请求：这里没有开启的都会被拒绝。只列出该代理命令行能够开启的项目。"$json$::jsonb),
  ('zh-CN', 'agent.mechanisms.blocked', $json$"已被 {orgs} 在其项目中禁用。"$json$::jsonb),
  ('zh-CN', 'mechanism.webSearch', $json$"网络搜索"$json$::jsonb),
  ('zh-CN', 'mechanism.webFetch', $json$"打开网页"$json$::jsonb),
  ('zh-CN', 'mechanism.shell', $json$"无需询问即可运行命令"$json$::jsonb),
  ('zh-CN', 'mechanism.githubTools', $json$"所有 GitHub 工具"$json$::jsonb),
  ('zh-CN', 'mechanism.webSearch.hint.claude', $json$"允许 Claude Code 无需询问即可使用 WebSearch。"$json$::jsonb),
  ('zh-CN', 'mechanism.webFetch.hint.claude', $json$"允许 Claude Code 无需询问即可用 WebFetch 读取任何网页。"$json$::jsonb),
  ('zh-CN', 'mechanism.shell.hint.claude', $json$"允许 Claude Code 无需询问即可运行终端命令 (Bash)。规划模式下不使用。"$json$::jsonb),
  ('zh-CN', 'mechanism.webSearch.hint.codex', $json$"实时网络搜索 (web_search = \"live\")。关闭后搜索完全停用。"$json$::jsonb),
  ('zh-CN', 'mechanism.webFetch.hint.copilot', $json$"允许 Copilot 无需询问即可访问任何 URL (--allow-all-urls)。"$json$::jsonb),
  ('zh-CN', 'mechanism.shell.hint.copilot', $json$"允许 Copilot 无需询问即可运行 shell 命令。被禁用的工具仍然禁用。规划模式下不使用。"$json$::jsonb),
  ('zh-CN', 'mechanism.githubTools.hint.copilot', $json$"开启 GitHub MCP 服务器的全部工具，而不是默认子集。"$json$::jsonb),
  ('zh-CN', 'cursor.mechanisms.none', $json$"Cursor 没有用于开启或关闭网络搜索或其他工具的命令行选项：它遵循 Cursor 自身的设置。"$json$::jsonb),
  ('zh-CN', 'settings.field.claude.mechanisms', $json$"Claude Code 的机制"$json$::jsonb),
  ('zh-CN', 'settings.field.codex.mechanisms', $json$"Codex 的机制"$json$::jsonb),
  ('zh-CN', 'settings.field.copilot.mechanisms', $json$"Copilot 的机制"$json$::jsonb),
  ('zh-CN', 'policy.mechanisms', $json$"禁用的机制"$json$::jsonb),
  ('zh-CN', 'policy.mechanisms.hint', $json$"勾选的项目在此组织的项目中保持关闭，即使成员已在 设置 › 代理 中开启。"$json$::jsonb),
  ('zh-CN', 'policy.safe.hint', $json$"Claude Code 不使用 bypassPermissions，Codex 不使用 danger-full-access，Copilot 不开放全部工具，Cursor 不使用 --force。Claude Code 和 Copilot 也不再无需询问就运行命令。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.unsavedAbove.title', $json$"“未保存的更改”不再把按钮挤下去"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.unsavedAbove.detail', $json$"在设置中，这条提示以前出现在按钮旁边并把按钮挤到下方。现在它位于按钮上方一个始终存在的位置。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.thoughtsCollapsed.title', $json$"代理途中所说的内容保持折叠"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.thoughtsCollapsed.detail', $json$"在 JayV 的气泡中，回答上方只显示代理工作时写下的最新一条消息。点击按钮可展开更早的消息。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.agentMechanisms.title', $json$"按代理设置网络搜索和其他工具"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.agentMechanisms.detail', $json$"设置 › 代理 新增了 Claude Code、Codex 和 Copilot 的“代理可以做什么”列表：网络搜索、打开网页、运行命令和 GitHub 工具，每一项只在代理命令行支持时提供。网络搜索现在默认开启。组织可以在 LLM 策略中禁用其中任何一项。"$json$::jsonb),
  ('hi', 'chat.thoughts.more', $json${"one":"+ {count} पिछला संदेश","other":"+ {count} पिछले संदेश"}$json$::jsonb),
  ('hi', 'chat.thoughts.less', $json$"केवल नवीनतम दिखाएँ"$json$::jsonb),
  ('hi', 'agent.mechanisms', $json$"एजेंट क्या कर सकता है"$json$::jsonb),
  ('hi', 'agent.mechanisms.hint', $json$"JayV एजेंट को बिना टर्मिनल के चलाता है, और कोई उसके अनुमोदन अनुरोधों का जवाब नहीं देता: जो यहाँ चालू नहीं है, वह अस्वीकार हो जाता है। केवल वही दिखता है जिसे इस एजेंट की कमांड लाइन चालू कर सकती है।"$json$::jsonb),
  ('hi', 'agent.mechanisms.blocked', $json$"{orgs} ने अपने प्रोजेक्ट में इसे ब्लॉक किया है।"$json$::jsonb),
  ('hi', 'mechanism.webSearch', $json$"वेब पर खोजें"$json$::jsonb),
  ('hi', 'mechanism.webFetch', $json$"वेब पेज खोलें"$json$::jsonb),
  ('hi', 'mechanism.shell', $json$"बिना पूछे कमांड चलाएँ"$json$::jsonb),
  ('hi', 'mechanism.githubTools', $json$"सभी GitHub टूल"$json$::jsonb),
  ('hi', 'mechanism.webSearch.hint.claude', $json$"Claude Code को बिना पूछे WebSearch इस्तेमाल करने देता है।"$json$::jsonb),
  ('hi', 'mechanism.webFetch.hint.claude', $json$"Claude Code को बिना पूछे WebFetch से कोई भी पेज पढ़ने देता है।"$json$::jsonb),
  ('hi', 'mechanism.shell.hint.claude', $json$"Claude Code को बिना पूछे टर्मिनल कमांड (Bash) चलाने देता है। योजना मोड में इस्तेमाल नहीं होता।"$json$::jsonb),
  ('hi', 'mechanism.webSearch.hint.codex', $json$"लाइव वेब खोज (web_search = \"live\")। बंद करने पर खोज पूरी तरह बंद हो जाती है।"$json$::jsonb),
  ('hi', 'mechanism.webFetch.hint.copilot', $json$"Copilot को बिना पूछे किसी भी URL तक पहुँचने देता है (--allow-all-urls)।"$json$::jsonb),
  ('hi', 'mechanism.shell.hint.copilot', $json$"Copilot को बिना पूछे शेल कमांड चलाने देता है। ब्लॉक किए गए टूल ब्लॉक ही रहते हैं। योजना मोड में इस्तेमाल नहीं होता।"$json$::jsonb),
  ('hi', 'mechanism.githubTools.hint.copilot', $json$"डिफ़ॉल्ट उपसमूह के बजाय GitHub MCP सर्वर के सभी टूल चालू करता है।"$json$::jsonb),
  ('hi', 'cursor.mechanisms.none', $json$"Cursor में वेब खोज या अन्य टूल चालू या बंद करने का कोई कमांड-लाइन विकल्प नहीं है: यह Cursor की अपनी सेटिंग्स का पालन करता है।"$json$::jsonb),
  ('hi', 'settings.field.claude.mechanisms', $json$"Claude Code की क्षमताएँ"$json$::jsonb),
  ('hi', 'settings.field.codex.mechanisms', $json$"Codex की क्षमताएँ"$json$::jsonb),
  ('hi', 'settings.field.copilot.mechanisms', $json$"Copilot की क्षमताएँ"$json$::jsonb),
  ('hi', 'policy.mechanisms', $json$"ब्लॉक की गई क्षमताएँ"$json$::jsonb),
  ('hi', 'policy.mechanisms.hint', $json$"चुनी गई क्षमताएँ इस संगठन के प्रोजेक्ट में बंद रहती हैं, उन सदस्यों के लिए भी जिन्होंने उन्हें सेटिंग्स › एजेंट में चालू किया है।"$json$::jsonb),
  ('hi', 'policy.safe.hint', $json$"Claude Code में bypassPermissions नहीं, Codex में danger-full-access नहीं, Copilot में सभी टूल की अनुमति नहीं और Cursor में --force नहीं। Claude Code और Copilot बिना पूछे कमांड चलाना भी बंद कर देते हैं।"$json$::jsonb),
  ('hi', 'whatsNew.item.unsavedAbove.title', $json$"\"बिना सहेजे बदलाव\" अब बटनों को नीचे नहीं धकेलता"$json$::jsonb),
  ('hi', 'whatsNew.item.unsavedAbove.detail', $json$"सेटिंग्स में यह सूचना बटनों के बगल में दिखती थी और उन्हें नीचे धकेल देती थी। अब यह उनके ऊपर, एक ऐसी जगह पर है जो हमेशा मौजूद रहती है।"$json$::jsonb),
  ('hi', 'whatsNew.item.thoughtsCollapsed.title', $json$"एजेंट ने रास्ते में जो कहा, वह समेटा रहता है"$json$::jsonb),
  ('hi', 'whatsNew.item.thoughtsCollapsed.detail', $json$"JayV के बबल में, उत्तर के ऊपर केवल वह नवीनतम संदेश दिखता है जो एजेंट ने काम करते समय लिखा। एक बटन पिछले संदेश खोलता है।"$json$::jsonb),
  ('hi', 'whatsNew.item.agentMechanisms.title', $json$"हर एजेंट के लिए वेब खोज और अन्य टूल"$json$::jsonb),
  ('hi', 'whatsNew.item.agentMechanisms.detail', $json$"सेटिंग्स › एजेंट में Claude Code, Codex और Copilot के लिए \"एजेंट क्या कर सकता है\" सूची आई है: वेब खोज, पेज खोलना, कमांड चलाना और GitHub टूल, हर एक केवल वहीं जहाँ एजेंट की कमांड लाइन इसका समर्थन करती है। वेब खोज अब डिफ़ॉल्ट रूप से चालू है। संगठन LLM नीति में हर एक को ब्लॉक कर सकते हैं।"$json$::jsonb),
  ('ar', 'chat.thoughts.more', $json${"zero":"+ {count} رسالة سابقة","one":"+ رسالة سابقة واحدة","two":"+ رسالتان سابقتان","few":"+ {count} رسائل سابقة","many":"+ {count} رسالة سابقة","other":"+ {count} رسالة سابقة"}$json$::jsonb),
  ('ar', 'chat.thoughts.less', $json$"عرض الأحدث فقط"$json$::jsonb),
  ('ar', 'agent.mechanisms', $json$"ما يمكن للوكيل فعله"$json$::jsonb),
  ('ar', 'agent.mechanisms.hint', $json$"يشغّل JayV الوكيل دون طرفية، ولا أحد يردّ على طلبات الموافقة الخاصة به: كل ما لم يُفعَّل هنا يُرفض. لا يظهر إلا ما يستطيع سطر أوامر هذا الوكيل تفعيله."$json$::jsonb),
  ('ar', 'agent.mechanisms.blocked', $json$"محظور من {orgs} في مشاريعها."$json$::jsonb),
  ('ar', 'mechanism.webSearch', $json$"البحث في الويب"$json$::jsonb),
  ('ar', 'mechanism.webFetch', $json$"فتح صفحات الويب"$json$::jsonb),
  ('ar', 'mechanism.shell', $json$"تشغيل الأوامر دون سؤال"$json$::jsonb),
  ('ar', 'mechanism.githubTools', $json$"كل أدوات GitHub"$json$::jsonb),
  ('ar', 'mechanism.webSearch.hint.claude', $json$"يتيح لـ Claude Code استخدام WebSearch دون سؤال."$json$::jsonb),
  ('ar', 'mechanism.webFetch.hint.claude', $json$"يتيح لـ Claude Code قراءة أي صفحة عبر WebFetch دون سؤال."$json$::jsonb),
  ('ar', 'mechanism.shell.hint.claude', $json$"يتيح لـ Claude Code تشغيل أوامر الطرفية (Bash) دون سؤال. لا يُستخدم في وضع التخطيط."$json$::jsonb),
  ('ar', 'mechanism.webSearch.hint.codex', $json$"بحث مباشر في الويب (web_search = \"live\"). عند إيقافه يتوقف البحث تمامًا."$json$::jsonb),
  ('ar', 'mechanism.webFetch.hint.copilot', $json$"يتيح لـ Copilot الوصول إلى أي عنوان URL دون سؤال (--allow-all-urls)."$json$::jsonb),
  ('ar', 'mechanism.shell.hint.copilot', $json$"يتيح لـ Copilot تشغيل أوامر shell دون سؤال. تبقى الأدوات المحظورة محظورة. لا يُستخدم في وضع التخطيط."$json$::jsonb),
  ('ar', 'mechanism.githubTools.hint.copilot', $json$"يفعّل كل أدوات خادم GitHub MCP بدلًا من المجموعة الافتراضية."$json$::jsonb),
  ('ar', 'cursor.mechanisms.none', $json$"لا يملك Cursor خيار سطر أوامر لتشغيل البحث في الويب أو الأدوات الأخرى أو إيقافها: فهو يتبع إعدادات Cursor نفسه."$json$::jsonb),
  ('ar', 'settings.field.claude.mechanisms', $json$"آليات Claude Code"$json$::jsonb),
  ('ar', 'settings.field.codex.mechanisms', $json$"آليات Codex"$json$::jsonb),
  ('ar', 'settings.field.copilot.mechanisms', $json$"آليات Copilot"$json$::jsonb),
  ('ar', 'policy.mechanisms', $json$"الآليات المحظورة"$json$::jsonb),
  ('ar', 'policy.mechanisms.hint', $json$"تبقى الآليات المحددة متوقفة في مشاريع هذه المؤسسة، حتى لمن فعّلها من الأعضاء في الإعدادات › الوكلاء."$json$::jsonb),
  ('ar', 'policy.safe.hint', $json$"لا bypassPermissions في Claude Code، ولا danger-full-access في Codex، ولا إتاحة كل الأدوات في Copilot، ولا --force في Cursor. ويتوقف Claude Code وCopilot أيضًا عن تشغيل الأوامر دون سؤال."$json$::jsonb),
  ('ar', 'whatsNew.item.unsavedAbove.title', $json$"\"تغييرات غير محفوظة\" لم تعد تدفع الأزرار"$json$::jsonb),
  ('ar', 'whatsNew.item.unsavedAbove.detail', $json$"في الإعدادات، كان التنبيه يظهر بجانب الأزرار ويدفعها إلى الأسفل. أصبح الآن فوقها، في مساحة موجودة دائمًا."$json$::jsonb),
  ('ar', 'whatsNew.item.thoughtsCollapsed.title', $json$"ما قاله الوكيل في الطريق يبقى مطويًا"$json$::jsonb),
  ('ar', 'whatsNew.item.thoughtsCollapsed.detail', $json$"في فقاعة JayV، لا تظهر فوق الإجابة إلا أحدث رسالة كتبها الوكيل أثناء العمل. ويفتح زرٌّ الرسائل السابقة."$json$::jsonb),
  ('ar', 'whatsNew.item.agentMechanisms.title', $json$"البحث في الويب وأدوات أخرى لكل وكيل"$json$::jsonb),
  ('ar', 'whatsNew.item.agentMechanisms.detail', $json$"أصبح في الإعدادات › الوكلاء قائمة \"ما يمكن للوكيل فعله\" لـ Claude Code وCodex وCopilot: البحث في الويب وفتح الصفحات وتشغيل الأوامر وأدوات GitHub، كلٌّ منها فقط حيث يدعمه سطر أوامر الوكيل. البحث في الويب مفعّل الآن افتراضيًا. ويمكن للمؤسسات حظر كل منها في سياسة LLM."$json$::jsonb),
  ('fr', 'chat.thoughts.more', $json${"one":"+ {count} message précédent","other":"+ {count} messages précédents"}$json$::jsonb),
  ('fr', 'chat.thoughts.less', $json$"afficher seulement le plus récent"$json$::jsonb),
  ('fr', 'agent.mechanisms', $json$"Ce que l'agent peut faire"$json$::jsonb),
  ('fr', 'agent.mechanisms.hint', $json$"JayV exécute l'agent sans terminal, et personne ne répond à ses demandes d'approbation : ce qui n'est pas activé ici est refusé. Seul ce que la ligne de commande de cet agent sait activer est listé."$json$::jsonb),
  ('fr', 'agent.mechanisms.blocked', $json$"Bloqué par {orgs} dans ses projets."$json$::jsonb),
  ('fr', 'mechanism.webSearch', $json$"Rechercher sur le web"$json$::jsonb),
  ('fr', 'mechanism.webFetch', $json$"Ouvrir des pages web"$json$::jsonb),
  ('fr', 'mechanism.shell', $json$"Exécuter des commandes sans demander"$json$::jsonb),
  ('fr', 'mechanism.githubTools', $json$"Tous les outils GitHub"$json$::jsonb),
  ('fr', 'mechanism.webSearch.hint.claude', $json$"Permet à Claude Code d'utiliser WebSearch sans demander."$json$::jsonb),
  ('fr', 'mechanism.webFetch.hint.claude', $json$"Permet à Claude Code de lire n'importe quelle page avec WebFetch sans demander."$json$::jsonb),
  ('fr', 'mechanism.shell.hint.claude', $json$"Permet à Claude Code d'exécuter des commandes de terminal (Bash) sans demander. Non utilisé en mode Planification."$json$::jsonb),
  ('fr', 'mechanism.webSearch.hint.codex', $json$"Recherche web en direct (web_search = \"live\"). Désactivée, la recherche est complètement coupée."$json$::jsonb),
  ('fr', 'mechanism.webFetch.hint.copilot', $json$"Permet à Copilot d'accéder à n'importe quelle URL sans demander (--allow-all-urls)."$json$::jsonb),
  ('fr', 'mechanism.shell.hint.copilot', $json$"Permet à Copilot d'exécuter des commandes shell sans demander. Les outils bloqués restent bloqués. Non utilisé en mode Planification."$json$::jsonb),
  ('fr', 'mechanism.githubTools.hint.copilot', $json$"Active tous les outils du serveur MCP GitHub au lieu du sous-ensemble par défaut."$json$::jsonb),
  ('fr', 'cursor.mechanisms.none', $json$"Cursor n'a pas d'option de ligne de commande pour activer ou désactiver la recherche web ou d'autres outils : il suit les réglages de Cursor lui-même."$json$::jsonb),
  ('fr', 'settings.field.claude.mechanisms', $json$"les mécanismes de Claude Code"$json$::jsonb),
  ('fr', 'settings.field.codex.mechanisms', $json$"les mécanismes de Codex"$json$::jsonb),
  ('fr', 'settings.field.copilot.mechanisms', $json$"les mécanismes de Copilot"$json$::jsonb),
  ('fr', 'policy.mechanisms', $json$"Mécanismes bloqués"$json$::jsonb),
  ('fr', 'policy.mechanisms.hint', $json$"Ceux qui sont cochés restent désactivés dans les projets de cette organisation, même pour les membres qui les ont activés dans Paramètres › Agents."$json$::jsonb),
  ('fr', 'policy.safe.hint', $json$"Pas de bypassPermissions dans Claude Code, pas de danger-full-access dans Codex, pas d'accès à tous les outils dans Copilot et pas de --force dans Cursor. Claude Code et Copilot cessent aussi d'exécuter des commandes sans demander."$json$::jsonb),
  ('fr', 'whatsNew.item.unsavedAbove.title', $json$"« Modifications non enregistrées » ne pousse plus les boutons"$json$::jsonb),
  ('fr', 'whatsNew.item.unsavedAbove.detail', $json$"Dans Paramètres, l'avis apparaissait à côté des boutons et les poussait vers le bas. Il se trouve maintenant au-dessus, dans un espace toujours présent."$json$::jsonb),
  ('fr', 'whatsNew.item.thoughtsCollapsed.title', $json$"Ce que l'agent a dit en chemin reste replié"$json$::jsonb),
  ('fr', 'whatsNew.item.thoughtsCollapsed.detail', $json$"Dans la bulle de JayV, seul le dernier message écrit par l'agent pendant son travail apparaît au-dessus de la réponse. Un bouton ouvre les précédents."$json$::jsonb),
  ('fr', 'whatsNew.item.agentMechanisms.title', $json$"Recherche web et autres outils par agent"$json$::jsonb),
  ('fr', 'whatsNew.item.agentMechanisms.detail', $json$"Paramètres › Agents propose la liste « Ce que l'agent peut faire » pour Claude Code, Codex et Copilot : rechercher sur le web, ouvrir des pages, exécuter des commandes et les outils GitHub, chacun seulement là où la ligne de commande de l'agent le permet. La recherche web est désormais activée par défaut. Les organisations peuvent bloquer chacun dans la politique LLM."$json$::jsonb),
  ('ja', 'chat.thoughts.more', $json${"other":"+ 以前のメッセージ {count} 件"}$json$::jsonb),
  ('ja', 'chat.thoughts.less', $json$"最新のみ表示"$json$::jsonb),
  ('ja', 'agent.mechanisms', $json$"エージェントができること"$json$::jsonb),
  ('ja', 'agent.mechanisms.hint', $json$"JayV はエージェントを端末なしで実行するため、承認の確認には誰も答えません。ここでオンにしていないものは拒否されます。このエージェントのコマンドラインがオンにできるものだけを表示します。"$json$::jsonb),
  ('ja', 'agent.mechanisms.blocked', $json$"{orgs} のプロジェクトではブロックされています。"$json$::jsonb),
  ('ja', 'mechanism.webSearch', $json$"ウェブを検索"$json$::jsonb),
  ('ja', 'mechanism.webFetch', $json$"ウェブページを開く"$json$::jsonb),
  ('ja', 'mechanism.shell', $json$"確認なしでコマンドを実行"$json$::jsonb),
  ('ja', 'mechanism.githubTools', $json$"すべての GitHub ツール"$json$::jsonb),
  ('ja', 'mechanism.webSearch.hint.claude', $json$"Claude Code が確認なしで WebSearch を使えるようにします。"$json$::jsonb),
  ('ja', 'mechanism.webFetch.hint.claude', $json$"Claude Code が確認なしで WebFetch により任意のページを読めるようにします。"$json$::jsonb),
  ('ja', 'mechanism.shell.hint.claude', $json$"Claude Code が確認なしで端末コマンド (Bash) を実行できるようにします。計画モードでは使われません。"$json$::jsonb),
  ('ja', 'mechanism.webSearch.hint.codex', $json$"ライブのウェブ検索 (web_search = \"live\")。オフにすると検索は完全に無効になります。"$json$::jsonb),
  ('ja', 'mechanism.webFetch.hint.copilot', $json$"Copilot が確認なしで任意の URL にアクセスできるようにします (--allow-all-urls)。"$json$::jsonb),
  ('ja', 'mechanism.shell.hint.copilot', $json$"Copilot が確認なしでシェルコマンドを実行できるようにします。ブロックしたツールは引き続き使えません。計画モードでは使われません。"$json$::jsonb),
  ('ja', 'mechanism.githubTools.hint.copilot', $json$"既定のサブセットではなく、GitHub MCP サーバーのすべてのツールをオンにします。"$json$::jsonb),
  ('ja', 'cursor.mechanisms.none', $json$"Cursor にはウェブ検索やその他のツールをオン・オフするコマンドラインオプションがありません。Cursor 自体の設定に従います。"$json$::jsonb),
  ('ja', 'settings.field.claude.mechanisms', $json$"Claude Code の機能"$json$::jsonb),
  ('ja', 'settings.field.codex.mechanisms', $json$"Codex の機能"$json$::jsonb),
  ('ja', 'settings.field.copilot.mechanisms', $json$"Copilot の機能"$json$::jsonb),
  ('ja', 'policy.mechanisms', $json$"ブロックする機能"$json$::jsonb),
  ('ja', 'policy.mechanisms.hint', $json$"チェックした機能は、設定 › エージェントでオンにしたメンバーでも、この組織のプロジェクトではオフになります。"$json$::jsonb),
  ('ja', 'policy.safe.hint', $json$"Claude Code の bypassPermissions、Codex の danger-full-access、Copilot の全ツール許可、Cursor の --force を使いません。Claude Code と Copilot は確認なしでのコマンド実行もやめます。"$json$::jsonb),
  ('ja', 'whatsNew.item.unsavedAbove.title', $json$"「未保存の変更」がボタンを押し下げなくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.unsavedAbove.detail', $json$"設定では、この通知がボタンの横に表示され、ボタンを下に押し下げていました。今はボタンの上の、常にある場所に表示されます。"$json$::jsonb),
  ('ja', 'whatsNew.item.thoughtsCollapsed.title', $json$"エージェントが途中で書いたことは折りたたまれます"$json$::jsonb),
  ('ja', 'whatsNew.item.thoughtsCollapsed.detail', $json$"JayV の吹き出しでは、作業中にエージェントが書いた最新のメッセージだけが回答の上に表示されます。ボタンで以前のものを開けます。"$json$::jsonb),
  ('ja', 'whatsNew.item.agentMechanisms.title', $json$"エージェントごとのウェブ検索とその他のツール"$json$::jsonb),
  ('ja', 'whatsNew.item.agentMechanisms.detail', $json$"設定 › エージェントに、Claude Code、Codex、Copilot 用の「エージェントができること」一覧が追加されました。ウェブ検索、ページを開く、コマンドの実行、GitHub ツールを、各エージェントのコマンドラインが対応する範囲でオンにできます。ウェブ検索は既定でオンになりました。組織は LLM ポリシーでそれぞれをブロックできます。"$json$::jsonb),
  ('ru', 'chat.thoughts.more', $json${"one":"+ {count} предыдущее сообщение","few":"+ {count} предыдущих сообщения","many":"+ {count} предыдущих сообщений","other":"+ {count} предыдущих сообщения"}$json$::jsonb),
  ('ru', 'chat.thoughts.less', $json$"показать только последнее"$json$::jsonb),
  ('ru', 'agent.mechanisms', $json$"Что может агент"$json$::jsonb),
  ('ru', 'agent.mechanisms.hint', $json$"JayV запускает агента без терминала, и никто не отвечает на его запросы подтверждения: всё, что не включено здесь, запрещается. Показано только то, что умеет включать командная строка этого агента."$json$::jsonb),
  ('ru', 'agent.mechanisms.blocked', $json$"Заблокировано {orgs} в их проектах."$json$::jsonb),
  ('ru', 'mechanism.webSearch', $json$"Поиск в интернете"$json$::jsonb),
  ('ru', 'mechanism.webFetch', $json$"Открывать веб-страницы"$json$::jsonb),
  ('ru', 'mechanism.shell', $json$"Выполнять команды без вопросов"$json$::jsonb),
  ('ru', 'mechanism.githubTools', $json$"Все инструменты GitHub"$json$::jsonb),
  ('ru', 'mechanism.webSearch.hint.claude', $json$"Разрешает Claude Code использовать WebSearch без вопросов."$json$::jsonb),
  ('ru', 'mechanism.webFetch.hint.claude', $json$"Разрешает Claude Code читать любую страницу через WebFetch без вопросов."$json$::jsonb),
  ('ru', 'mechanism.shell.hint.claude', $json$"Разрешает Claude Code выполнять команды терминала (Bash) без вопросов. Не используется в режиме планирования."$json$::jsonb),
  ('ru', 'mechanism.webSearch.hint.codex', $json$"Живой поиск в интернете (web_search = \"live\"). Выключенный поиск отключён полностью."$json$::jsonb),
  ('ru', 'mechanism.webFetch.hint.copilot', $json$"Разрешает Copilot открывать любой URL без вопросов (--allow-all-urls)."$json$::jsonb),
  ('ru', 'mechanism.shell.hint.copilot', $json$"Разрешает Copilot выполнять команды shell без вопросов. Заблокированные инструменты остаются заблокированными. Не используется в режиме планирования."$json$::jsonb),
  ('ru', 'mechanism.githubTools.hint.copilot', $json$"Включает все инструменты MCP-сервера GitHub вместо набора по умолчанию."$json$::jsonb),
  ('ru', 'cursor.mechanisms.none', $json$"У Cursor нет флага командной строки, чтобы включить или выключить поиск в интернете или другие инструменты: он следует собственным настройкам Cursor."$json$::jsonb),
  ('ru', 'settings.field.claude.mechanisms', $json$"механизмы Claude Code"$json$::jsonb),
  ('ru', 'settings.field.codex.mechanisms', $json$"механизмы Codex"$json$::jsonb),
  ('ru', 'settings.field.copilot.mechanisms', $json$"механизмы Copilot"$json$::jsonb),
  ('ru', 'policy.mechanisms', $json$"Заблокированные механизмы"$json$::jsonb),
  ('ru', 'policy.mechanisms.hint', $json$"Отмеченные остаются выключенными в проектах этой организации, даже у участников, которые включили их в Настройки › Агенты."$json$::jsonb),
  ('ru', 'policy.safe.hint', $json$"Без bypassPermissions в Claude Code, без danger-full-access в Codex, без доступа ко всем инструментам в Copilot и без --force в Cursor. Claude Code и Copilot также перестают выполнять команды без вопросов."$json$::jsonb),
  ('ru', 'whatsNew.item.unsavedAbove.title', $json$"«Несохранённые изменения» больше не сдвигают кнопки"$json$::jsonb),
  ('ru', 'whatsNew.item.unsavedAbove.detail', $json$"В настройках уведомление появлялось рядом с кнопками и сдвигало их вниз. Теперь оно стоит над ними, в месте, которое есть всегда."$json$::jsonb),
  ('ru', 'whatsNew.item.thoughtsCollapsed.title', $json$"Сказанное агентом по ходу работы свёрнуто"$json$::jsonb),
  ('ru', 'whatsNew.item.thoughtsCollapsed.detail', $json$"В пузыре JayV над ответом показывается только последнее сообщение, которое агент написал во время работы. Кнопка открывает предыдущие."$json$::jsonb),
  ('ru', 'whatsNew.item.agentMechanisms.title', $json$"Поиск в интернете и другие инструменты для каждого агента"$json$::jsonb),
  ('ru', 'whatsNew.item.agentMechanisms.detail', $json$"В Настройки › Агенты появился список «Что может агент» для Claude Code, Codex и Copilot: поиск в интернете, открытие страниц, выполнение команд и инструменты GitHub, каждый только там, где его поддерживает командная строка агента. Поиск в интернете теперь включён по умолчанию. Организации могут заблокировать каждый из них в политике LLM."$json$::jsonb),
  ('de', 'chat.thoughts.more', $json${"one":"+ {count} frühere Nachricht","other":"+ {count} frühere Nachrichten"}$json$::jsonb),
  ('de', 'chat.thoughts.less', $json$"nur die neueste anzeigen"$json$::jsonb),
  ('de', 'agent.mechanisms', $json$"Was der Agent tun darf"$json$::jsonb),
  ('de', 'agent.mechanisms.hint', $json$"JayV startet den Agenten ohne Terminal, und niemand beantwortet seine Freigabeanfragen: Was hier nicht eingeschaltet ist, wird abgelehnt. Es erscheint nur, was die Befehlszeile dieses Agenten einschalten kann."$json$::jsonb),
  ('de', 'agent.mechanisms.blocked', $json$"Von {orgs} in deren Projekten gesperrt."$json$::jsonb),
  ('de', 'mechanism.webSearch', $json$"Im Web suchen"$json$::jsonb),
  ('de', 'mechanism.webFetch', $json$"Webseiten öffnen"$json$::jsonb),
  ('de', 'mechanism.shell', $json$"Befehle ohne Nachfrage ausführen"$json$::jsonb),
  ('de', 'mechanism.githubTools', $json$"Alle GitHub-Werkzeuge"$json$::jsonb),
  ('de', 'mechanism.webSearch.hint.claude', $json$"Lässt Claude Code WebSearch ohne Nachfrage verwenden."$json$::jsonb),
  ('de', 'mechanism.webFetch.hint.claude', $json$"Lässt Claude Code jede Seite mit WebFetch ohne Nachfrage lesen."$json$::jsonb),
  ('de', 'mechanism.shell.hint.claude', $json$"Lässt Claude Code Terminalbefehle (Bash) ohne Nachfrage ausführen. Gilt nicht im Planungsmodus."$json$::jsonb),
  ('de', 'mechanism.webSearch.hint.codex', $json$"Live-Websuche (web_search = \"live\"). Ausgeschaltet ist die Suche ganz aus."$json$::jsonb),
  ('de', 'mechanism.webFetch.hint.copilot', $json$"Lässt Copilot ohne Nachfrage auf jede URL zugreifen (--allow-all-urls)."$json$::jsonb),
  ('de', 'mechanism.shell.hint.copilot', $json$"Lässt Copilot Shell-Befehle ohne Nachfrage ausführen. Gesperrte Werkzeuge bleiben gesperrt. Gilt nicht im Planungsmodus."$json$::jsonb),
  ('de', 'mechanism.githubTools.hint.copilot', $json$"Schaltet alle Werkzeuge des GitHub-MCP-Servers statt der Standardauswahl ein."$json$::jsonb),
  ('de', 'cursor.mechanisms.none', $json$"Cursor hat keine Befehlszeilenoption, um die Websuche oder andere Werkzeuge ein- oder auszuschalten: Es folgt den eigenen Cursor-Einstellungen."$json$::jsonb),
  ('de', 'settings.field.claude.mechanisms', $json$"die Mechanismen von Claude Code"$json$::jsonb),
  ('de', 'settings.field.codex.mechanisms', $json$"die Mechanismen von Codex"$json$::jsonb),
  ('de', 'settings.field.copilot.mechanisms', $json$"die Mechanismen von Copilot"$json$::jsonb),
  ('de', 'policy.mechanisms', $json$"Gesperrte Mechanismen"$json$::jsonb),
  ('de', 'policy.mechanisms.hint', $json$"Markierte bleiben in den Projekten dieser Organisation aus, auch für Mitglieder, die sie unter Einstellungen › Agenten eingeschaltet haben."$json$::jsonb),
  ('de', 'policy.safe.hint', $json$"Kein bypassPermissions in Claude Code, kein danger-full-access in Codex, nicht alle Werkzeuge in Copilot und kein --force in Cursor. Claude Code und Copilot führen außerdem keine Befehle mehr ohne Nachfrage aus."$json$::jsonb),
  ('de', 'whatsNew.item.unsavedAbove.title', $json$"„Ungespeicherte Änderungen“ verschiebt die Schaltflächen nicht mehr"$json$::jsonb),
  ('de', 'whatsNew.item.unsavedAbove.detail', $json$"In den Einstellungen erschien der Hinweis neben den Schaltflächen und schob sie nach unten. Jetzt steht er darüber, in einem Platz, der immer da ist."$json$::jsonb),
  ('de', 'whatsNew.item.thoughtsCollapsed.title', $json$"Was der Agent unterwegs gesagt hat, bleibt eingeklappt"$json$::jsonb),
  ('de', 'whatsNew.item.thoughtsCollapsed.detail', $json$"In JayVs Blase erscheint über der Antwort nur die neueste Nachricht, die der Agent während der Arbeit geschrieben hat. Eine Schaltfläche öffnet die früheren."$json$::jsonb),
  ('de', 'whatsNew.item.agentMechanisms.title', $json$"Websuche und andere Werkzeuge pro Agent"$json$::jsonb),
  ('de', 'whatsNew.item.agentMechanisms.detail', $json$"Einstellungen › Agenten hat die Liste „Was der Agent tun darf“ für Claude Code, Codex und Copilot: im Web suchen, Seiten öffnen, Befehle ausführen und GitHub-Werkzeuge, jeweils nur, wo die Befehlszeile des Agenten es unterstützt. Die Websuche ist jetzt standardmäßig an. Organisationen können jeden davon in der LLM-Richtlinie sperren."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
