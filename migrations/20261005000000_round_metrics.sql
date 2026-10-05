-- v0.55.0 (Fase 0 do plano de redução de voltas): as consultas que medem o
-- JayV pelo que ele promete — quantas voltas o desenvolvedor dá até chegar
-- onde quer, quanto cada chat custa e por que o agente relê o projeto do zero.
--
-- São views, não tabelas: leem o que o app já sincroniza (turns,
-- entry_checks, usage_records, jev_records). `security_invoker` faz cada
-- conta ver só as próprias linhas pela RLS das tabelas; no editor SQL, com o
-- papel de serviço, elas mostram o total.
--
-- O app grava, a partir da v0.55.0, uma marca `session_new:<motivo>` em
-- jev_records a cada sessão nova de agente (first, cannot_resume,
-- other_agent, other_model, other_folder, other_mode, turn_ceiling, lost), ao
-- lado da `session_resumed` que já existia.

-- Vereditos da portaria por origem (o Jev ou a heurística local).
create view public.jev_metric_entry_verdicts with (security_invoker = true) as
select e.source, e.verdict, count(*)::bigint as requests
from public.entry_checks e
where e.row_deleted_at is null
group by e.source, e.verdict;

-- O que vem depois de cada veredito: o próximo pedido do mesmo chat em até
-- 15 minutos é tratado como reenvio.
create view public.jev_metric_gate_followups with (security_invoker = true) as
with ordered as (
  select t.chat_id, e.verdict, t.created_at::timestamptz as at,
         lead(t.created_at::timestamptz) over (partition by t.chat_id order by t.ordinal) as next_at
  from public.turns t
  join public.entry_checks e on e.turn_id = t.id and e.row_deleted_at is null
  where t.row_deleted_at is null
)
select verdict,
       count(*)::bigint as requests,
       count(*) filter (where next_at - at < interval '15 minutes')::bigint as resent_within_15min
from ordered
group by verdict;

-- Pedidos por chat e quantos deles são reclamação ("não funcionou", "ainda dá
-- erro", "still fails"): a linha de base das voltas.
create view public.jev_metric_chat_rounds with (security_invoker = true) as
select count(distinct t.chat_id)::bigint as chats,
       count(*)::bigint as requests,
       round(count(*)::numeric / nullif(count(distinct t.chat_id), 0), 2) as requests_per_chat,
       count(*) filter (where e.prompt ~* '(n[ãa]o (funcionou|funciona|deu certo|resolveu)|ainda (d[áa]|est[áa]|n[ãa]o)|deu erro|quebrou|doesn.?t work|didn.?t work|still (fails|broken|not))')::bigint as complaints
from public.turns t
join public.entry_checks e on e.turn_id = t.id and e.row_deleted_at is null
where t.row_deleted_at is null;

-- O que cada fonte gastou: os agentes e o Jev (`jev:entry`, `jev:routing`,
-- `jev:asking`), com a precisão de cada número.
create view public.jev_metric_spend_by_source with (security_invoker = true) as
select split_part(r.source, ':', 1) as payer,
       r.source,
       r.precision,
       count(*)::bigint as calls,
       sum(r.input_tokens)::bigint as input_tokens,
       sum(r.cache_read_tokens)::bigint as cache_read_tokens,
       sum(r.cache_write_tokens)::bigint as cache_write_tokens,
       sum(r.output_tokens)::bigint as output_tokens,
       round(sum(r.cost_usd)::numeric, 4) as cost_usd
from public.usage_records r
where r.row_deleted_at is null
group by split_part(r.source, ':', 1), r.source, r.precision;

-- Custo por chat: o que importa para quem dá voltas é o chat inteiro.
create view public.jev_metric_chat_cost with (security_invoker = true) as
select r.chat_id,
       count(distinct r.turn_id)::bigint as requests,
       sum(r.input_tokens + r.cache_read_tokens + r.cache_write_tokens + r.output_tokens)::bigint as tokens,
       round(sum(r.cost_usd)::numeric, 4) as cost_usd
from public.usage_records r
where r.row_deleted_at is null and r.chat_id is not null
group by r.chat_id;

-- Sessões de agente: retomadas e novas, com o motivo de cada nova.
create view public.jev_metric_agent_sessions with (security_invoker = true) as
select case when j.kind = 'session_resumed' then 'resumed' else 'new' end as outcome,
       case when j.kind like 'session_new:%' then substr(j.kind, length('session_new:') + 1) end as reason,
       count(*)::bigint as sessions
from public.jev_records j
where j.row_deleted_at is null and (j.kind = 'session_resumed' or j.kind like 'session_new:%')
group by 1, 2;

-- A taxa de retomada de cada chat.
create view public.jev_metric_chat_resume_rate with (security_invoker = true) as
select j.chat_id,
       count(*) filter (where j.kind = 'session_resumed')::bigint as resumed,
       count(*) filter (where j.kind like 'session_new:%')::bigint as new_sessions,
       round(count(*) filter (where j.kind = 'session_resumed')::numeric / nullif(count(*), 0), 2) as resume_rate
from public.jev_records j
where j.row_deleted_at is null and j.chat_id is not null and (j.kind = 'session_resumed' or j.kind like 'session_new:%')
group by j.chat_id;

grant select on
  public.jev_metric_entry_verdicts,
  public.jev_metric_gate_followups,
  public.jev_metric_chat_rounds,
  public.jev_metric_spend_by_source,
  public.jev_metric_chat_cost,
  public.jev_metric_agent_sessions,
  public.jev_metric_chat_resume_rate
to authenticated;
