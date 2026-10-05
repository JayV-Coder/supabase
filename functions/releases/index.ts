// A única porta para o repositório público de releases do app
// (`JayV-Coder/jayv-coder-releases`). O site e o app leem tudo por aqui, nunca
// direto do GitHub:
//   GET /latest                 → a última versão publicada e os instaladores
//   GET /changelog              → o que cada versão trouxe (a janela "Novidades")
//   GET /manual                 → a documentação: funcionalidades e comandos
//   GET /updater                → o `latest.json` do atualizador do Tauri
//   GET /download/<tag>/<nome>  → 302 para o arquivo daquele release
//
// Sem JWT (`verify_jwt = false`): é tudo público. A função só repassa o que
// existe no repositório: o download confere que o arquivo pertence ao release
// pedido, então ela não vira redirecionador para endereço qualquer.
//
// Segredos opcionais (Edge Functions → Secrets):
//   RELEASES_REPOSITORY    outro repositório (padrão JayV-Coder/jayv-coder-releases)
//   RELEASES_GITHUB_TOKEN  token só de leitura, para não depender do limite de
//                          60 pedidos por hora da API sem token
import {
  assetSource, buildManual, type GithubRelease, manualIds, mergeChangelog, newestFirst, publicRelease, rewriteUpdater, routeOf,
} from "./lib.ts";

const DEFAULT_REPOSITORY = "JayV-Coder/jayv-coder-releases";
// `dono/repositório`. Um valor sem o dono (só "jayv-coder-releases") ou
// malformado não pode derrubar a função: vale o padrão, com aviso no log.
const configuredRepository = (Deno.env.get("RELEASES_REPOSITORY") ?? "").trim();
const REPOSITORY = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(configuredRepository) ? configuredRepository : DEFAULT_REPOSITORY;
if (configuredRepository && REPOSITORY !== configuredRepository) {
  console.error(`releases: RELEASES_REPOSITORY "${configuredRepository}" não está no formato dono/repositório; usando ${DEFAULT_REPOSITORY}`);
}
// Token só de leitura. Se o GitHub o recusar (401: vencido, revogado ou
// colado errado), a função passa a pedir sem token em vez de falhar.
let token = (Deno.env.get("RELEASES_GITHUB_TOKEN") ?? "").trim();
const BASE = `${Deno.env.get("SUPABASE_URL") ?? ""}/functions/v1/releases`;
// Quanto tempo a resposta do GitHub vale em memória e no cache de quem pede.
const TTL_MS = 5 * 60_000;
const UPSTREAM_TIMEOUT_MS = 8_000;

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

/** Cada leitura do GitHub fica em memória no isolate; se o GitHub falhar, vale
 * a última resposta boa, mesmo vencida. */
const memory = new Map<string, { at: number; value: unknown }>();

async function remember<T>(key: string, load: () => Promise<T>): Promise<T> {
  const kept = memory.get(key);
  if (kept && Date.now() - kept.at < TTL_MS) return kept.value as T;
  try {
    const value = await load();
    memory.set(key, { at: Date.now(), value });
    return value;
  } catch (error) {
    if (kept) {
      console.error("releases: stale", key, error);
      return kept.value as T;
    }
    throw error;
  }
}

class Missing extends Error {}

async function upstream(url: string, accept: string, authorized: boolean): Promise<Response> {
  const headers: Record<string, string> = { Accept: accept, "User-Agent": "jayv-releases-function" };
  if (authorized && token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
  if (response.status === 401 && headers.Authorization) {
    await response.body?.cancel();
    console.error("releases: o GitHub recusou RELEASES_GITHUB_TOKEN (401); seguindo sem token");
    token = "";
    return upstream(url, accept, false);
  }
  if (response.status === 404) {
    await response.body?.cancel();
    throw new Missing(url);
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`${url}: ${response.status}`);
  }
  return response;
}

/** Os releases publicados (sem rascunho nem prévia), do mais novo ao mais antigo. */
function releases(): Promise<GithubRelease[]> {
  return remember("releases", async () => {
    const response = await upstream(`https://api.github.com/repos/${REPOSITORY}/releases?per_page=100`, "application/vnd.github+json", true);
    const list = (await response.json()) as GithubRelease[];
    return list
      .filter((release) => !release.draft && !release.prerelease)
      .sort((a, b) => newestFirst({ version: a.tag_name.replace(/^v/, "") }, { version: b.tag_name.replace(/^v/, "") }));
  });
}

/** Um arquivo JSON do ramo principal do repositório; ausente, nulo. */
function file(path: string): Promise<unknown> {
  return remember(`file:${path}`, async () => {
    try {
      const response = await upstream(`https://raw.githubusercontent.com/${REPOSITORY}/HEAD/${path}`, "application/json", false);
      return await response.json();
    } catch (error) {
      if (error instanceof Missing) return null;
      throw error;
    }
  });
}

async function latest(): Promise<Response> {
  const [newest] = await releases();
  if (!newest) return refuse(404, "release", "nenhum release publicado");
  return reply(200, publicRelease(newest, BASE));
}

async function changelog(): Promise<Response> {
  const [published, list] = await Promise.all([file("changelog.json"), releases().catch(() => [] as GithubRelease[])]);
  return reply(200, { releases: mergeChangelog(published, list.map((release) => release.body)) });
}

async function manual(): Promise<Response> {
  const [index, commands] = await Promise.all([file("manual/index.json"), file("manual/commands.json")]);
  const ids = manualIds(index);
  const features = await Promise.all(ids.map((id) => file(`manual/features/${id}.json`).catch(() => null)));
  return reply(200, buildManual(index, features, commands));
}

async function updater(): Promise<Response> {
  const [newest] = await releases();
  const source = assetSource(newest, "latest.json");
  if (!newest || !source) return refuse(404, "release", "nenhum latest.json publicado");
  const manifest = await remember(`updater:${newest.tag_name}`, async () => (await upstream(source, "application/json", false)).json());
  const rewritten = rewriteUpdater(manifest, REPOSITORY, BASE, newest.tag_name);
  if (!rewritten) return refuse(502, "manifest", "latest.json inválido");
  // O atualizador pergunta a cada abertura do app: um minuto basta.
  return reply(200, rewritten, 60);
}

async function download(tag: string, name: string): Promise<Response> {
  let release = (await releases()).find((known) => known.tag_name === tag);
  if (!release) {
    release = await remember(`tag:${tag}`, async () => {
      try {
        const response = await upstream(`https://api.github.com/repos/${REPOSITORY}/releases/tags/${encodeURIComponent(tag)}`, "application/vnd.github+json", true);
        const found = (await response.json()) as GithubRelease;
        return found.draft ? undefined : found;
      } catch (error) {
        if (error instanceof Missing) return undefined;
        throw error;
      }
    });
  }
  const target = assetSource(release, name);
  if (!target) return refuse(404, "asset", "arquivo não encontrado neste release");
  return new Response(null, { status: 302, headers: { ...CORS, Location: target, "Cache-Control": "public, max-age=300" } });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (request.method !== "GET" && request.method !== "HEAD") return refuse(405, "method", "só GET");
  const route = routeOf(new URL(request.url).pathname);
  if (!route) return refuse(404, "route", "rota desconhecida");
  try {
    switch (route.kind) {
      case "latest": return await latest();
      case "changelog": return await changelog();
      case "manual": return await manual();
      case "updater": return await updater();
      case "download": return await download(route.tag, route.name);
    }
  } catch (error) {
    console.error("releases", route.kind, error);
    return refuse(502, "upstream", "o repositório de releases não respondeu");
  }
});
