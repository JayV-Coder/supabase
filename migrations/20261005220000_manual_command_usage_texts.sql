-- Site v1.3.1: o que se digita nos comandos do terminal, na Documentação, com
-- o nome do parâmetro no idioma da página (`jayv run <pedido>`). O comando
-- em si não muda; só o que vai entre `<>`. A chave é docs.command.<id>.usage;
-- comando sem ela mostra o `usage` do commands.json como está.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'docs.command.cliRun.usage', $json$"jayv run <pedido>"$json$::jsonb),
  ('pt-BR', 'docs.command.cliBench.usage', $json$"jayv bench <tarefas.yaml>"$json$::jsonb),
  ('en', 'docs.command.cliRun.usage', $json$"jayv run <request>"$json$::jsonb),
  ('en', 'docs.command.cliBench.usage', $json$"jayv bench <tasks.yaml>"$json$::jsonb),
  ('es', 'docs.command.cliRun.usage', $json$"jayv run <solicitud>"$json$::jsonb),
  ('es', 'docs.command.cliBench.usage', $json$"jayv bench <tareas.yaml>"$json$::jsonb),
  ('zh-CN', 'docs.command.cliRun.usage', $json$"jayv run <请求>"$json$::jsonb),
  ('zh-CN', 'docs.command.cliBench.usage', $json$"jayv bench <任务.yaml>"$json$::jsonb),
  ('hi', 'docs.command.cliRun.usage', $json$"jayv run <अनुरोध>"$json$::jsonb),
  ('hi', 'docs.command.cliBench.usage', $json$"jayv bench <टास्क.yaml>"$json$::jsonb),
  ('ar', 'docs.command.cliRun.usage', $json$"jayv run <الطلب>"$json$::jsonb),
  ('ar', 'docs.command.cliBench.usage', $json$"jayv bench <المهام.yaml>"$json$::jsonb),
  ('fr', 'docs.command.cliRun.usage', $json$"jayv run <demande>"$json$::jsonb),
  ('fr', 'docs.command.cliBench.usage', $json$"jayv bench <taches.yaml>"$json$::jsonb),
  ('ru', 'docs.command.cliRun.usage', $json$"jayv run <запрос>"$json$::jsonb),
  ('ru', 'docs.command.cliBench.usage', $json$"jayv bench <задачи.yaml>"$json$::jsonb),
  ('ja', 'docs.command.cliRun.usage', $json$"jayv run <依頼>"$json$::jsonb),
  ('ja', 'docs.command.cliBench.usage', $json$"jayv bench <タスク.yaml>"$json$::jsonb),
  ('de', 'docs.command.cliRun.usage', $json$"jayv run <anfrage>"$json$::jsonb),
  ('de', 'docs.command.cliBench.usage', $json$"jayv bench <aufgaben.yaml>"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;
