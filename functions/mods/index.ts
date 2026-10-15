// A única porta para o repositório público dos mods
// (`JayV-Coder/jayv-coder-mods`). O app e o site leem o catálogo por aqui,
// nunca direto do GitHub:
//   GET /catalog/v2          → o `catalog.v2.json` do ramo principal: o catálogo
//                              genérico, em que cada mod diz o que traz a cada
//                              ponto de extensão do app (`contributes`)
//   GET /catalog             → o `catalog.json`: o formato antigo, para o app
//                              0.94 e o site 2.12
//   GET /pages               → o `pages.json`: a página de cada mod no site (o
//                              que ele faz, como habilitar e como usar)
//   GET /pages/<id>          → a página de um mod
//   GET /media/<id>/<print>  → um print de uma página (`<nome>.<idioma>.webp`),
//                              com cache longo: o site pede com `?v=<marca>`
//
// Sem JWT (`verify_jwt = false`): o catálogo é público, como os releases. Os
// mods que cada pessoa cria ficam na conta dela (as tabelas sincronizadas do
// app), não aqui.
//
// Segredos opcionais (Edge Functions → Secrets):
//   MODS_REPOSITORY   outro repositório (padrão JayV-Coder/jayv-coder-mods)
import {
  type CatalogVersion, FILES, MEDIA_MAX_BYTES, normalizeCatalog, normalizePages, PAGES_FILE, type Catalog, type Pages, routeOf,
} from "./lib.ts";

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
// O print muda de nome (`?v=`) quando muda de conteúdo: o cache pode ser longo.
const MEDIA_MAX_AGE = 7 * 86_400;
// Quantos prints ficam em memória no isolate.
const MEDIA_KEPT = 120;

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

const raw = (path: string) => fetch(`https://raw.githubusercontent.com/${REPOSITORY}/HEAD/${path}`, {
  headers: { "User-Agent": "jayv-mods-function" },
  signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
});

/** O último arquivo bom de cada tipo fica em memória no isolate; se o GitHub
 * falhar ou o arquivo vier quebrado, vale ele, mesmo vencido. */
const kept = new Map<string, { at: number; value: unknown }>();

async function remember<T>(key: string, file: string, read: (value: unknown) => T | null): Promise<T | null> {
  const last = kept.get(key) as { at: number; value: T } | undefined;
  if (last && Date.now() - last.at < TTL_MS) return last.value;
  try {
    const response = await raw(file);
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`${file}: ${response.status}`);
    }
    const text = await response.text();
    if (text.length > MAX_BYTES) throw new Error(`${file}: ${text.length} bytes`);
    const value = read(JSON.parse(text));
    if (!value) throw new Error(`${file}: formato inesperado`);
    kept.set(key, { at: Date.now(), value });
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

const catalog = (version: CatalogVersion) => remember<Catalog>(`catalog:${version}`, FILES[version], (value) => normalizeCatalog(value, version));
const pages = () => remember<Pages>("pages", PAGES_FILE, normalizePages);

/** Os prints lidos por último, do mais velho ao mais novo. */
const images = new Map<string, Uint8Array<ArrayBuffer>>();

async function media(id: string, file: string): Promise<Uint8Array<ArrayBuffer> | null> {
  const key = `${id}/${file}`;
  const known = images.get(key);
  if (known) {
    images.delete(key);
    images.set(key, known);
    return known;
  }
  try {
    const response = await raw(`mods/${id}/media/${file}`);
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > MEDIA_MAX_BYTES) return null;
    images.set(key, bytes);
    while (images.size > MEDIA_KEPT) images.delete(images.keys().next().value!);
    return bytes;
  } catch (error) {
    console.error("mods media", key, error);
    return null;
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (request.method !== "GET" && request.method !== "HEAD") return refuse(405, "method", "só GET");
  const route = routeOf(new URL(request.url).pathname);
  if (!route) return refuse(404, "route", "rota desconhecida");
  if (route.kind === "catalog") {
    const value = await catalog(route.version);
    return value ? reply(200, value) : refuse(502, "upstream", "o repositório de mods não respondeu");
  }
  if (route.kind === "pages") {
    const value = await pages();
    if (!value) return refuse(502, "upstream", "o repositório de mods não respondeu");
    if (route.id === null) return reply(200, value);
    const page = value.pages[route.id];
    return page ? reply(200, { schema: value.schema, id: route.id, page }) : refuse(404, "page", "mod sem página");
  }
  const bytes = await media(route.id, route.file);
  if (!bytes) return refuse(404, "media", "print não encontrado");
  return new Response(request.method === "HEAD" ? null : bytes, {
    status: 200,
    headers: { ...CORS, "Content-Type": "image/webp", "Cache-Control": `public, max-age=${MEDIA_MAX_AGE}, s-maxage=${MEDIA_MAX_AGE}, immutable` },
  });
});
