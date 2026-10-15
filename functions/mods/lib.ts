// O que a função `mods` faz sem rede: a rota e a limpeza do catálogo. Testado
// com `deno test functions/mods/lib.test.ts`.

/** `version` 2 é o catálogo genérico (`catalog.v2.json`): cada mod diz o que
 * traz a cada ponto de extensão do app (`contributes`). 1 é o formato antigo
 * (`catalog.json`), que o app 0.94 e o site 2.12 ainda leem. `pages` são as
 * páginas dos mods no site (`pages.json`), todas ou a de um mod; `media` é um
 * print de uma página (`mods/<id>/media/<arquivo>`). */
export type CatalogVersion = 1 | 2;
export type Route =
  | { kind: "catalog"; version: CatalogVersion }
  | { kind: "pages"; id: string | null }
  | { kind: "media"; id: string; file: string };

/** O arquivo das páginas no repositório. */
export const PAGES_FILE = "pages.json";
/** O nome de um print: `<nome>.<idioma>.webp`, como o validador do
 * repositório de mods aceita. */
export const MEDIA = /^[a-z0-9]+(?:-[a-z0-9]+)*\.[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,4})?\.webp$/;
/** Quanto um print pode ter; maior que isso a função não serve. */
export const MEDIA_MAX_BYTES = 1_000_000;

/** O arquivo do repositório de cada formato. */
export const FILES: Record<CatalogVersion, string> = { 1: "catalog.json", 2: "catalog.v2.json" };

/** A rota pedida, com ou sem o prefixo da função (`/functions/v1/mods`). */
export function routeOf(pathname: string): Route | null {
  const rest = pathname.replace(/^.*?\/mods(?=\/|$)/, "").replace(/\/+$/, "");
  if (rest === "/catalog") return { kind: "catalog", version: 1 };
  if (rest === "/catalog/v2") return { kind: "catalog", version: 2 };
  if (rest === "/pages") return { kind: "pages", id: null };
  const page = /^\/pages\/([^/]+)$/.exec(rest);
  if (page) return ID.test(page[1]) ? { kind: "pages", id: page[1] } : null;
  const media = /^\/media\/([^/]+)\/([^/]+)$/.exec(rest);
  if (media) return ID.test(media[1]) && MEDIA.test(media[2]) ? { kind: "media", id: media[1], file: media[2] } : null;
  return null;
}

export interface Pages {
  schema: number;
  pages: Record<string, unknown>;
}

/** As páginas como saem daqui: um objeto com `schema` e `pages` (id → página).
 * A página de um id inválido, ou que não é objeto, sai; o conteúdo de cada uma
 * passa como veio — o site confere o que lê. Nulo quando nem isso dá para ler. */
export function normalizePages(value: unknown): Pages | null {
  if (!isObject(value)) return null;
  const { schema, pages } = value as { schema?: unknown; pages?: unknown };
  if (typeof schema !== "number" || !Number.isInteger(schema) || schema < 1 || !isObject(pages)) return null;
  const kept: Record<string, unknown> = {};
  for (const [id, page] of Object.entries(pages)) {
    if (!ID.test(id) || !isObject(page)) continue;
    kept[id] = page;
    if (Object.keys(kept).length >= MAX_MODS) break;
  }
  return { schema, pages: kept };
}

export interface Catalog {
  schema: number;
  mods: Record<string, unknown>[];
}

/** Quantos mods o catálogo leva, no máximo. */
export const MAX_MODS = 500;
const ID = /^[a-z][A-Za-z0-9-]{1,39}$/;

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

/** A chave que não pode repetir: no formato antigo, o tipo e o id (um motor de
 * LLM e um recurso podiam ter o mesmo nome); no genérico, o id. Nula: o mod
 * não é um mod daquele formato. */
function keyOf(mod: Record<string, unknown>, version: CatalogVersion): string | null {
  const { id, kind, contributes } = mod as { id?: unknown; kind?: unknown; contributes?: unknown };
  if (typeof id !== "string" || !ID.test(id)) return null;
  if (version === 1) return typeof kind === "string" ? `${kind}:${id}` : null;
  return isObject(contributes) && Object.keys(contributes).length > 0 ? id : null;
}

/** O catálogo do repositório como ele sai daqui: um objeto com `schema` e a
 * lista `mods`. Um mod que não é do formato pedido (sem `id`; sem `kind` no
 * antigo, sem `contributes` no genérico) ou repetido sai; o resto do conteúdo
 * de cada mod passa como veio — quem o lê (o app e o site) confere os campos
 * que conhece e ignora o formato que não entende. Nulo quando nem isso dá
 * para ler: a função fica com o último catálogo bom. */
export function normalizeCatalog(value: unknown, version: CatalogVersion = 1): Catalog | null {
  if (!isObject(value)) return null;
  const { schema, mods } = value as { schema?: unknown; mods?: unknown };
  if (typeof schema !== "number" || !Number.isInteger(schema) || schema < 1 || !Array.isArray(mods)) return null;
  const seen = new Set<string>();
  const kept: Record<string, unknown>[] = [];
  for (const mod of mods) {
    if (!isObject(mod)) continue;
    const key = keyOf(mod, version);
    if (key === null || seen.has(key)) continue;
    seen.add(key);
    kept.push(mod);
    if (kept.length >= MAX_MODS) break;
  }
  return { schema, mods: kept };
}
