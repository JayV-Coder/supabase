// O Jev do JayV. Recebe `{ set, state, include? }` com o JWT do usuário,
// conta a chamada no limite diário, monta as perguntas do conjunto a partir de
// `jev_questions` e repassa à TypeSafe com a chave que só existe aqui.
//
// O app nunca manda perguntas: se mandasse, a chave viraria API de uso livre
// para qualquer conta do projeto.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const SETS = ["entry", "routing", "asking"];
const TYPESAFE_URL = `${Deno.env.get("TYPESAFE_BASE_URL") ?? "https://api.typesafe.ai"}/v1/systemone`;
const MODEL = Deno.env.get("TYPESAFE_DEFAULT_MODEL") ?? "jev-latest";
// Um valor que não é número ("500 ", "abc") não pode desligar o limite.
const configuredLimit = Number.parseInt(Deno.env.get("JEV_DAILY_LIMIT") ?? "", 10);
const DAILY_LIMIT = Number.isFinite(configuredLimit) && configuredLimit > 0 ? configuredLimit : 500;
// Quanto a TypeSafe pode demorar. Abaixo dos 30 s do app antigo: a chamada
// que ele já abandonou não fica correndo aqui depois de ele desistir.
const configuredTimeout = Number.parseInt(Deno.env.get("JEV_UPSTREAM_TIMEOUT_MS") ?? "", 10);
const UPSTREAM_TIMEOUT_MS = Number.isFinite(configuredTimeout) && configuredTimeout >= 1000 ? configuredTimeout : 25_000;
// As perguntas mudam por migração, não a cada pedido: ficam em memória no
// isolate por alguns minutos em vez de uma ida ao banco por chamada.
const QUESTIONS_TTL_MS = 5 * 60_000;
// O id da chamada que o app repete igual em cada tentativa (`x-jev-request`).
const REQUEST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Row = { id: string; body: unknown };
const questionsCache = new Map<string, { at: number; rows: Row[] }>();

function reply(status: number, body: unknown, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function refuse(status: number, code: string, message: string): Response {
  return reply(status, { error: message, code });
}

// deno-lint-ignore no-explicit-any
async function readQuestions(supabase: SupabaseClient<any, "public">, set: string): Promise<{ rows: Row[]; error?: string }> {
  const kept = questionsCache.get(set);
  if (kept && Date.now() - kept.at < QUESTIONS_TTL_MS) return { rows: kept.rows };
  const { data, error } = await supabase.from("jev_questions").select("id, body").eq("question_set", set).order("position");
  if (error) return { rows: [], error: error.message };
  const rows = (data ?? []) as Row[];
  questionsCache.set(set, { at: Date.now(), rows });
  return { rows };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return refuse(405, "method", "só POST");

  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return refuse(401, "session", "sem sessão");

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Um token que nem é JWT faz o `getClaims` lançar em vez de devolver erro:
  // as duas formas são a mesma recusa.
  let subject: string | undefined;
  try {
    const { data: claims, error: invalid } = await supabase.auth.getClaims(token);
    if (!invalid) subject = claims?.claims?.sub;
  } catch {
    subject = undefined;
  }
  if (!subject) return refuse(401, "session", "sessão inválida ou expirada");

  let input: { set?: unknown; state?: unknown; include?: unknown };
  try {
    input = await request.json();
  } catch {
    return refuse(400, "body", "o corpo não é JSON");
  }
  const set = String(input.set ?? "");
  if (!SETS.includes(set)) return refuse(400, "set", `conjunto desconhecido: ${set}`);
  if (typeof input.state !== "object" || input.state === null) return refuse(400, "state", "falta o estado");
  const include = Array.isArray(input.include) ? input.include.map(String) : null;
  const sent = request.headers.get("x-jev-request") ?? "";
  const requestId = REQUEST_ID.test(sent) ? sent.toLowerCase() : null;

  // A conta, o limite do plano e as perguntas não dependem um do outro: saem
  // juntos.
  const [counted, planLimit, questionRows] = await Promise.all([
    requestId ? supabase.rpc("jev_count_call", { request: requestId }) : supabase.rpc("jev_count_call"),
    supabase.rpc("my_jev_daily_limit"),
    readQuestions(supabase, set),
  ]);
  const { data: used, error: counting } = counted;
  // Sem o segundo fator (PT403) a recusa é definitiva: 403, e o app não
  // tenta de novo como faria num 500.
  if (counting) return refuse(counting.code === "PT403" ? 403 : 500, counting.code === "PT403" ? "second_factor" : "usage", `não foi possível contar o uso: ${counting.message}`);
  // As chamadas do dia vão em toda resposta, inclusive na recusa: é delas que
  // o app tira a cota diária das estatísticas.
  // O plano pode ter limite próprio; sem ele (ou sem a migração), vale o da função.
  const ownLimit = Number(planLimit.error ? null : planLimit.data);
  const limit = Number.isInteger(ownLimit) && ownLimit > 0 ? ownLimit : DAILY_LIMIT;
  const calls = { "X-Jev-Calls-Used": String(used), "X-Jev-Daily-Limit": String(limit) };
  if (Number(used) > limit) return reply(429, { error: "limite diário do Jev atingido", code: "daily_limit" }, calls);

  // A chamada que não valeu volta para o limite do dia; com id, só uma vez.
  const refund = async () => {
    const { error } = requestId ? await supabase.rpc("jev_refund_call", { request: requestId }) : await supabase.rpc("jev_refund_call");
    if (error) console.error("jev: não devolveu a chamada", error.message);
  };

  if (questionRows.error) {
    await refund();
    return refuse(500, "questions", `não foi possível ler as perguntas: ${questionRows.error}`);
  }
  const questions = Object.fromEntries(questionRows.rows.filter((row) => !include || include.includes(row.id)).map((row) => [row.id, row.body]));
  if (Object.keys(questions).length === 0) {
    await refund();
    return refuse(422, "questions", `o conjunto ${set} não tem perguntas`);
  }

  const key = Deno.env.get("TYPESAFE_API_KEY");
  if (!key) {
    await refund();
    return refuse(500, "config", "a função está sem a chave da TypeSafe");
  }

  let upstream: Response;
  try {
    upstream = await fetch(TYPESAFE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: MODEL, state: input.state, questions }),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (error) {
    // Sem resposta no prazo ou sem rede até a TypeSafe: a chamada não valeu.
    await refund();
    const timedOut = error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError");
    return timedOut
      ? refuse(504, "upstream_timeout", `a TypeSafe não respondeu em ${UPSTREAM_TIMEOUT_MS} ms`)
      : refuse(502, "upstream", `a TypeSafe não respondeu: ${error}`);
  }
  // A avaliação volta como veio, e o status também: 429, 529 e 5xx são o
  // sinal para o Rust tentar de novo. Essa chamada não valeu, então não conta
  // no limite do dia — senão cada nova tentativa gastaria a cota duas vezes.
  if (upstream.status === 429 || upstream.status >= 500) await refund();
  const headers: Record<string, string> = { ...calls };
  const retryAfter = upstream.headers.get("Retry-After");
  if (retryAfter) headers["Retry-After"] = retryAfter;
  return new Response(await upstream.text(), { status: upstream.status, headers: { "Content-Type": "application/json", ...headers } });
});
