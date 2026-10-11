// deno test functions/mods/lib.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { MAX_MODS, normalizeCatalog, routeOf } from "./lib.ts";

Deno.test("the catalog route with or without the function prefix", () => {
  assertEquals(routeOf("/mods/catalog"), { kind: "catalog" });
  assertEquals(routeOf("/functions/v1/mods/catalog/"), { kind: "catalog" });
  assertEquals(routeOf("/mods"), null);
  assertEquals(routeOf("/mods/catalog/extra"), null);
});

Deno.test("a catalog keeps its mods and drops the broken or repeated ones", () => {
  const stats = { id: "stats", kind: "feature", future: { kept: true } };
  const catalog = normalizeCatalog({
    schema: 1,
    mods: [stats, { id: "stats", kind: "feature" }, { id: "x" }, { kind: "llm" }, null, "claude", { id: "Bad Id", kind: "llm" }, { id: "claude", kind: "llm" }],
  });
  assertEquals(catalog, { schema: 1, mods: [stats, { id: "claude", kind: "llm" }] });
});

Deno.test("something that is not a catalog is null", () => {
  for (const value of [null, [], "x", { mods: [] }, { schema: 0, mods: [] }, { schema: 1.5, mods: [] }, { schema: 1, mods: {} }]) {
    assertEquals(normalizeCatalog(value), null);
  }
});

Deno.test("a newer schema passes as it is: the app and the site decide", () => {
  assertEquals(normalizeCatalog({ schema: 2, mods: [] }), { schema: 2, mods: [] });
});

Deno.test("the catalog is capped", () => {
  const mods = Array.from({ length: MAX_MODS + 10 }, (_, index) => ({ id: `mod-${index}`, kind: "template" }));
  assertEquals(normalizeCatalog({ schema: 1, mods })?.mods.length, MAX_MODS);
});
