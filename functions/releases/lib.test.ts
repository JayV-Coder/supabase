// deno test functions/releases/lib.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { buildManual, manualIds, mergeChangelog, publicRelease, releaseFromBody, rewriteUpdater, routeOf } from "./lib.ts";

const BASE = "https://example.supabase.co/functions/v1/releases";
const REPO = "acme/app-releases";

const encode = (value: unknown) => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))));

Deno.test("routes with or without the function prefix", () => {
  assertEquals(routeOf("/releases/latest"), { kind: "latest" });
  assertEquals(routeOf("/functions/v1/releases/changelog/"), { kind: "changelog" });
  assertEquals(routeOf("/releases/manual"), { kind: "manual" });
  assertEquals(routeOf("/releases/updater"), { kind: "updater" });
  assertEquals(routeOf("/releases/download/v1.2.3/App_1.2.3_x64-setup.exe"), { kind: "download", tag: "v1.2.3", name: "App_1.2.3_x64-setup.exe" });
});

Deno.test("a download outside a release tag or with a path in the name is refused", () => {
  assertEquals(routeOf("/releases/download/main/file.exe"), null);
  assertEquals(routeOf("/releases/download/v1.2.3/..%2Fsecret"), null);
  assertEquals(routeOf("/releases/download/v1.2.3/a/b"), null);
  assertEquals(routeOf("/releases/whatever"), null);
  assertEquals(routeOf("/releases"), null);
});

Deno.test("the public release links every asset through the function", () => {
  const release = publicRelease({
    tag_name: "v1.2.3", draft: false, prerelease: false, published_at: "2026-10-05T12:00:00Z", body: null,
    assets: [{ name: "App_1.2.3_amd64.deb", size: 10, browser_download_url: "https://github.com/acme/app-releases/releases/download/v1.2.3/App_1.2.3_amd64.deb" }],
  }, BASE);
  assertEquals(release.version, "1.2.3");
  assertEquals(release.assets[0].url, `${BASE}/download/v1.2.3/App_1.2.3_amd64.deb`);
});

Deno.test("the changelog file wins and older release notes fill the gaps", () => {
  const published = { releases: [{ version: "1.1.0", date: "2026-10-02", items: [{ kind: "feature", id: "search", title: "Search" }, { kind: "bogus", id: "x" }] }] };
  const old = `notes\n<!-- whats-new: ${encode({ version: "1.0.0", date: "2026-09-01", items: [{ kind: "fix", id: "crash" }] })} -->`;
  const duplicate = `<!-- whats-new: ${encode({ version: "1.1.0", date: "2026-10-01", items: [] })} -->`;
  const list = mergeChangelog(published, [duplicate, old, null, "<!-- whats-new: !!! -->"]);
  assertEquals(list.map((release) => release.version), ["1.1.0", "1.0.0"]);
  assertEquals(list[0].items, [{ kind: "feature", id: "search", title: "Search", detail: null }]);
  assertEquals(list[0].date, "2026-10-02");
});

Deno.test("broken notes are ignored", () => {
  assertEquals(releaseFromBody(null), null);
  assertEquals(releaseFromBody(`<!-- whats-new: ${encode({ version: "x", date: "2026-01-01", items: [] })} -->`), null);
});

Deno.test("the manual keeps the index order and drops broken files", () => {
  const index = { version: "1.2.3", updatedAt: "2026-10-05", features: ["routing", "routing", "bad id", "gate"] };
  assertEquals(manualIds(index), ["routing", "gate"]);
  const manual = buildManual(index, [
    { id: "routing", category: "agents", since: "0.1.0", plan: "adaptiveRouting", commands: ["plan"], title: "Routing", summary: "Picks the agent.", usage: "Send a request." },
    { id: "gate", title: "Gate" },
  ], { commands: [{ id: "plan", kind: "chat", usage: "/plan", detail: "Plans first." }, { id: "bad", kind: "mouse", usage: "x", detail: "y" }] });
  assertEquals(manual.version, "1.2.3");
  assertEquals(manual.features.map((feature) => feature.id), ["routing"]);
  assertEquals(manual.commands.map((command) => command.id), ["plan"]);
});

Deno.test("the updater manifest only keeps packages from the releases repository, pinned to the tag", () => {
  const manifest = {
    version: "1.2.3", notes: "n", pub_date: "2026-10-05T12:00:00Z",
    platforms: {
      "linux-x86_64": { signature: "sig", url: `https://github.com/${REPO}/releases/download/v1.2.3/App_1.2.3_amd64.AppImage` },
      "darwin-aarch64": { signature: "sig", url: `https://github.com/${REPO}/releases/latest/download/App_aarch64.app.tar.gz` },
      "windows-x86_64": { signature: "sig", url: "https://evil.example/App.exe" },
      "linux-x86_64-deb": { signature: "sig", url: `https://github.com/${REPO}/releases/latest/download/a/b.deb` },
    },
  };
  assertEquals(rewriteUpdater(manifest, REPO, BASE, "v1.2.3"), {
    version: "1.2.3", notes: "n", pub_date: "2026-10-05T12:00:00Z",
    platforms: {
      "linux-x86_64": { signature: "sig", url: `${BASE}/download/v1.2.3/App_1.2.3_amd64.AppImage` },
      "darwin-aarch64": { signature: "sig", url: `${BASE}/download/v1.2.3/App_aarch64.app.tar.gz` },
    },
  });
  assertEquals(rewriteUpdater(null, REPO, BASE, "v1.2.3"), null);
});
