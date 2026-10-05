// O que a função `releases` faz sem rede: reconhecer a rota, conferir nomes,
// ler as novidades do corpo de um release e reescrever os links para que tudo
// passe por ela. Fica separado do `index.ts` para os testes (`lib.test.ts`).

/** Uma versão publicada como o site e o app a leem: os links já apontam para a
 * própria função (`/download/<tag>/<arquivo>`), nunca para o GitHub. */
export interface Asset { name: string; size: number; url: string }
export interface PublishedRelease { version: string; tag: string; publishedAt: string; assets: Asset[] }

export type ChangeKind = "feature" | "fix";
export interface ChangeItem { kind: ChangeKind; id: string; title: string | null; detail: string | null }
export interface ChangeRelease { version: string; date: string; items: ChangeItem[] }

/** Um comando do app: na caixa de mensagem (`chat`), no teclado (`shortcut`)
 * ou no terminal (`cli`). `usage` é o que se digita, igual em todo idioma. */
export interface ManualCommand { id: string; kind: "chat" | "shortcut" | "cli"; usage: string; detail: string }

/** Uma funcionalidade documentada. O texto vem em inglês; o site traduz pelas
 * chaves `docs.<id>.title`, `.summary` e `.usage`. */
export interface ManualFeature {
  id: string;
  category: string;
  /** A versão em que a funcionalidade chegou, quando se sabe. */
  since: string | null;
  /** A chave do recurso no catálogo dos planos, quando ele depende do plano. */
  plan: string | null;
  commands: string[];
  title: string;
  summary: string;
  usage: string;
}

export interface Manual { version: string | null; updatedAt: string | null; features: ManualFeature[]; commands: ManualCommand[] }

export type Route =
  | { kind: "latest" }
  | { kind: "changelog" }
  | { kind: "manual" }
  | { kind: "updater" }
  | { kind: "download"; tag: string; name: string };

const TAG = /^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/;
const ASSET = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,199}$/;
const ID = /^[A-Za-z][A-Za-z0-9]{0,63}$/;
const VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** A rota pedida, tirando o prefixo da função (`/releases` ou
 * `/functions/v1/releases`, conforme quem atende). Desconhecida, nulo. */
export function routeOf(pathname: string): Route | null {
  const rest = pathname.replace(/^.*?\/releases(?=\/|$)/, "").replace(/\/+$/, "");
  if (rest === "/latest") return { kind: "latest" };
  if (rest === "/changelog") return { kind: "changelog" };
  if (rest === "/manual") return { kind: "manual" };
  if (rest === "/updater") return { kind: "updater" };
  const download = /^\/download\/([^/]+)\/([^/]+)$/.exec(rest);
  if (download) {
    let tag: string, name: string;
    try {
      tag = decodeURIComponent(download[1]);
      name = decodeURIComponent(download[2]);
    } catch {
      return null;
    }
    if (TAG.test(tag) && ASSET.test(name)) return { kind: "download", tag, name };
  }
  return null;
}

/** O link de download pela função. */
export const downloadUrl = (base: string, tag: string, name: string) =>
  `${base}/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`;

interface GithubAsset { name: string; size: number; browser_download_url: string }
export interface GithubRelease { tag_name: string; draft: boolean; prerelease: boolean; published_at: string | null; body: string | null; assets: GithubAsset[] }

/** O release do GitHub como a função o devolve, com os links reescritos. */
export function publicRelease(release: GithubRelease, base: string): PublishedRelease {
  return {
    version: release.tag_name.replace(/^v/, ""),
    tag: release.tag_name,
    publishedAt: release.published_at ?? "",
    assets: release.assets
      .filter((asset) => ASSET.test(asset.name))
      .map((asset) => ({ name: asset.name, size: asset.size, url: downloadUrl(base, release.tag_name, asset.name) })),
  };
}

/** O endereço real de um arquivo de um release, só se ele existe ali. */
export function assetSource(release: GithubRelease | null | undefined, name: string): string | null {
  return release?.assets.find((asset) => asset.name === name)?.browser_download_url ?? null;
}

const text = (value: unknown, max = 4000) => (typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null);

function changeItem(value: unknown): ChangeItem | null {
  const item = value as Partial<ChangeItem> | null;
  if (!item || (item.kind !== "feature" && item.kind !== "fix") || typeof item.id !== "string" || !ID.test(item.id)) return null;
  return { kind: item.kind, id: item.id, title: text(item.title, 300), detail: text(item.detail) };
}

/** Uma versão do changelog, conferida campo a campo; quebrada, nulo. */
export function changeRelease(value: unknown): ChangeRelease | null {
  const release = value as Partial<ChangeRelease> | null;
  if (!release || typeof release.version !== "string" || !VERSION.test(release.version)) return null;
  if (typeof release.date !== "string" || !DAY.test(release.date) || !Array.isArray(release.items)) return null;
  return { version: release.version, date: release.date, items: release.items.map(changeItem).filter((item): item is ChangeItem => !!item) };
}

/** As novidades que o `release.yml` do app grava no corpo do release (um
 * comentário com JSON em base64), para os releases de antes do
 * `changelog.json`. */
