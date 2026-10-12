// A única porta para o repositório público dos mods
// (`JayV-Coder/jayv-coder-mods`). O app e o site leem o catálogo por aqui,
// nunca direto do GitHub:
//   GET /catalog/v2  → o `catalog.v2.json` do ramo principal: o catálogo
//                      genérico, em que cada mod diz o que traz a cada ponto
//                      de extensão do app (`contributes`)
//   GET /catalog     → o `catalog.json`: o formato antigo, para o app 0.94 e o
//                      site 2.12
//
// Sem JWT (`verify_jwt = false`): o catálogo é público, como os releases. Os
// mods que cada pessoa cria ficam na conta dela (as tabelas sincronizadas do
// app), não aqui.
//
// Segredos opcionais (Edge Functions → Secrets):
//   MODS_REPOSITORY   outro repositório (padrão JayV-Coder/jayv-coder-mods)
import { FILES, normalizeCatalog, routeOf, type Catalog, type Route } from "./lib.ts";

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

/** O último catálogo bom de cada formato fica em memória no isolate; se o
 * GitHub falhar ou o catálogo vier quebrado, vale ele, mesmo vencido. */
const kept = new Map<Route["version"], { at: number; value: Catalog }>();

async function catalog(version: Route["version"]): Promise<Catalog | null> {
  const last = kept.get(version);
  if (last && Date.now() - last.at < TTL_MS) return last.value;
  const file = FILES[version];
  try {
    const response = await fetch(`https://raw.githubusercontent.com/${REPOSITORY}/HEAD/${file}`, {
      headers: { Accept: "application/json", "User-Agent": "jayv-mods-function" },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`${file}: ${response.status}`);
    }
    const text = await response.text();
    if (text.length > MAX_BYTES) throw new Error(`${file}: ${text.length} bytes`);
    const value = normalizeCatalog(JSON.parse(text), version);
    if (!value) throw new Error(`${file}: formato inesperado`);
    kept.set(version, { at: Date.now(), value });
    return value;
  } catch (error) {
    if (last) {
      console.error("mods: stale", error);
      return last.value;
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
  const value = await catalog(route.version);
  if (!value) return refuse(502, "upstream", "o repositório de mods não respondeu");
  return reply(200, value);
});
