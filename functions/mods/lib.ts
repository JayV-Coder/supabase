// O que a função `mods` faz sem rede: a rota e a limpeza do catálogo. Testado
// com `deno test functions/mods/lib.test.ts`.

/** `version` 2 é o catálogo genérico (`catalog.v2.json`): cada mod diz o que
 * traz a cada ponto de extensão do app (`contributes`). 1 é o formato antigo
 * (`catalog.json`), que o app 0.94 e o site 2.12 ainda leem. */
export type Route = { kind: "catalog"; version: 1 | 2 };

/** O arquivo do repositório de cada formato. */
export const FILES: Record<Route["version"], string> = { 1: "catalog.json", 2: "catalog.v2.json" };

/** A rota pedida, com ou sem o prefixo da função (`/functions/v1/mods`). */
export function routeOf(pathname: string): Route | null {
  const rest = pathname.replace(/^.*?\/mods(?=\/|$)/, "").replace(/\/+$/, "");
  if (rest === "/catalog") return { kind: "catalog", version: 1 };
  if (rest === "/catalog/v2") return { kind: "catalog", version: 2 };
  return null;
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
function keyOf(mod: Record<string, unknown>, version: Route["version"]): string | null {
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
export function normalizeCatalog(value: unknown, version: Route["version"] = 1): Catalog | null {
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