export function releaseFromBody(body: string | null | undefined): ChangeRelease | null {
  const encoded = body?.match(/<!-- whats-new: ([A-Za-z0-9+/=]+) -->/)?.[1];
  if (!encoded) return null;
  try {
    const bytes = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
    return changeRelease(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    return null;
  }
}

/** Compara `MAJOR.MINOR.PATCH`, do mais novo para o mais antigo. */
export function newestFirst(a: { version: string }, b: { version: string }) {
  const parts = (version: string) => version.split("-")[0].split(".").map((part) => Number.parseInt(part, 10) || 0);
  const [left, right] = [parts(a.version), parts(b.version)];
  for (let index = 0; index < 3; index++) {
    const difference = (right[index] ?? 0) - (left[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

/** O changelog inteiro: o `changelog.json` publicado vale primeiro; versões
 * que só existem nas notas dos releases entram por baixo. */
export function mergeChangelog(published: unknown, bodies: (string | null)[]): ChangeRelease[] {
  const list = Array.isArray((published as { releases?: unknown } | null)?.releases) ? (published as { releases: unknown[] }).releases : [];
  const byVersion = new Map<string, ChangeRelease>();
  for (const value of list) {
    const release = changeRelease(value);
    if (release && !byVersion.has(release.version)) byVersion.set(release.version, release);
  }
  for (const body of bodies) {
    const release = releaseFromBody(body);
    if (release && !byVersion.has(release.version)) byVersion.set(release.version, release);
  }
  return [...byVersion.values()].sort(newestFirst);
}

function manualCommand(value: unknown): ManualCommand | null {
  const command = value as Partial<ManualCommand> | null;
  if (!command || typeof command.id !== "string" || !ID.test(command.id)) return null;
  if (command.kind !== "chat" && command.kind !== "shortcut" && command.kind !== "cli") return null;
  const usage = text(command.usage, 200);
  const detail = text(command.detail);
  return usage && detail ? { id: command.id, kind: command.kind, usage, detail } : null;
}

function manualFeature(value: unknown): ManualFeature | null {
  const feature = value as Partial<ManualFeature> | null;
  if (!feature || typeof feature.id !== "string" || !ID.test(feature.id)) return null;
  const title = text(feature.title, 300);
  const summary = text(feature.summary);
  const usage = text(feature.usage);
  if (!title || !summary || !usage) return null;
  return {
    id: feature.id,
    category: typeof feature.category === "string" && ID.test(feature.category) ? feature.category : "other",
    since: typeof feature.since === "string" && VERSION.test(feature.since) ? feature.since : null,
    plan: typeof feature.plan === "string" && ID.test(feature.plan) ? feature.plan : null,
    commands: Array.isArray(feature.commands) ? feature.commands.filter((id): id is string => typeof id === "string" && ID.test(id)) : [],
    title,
    summary,
    usage,
  };
}

/** A documentação montada a partir do índice, de cada arquivo de
 * funcionalidade e da lista de comandos. Arquivo quebrado fica de fora em vez
 * de derrubar a página inteira. */
export function buildManual(index: unknown, features: unknown[], commands: unknown): Manual {
  const head = (index ?? {}) as { version?: unknown; updatedAt?: unknown };
  const seen = new Set<string>();
  const list = features.map(manualFeature).filter((feature): feature is ManualFeature => {
    if (!feature || seen.has(feature.id)) return false;
    seen.add(feature.id);
    return true;
  });
  const commandList = Array.isArray((commands as { commands?: unknown } | null)?.commands) ? (commands as { commands: unknown[] }).commands : [];
  return {
    version: typeof head.version === "string" && VERSION.test(head.version) ? head.version : null,
    updatedAt: typeof head.updatedAt === "string" ? head.updatedAt : null,
    features: list,
    commands: commandList.map(manualCommand).filter((command): command is ManualCommand => !!command),
  };
}

/** Os ids de funcionalidade listados no índice, na ordem dele. */
export function manualIds(index: unknown): string[] {
  const features = (index as { features?: unknown } | null)?.features;
  if (!Array.isArray(features)) return [];
  return [...new Set(features.filter((id): id is string => typeof id === "string" && ID.test(id)))].slice(0, 200);
}

/** O `latest.json` do atualizador do Tauri com cada pacote baixado pela
 * função. O `tauri-action` escreve os links como `releases/latest/download/…`;
 * aqui eles ficam presos à tag do release de onde o manifesto saiu, para que
 * um release novo publicado no meio do download não troque o pacote que a
 * assinatura confere. Um link que não é do repositório fica de fora: o app não
 * baixa nada que não passe por aqui. */
export function rewriteUpdater(manifest: unknown, repository: string, base: string, tag: string): unknown {
  const value = manifest as { platforms?: Record<string, { url?: unknown; signature?: unknown }> } | null;
  if (!value || typeof value !== "object" || !value.platforms || typeof value.platforms !== "object" || !TAG.test(tag)) return null;
  const pinned = `https://github.com/${repository}/releases/download/`;
  const latest = `https://github.com/${repository}/releases/latest/download/`;
  const platforms: Record<string, { url: string; signature: unknown }> = {};
  for (const [platform, entry] of Object.entries(value.platforms)) {
    if (typeof entry?.url !== "string") continue;
    let parts: string[];
    try {
      parts = entry.url.startsWith(latest)
        ? [tag, decodeURIComponent(entry.url.slice(latest.length))]
        : entry.url.startsWith(pinned) ? entry.url.slice(pinned.length).split("/").map((part) => decodeURIComponent(part)) : [];
    } catch {
      continue;
    }
    const [from, name] = parts;
    if (parts.length !== 2 || !TAG.test(from) || !ASSET.test(name)) continue;
    platforms[platform] = { ...entry, url: downloadUrl(base, from, name), signature: entry.signature };
  }
  return { ...value, platforms };
}
