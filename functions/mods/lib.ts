// O que a função `mods` faz sem rede: a rota e a limpeza do catálogo. Testado
// com `deno test functions/mods/lib.test.ts`.

export type Route = { kind: "catalog" };

/** A rota pedida, com ou sem o prefixo da função (`/functions/v1/mods`). */
export function routeOf(pathname: string): Route | null {
  const rest = pathname.replace(/^.*?\/mods(?=\/|$)/, "").replace(/\/+$/, "");
  return rest === "/catalog" ? { kind: "catalog" } : null;
}

export interface Catalog {
  schema: number;
  mods: Record<string, unknown>[];
}

/** Quantos mods o catálogo leva, no máximo. */
export const MAX_MODS = 500;
const ID = /^[a-z][A-Za-z0-9-]{1,39}$/;

/** O catálogo do repositório como ele sai daqui: um objeto com `schema` e a
 * lista `mods`. Um mod sem `id` ou `kind` de texto, ou repetido, sai; o
 * resto do conteúdo de cada mod passa como veio — quem o lê (o app e o site)
 * confere os campos que conhece e ignora o formato que não entende. Nulo
 * quando nem isso dá para ler: a função fica com o último catálogo bom. */
export function normalizeCatalog(value: unknown): Catalog | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const { schema, mods } = value as { schema?: unknown; mods?: unknown };
  if (typeof schema !== "number" || !Number.isInteger(schema) || schema < 1 || !Array.isArray(mods)) return null;
  const seen = new Set<string>();
  const kept: Record<string, unknown>[] = [];
  for (const mod of mods) {
    if (typeof mod !== "object" || mod === null || Array.isArray(mod)) continue;
    const { id, kind } = mod as { id?: unknown; kind?: unknown };
    if (typeof id !== "string" || !ID.test(id) || typeof kind !== "string") continue;
    const key = `${kind}:${id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    kept.push(mod as Record<string, unknown>);
    if (kept.length >= MAX_MODS) break;
  }
  return { schema, mods: kept };
}
