// A única porta para o repositório público dos mods
// (`JayV-Coder/jayv-coder-mods`). O app e o site leem o catálogo por aqui,
// nunca direto do GitHub:
//   GET /catalog   → o `catalog.json` do ramo principal: `{ schema, mods }`
//
// Sem JWT (`verify_jwt = false`): o catálogo é público, como os releases. Os
// mods que cada pessoa cria ficam na conta dela (as tabelas sincronizadas do
// app), não aqui.
//
// Segredos opcionais (Edge Functions → Secrets):
//   MODS_REPOSITORY   outro repositório (padrão JayV-Coder/jayv-coder-mods)
import { normalizeCatalog, routeOf, type Catalog } from "./lib.ts";

const DEFAULT_REPOSITORY = "JayV-Coder/jayv-coder-mods";
// `dono/repositório`. Um valor malformado não derruba a função: vale o padrão,
// com aviso no log.
const configuredRepository = (Deno.env.get("MODS_REPOSITORY") ?? "").trim();
const REPOSITORY = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(configuredRepository) ? configuredRepository : DEFAULT_REPOSITORY;
if (configuredRepository && REPOSITORY !== configuredRepository) {
  console.error(`mods: MODS_REPOSITORY "${configuredRepository}" não está no formato dono/repositório; usando ${DEFAULT_REPOSITORY}`);
}
// Quanto tempo o catálogo vale em memória e no cache de quem pede.
const TTL_MS = 5 * 60_000;
const UPSTREAM_TIMEOUT_MS = 8_000;
// Um catálogo maior que isto não é um catálogo: a função fica com o último bom.
const MAX_BYTES = 2_000_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
};

function reply(status: number, body: unknown, maxAge = 300): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": status === 200 ? `public, max-age=${maxAge}, s-maxage=${maxAge}` : "no-store",
    },
  });
}

const refuse = (status: number, code: string, message: string) => reply(status, { error: message, code });

/** O último catálogo bom fica em memória no isolate; se o GitHub falhar ou o
 * catálogo vier quebrado, vale ele, mesmo vencido. */
let kept: { at: number; value: Catalog } | null = null;

async function catalog(): Promise<Catalog | null> {
  if (kept && Date.now() - kept.at < TTL_MS) return kept.value;
  try {
    const response = await fetch(`https://raw.githubusercontent.com/${REPOSITORY}/HEAD/catalog.json`, {
      headers: { Accept: "application/json", "User-Agent": "jayv-mods-function" },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`catalog.json: ${response.status}`);
    }
    const text = await response.text();
    if (text.length > MAX_BYTES) throw new Error(`catalog.json: ${text.length} bytes`);
    const value = normalizeCatalog(JSON.parse(text));
    if (!value) throw new Error("catalog.json: formato inesperado");
    kept = { at: Date.now(), value };
    return value;
  } catch (error) {
    if (kept) {
      console.error("mods: stale", error);
      return kept.value;
    }
    console.error("mods", error);
    return null;
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (request.method !== "GET" && request.method !== "HEAD") return refuse(405, "method", "só GET");
  const route = routeOf(new URL(request.url).pathname);
  if (!route) return refuse(404, "route", "rota desconhecida");
  const value = await catalog();
  if (!value) return refuse(502, "upstream", "o repositório de mods não respondeu");
  return reply(200, value);
});
