// deno test functions/mods/lib.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { FILES, MAX_MODS, normalizeCatalog, routeOf } from "./lib.ts";

Deno.test("the catalog routes with or without the function prefix", () => {
  assertEquals(routeOf("/mods/catalog"), { kind: "catalog", version: 1 });
  assertEquals(routeOf("/functions/v1/mods/catalog/"), { kind: "catalog", version: 1 });
  assertEquals(routeOf("/functions/v1/mods/catalog/v2"), { kind: "catalog", version: 2 });
  assertEquals(routeOf("/mods/catalog/v2/"), { kind: "catalog", version: 2 });
  assertEquals(routeOf("/mods"), null);
  assertEquals(routeOf("/mods/catalog/extra"), null);
  assertEquals(routeOf("/mods/catalog/v3"), null);
  assertEquals(FILES, { 1: "catalog.json", 2: "catalog.v2.json" });
});

Deno.test("an old catalog keeps its mods and drops the broken or repeated ones", () => {
  const stats = { id: "stats", kind: "feature", future: { kept: true } };
  const catalog = normalizeCatalog({
    schema: 1,
    mods: [stats, { id: "stats", kind: "feature" }, { id: "x" }, { kind: "llm" }, null, "claude", { id: "Bad Id", kind: "llm" }, { id: "claude", kind: "llm" }],
  });
  assertEquals(catalog, { schema: 1, mods: [stats, { id: "claude", kind: "llm" }] });
});

Deno.test("a generic catalog keeps the mods that bring something, once per id", () => {
  const pack = { id: "pack", version: "1.0.0", contributes: { features: ["stats"], agents: [{ kind: "api" }] }, future: true };
  const catalog = normalizeCatalog({
    schema: 2,
    mods: [pack, { id: "pack", contributes: { features: ["mcp"] } }, { id: "stats", kind: "feature" }, { id: "empty", contributes: {} }, { id: "list", contributes: [] }, { id: "mcp", contributes: { features: ["mcp"] } }],
  }, 2);
  assertEquals(catalog, { schema: 2, mods: [pack, { id: "mcp", contributes: { features: ["mcp"] } }] });
});

Deno.test("something that is not a catalog is null", () => {
  for (const value of [null, [], "x", { mods: [] }, { schema: 0, mods: [] }, { schema: 1.5, mods: [] }, { schema: 1, mods: {} }]) {
    assertEquals(normalizeCatalog(value), null);
    assertEquals(normalizeCatalog(value, 2), null);
  }
});

Deno.test("a newer schema passes as it is: the app and the site decide", () => {
  assertEquals(normalizeCatalog({ schema: 3, mods: [] }, 2), { schema: 3, mods: [] });
});

Deno.test("the catalog is capped", () => {
  const mods = Array.from({ length: MAX_MODS + 10 }, (_, index) => ({ id: `mod-${index}`, kind: "template", contributes: { features: ["stats"] } }));
  assertEquals(normalizeCatalog({ schema: 1, mods })?.mods.length, MAX_MODS);
  assertEquals(normalizeCatalog({ schema: 2, mods }, 2)?.mods.length, MAX_MODS);
});
