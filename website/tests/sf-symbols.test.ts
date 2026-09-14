import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { buildSymbolIndex } from "../scripts/generate-sf-symbol-index";
import SYMBOL_INDEX from "@/lib/sf-symbol-index.json";
import { SUGGESTED_SYMBOLS } from "@/lib/sf-symbols";
import { getSymbolDefinition, searchSymbols } from "@/lib/sf-symbols.server";
import { DEFAULT_CATEGORY_ICON, marketplaceKindDefaults } from "@/lib/marketplace/schema";
import { GET } from "@/app/api/sf-symbols/route";

describe("SF Symbols picker catalog", () => {
  it("keeps the name index aligned with the installed vector package", () => {
    expect(SYMBOL_INDEX).toEqual(buildSymbolIndex());
  });

  it("renders the suggestions and all marketplace defaults", () => {
    const defaults = Object.values(marketplaceKindDefaults).map((entry) => entry.icon);
    for (const name of [...SUGGESTED_SYMBOLS, DEFAULT_CATEGORY_ICON, ...defaults]) {
      expect(getSymbolDefinition(name)?.svgPathData.length, name).toBeGreaterThan(0);
    }
    expect(getSymbolDefinition("wand.and.stars")?.sourceName).toBe("wand.and.sparkles");
  });

  it("ranks exact matches first and understands multiword searches", () => {
    expect(searchSymbols("bolt", 80)[0]).toBe("bolt");
    expect(searchSymbols("bolt", 80)).toContain("cloud.bolt.fill");
    expect(searchSymbols("lock open")).toContain("lock.open.fill");
    expect(searchSymbols("LOCK_OPEN")).toContain("lock.open.fill");
    expect(searchSymbols("zzzz-nothing")).toEqual([]);
  });

  it("serves search results with a bounded limit", async () => {
    const response = GET(new Request("http://localhost/api/sf-symbols?q=film&limit=2"));
    expect(response.status).toBe(200);
    expect((await response.json()).results).toEqual(searchSymbols("film", 2));
    const bounded = GET(new Request("http://localhost/api/sf-symbols?limit=999999"));
    expect((await bounded.json()).results).toHaveLength(100);
  });

  it("serves real SVG vectors and rejects injected color attributes", async () => {
    const response = GET(new Request('http://localhost/api/sf-symbols?name=film&color=%22%20onload%3D%22alert(1)'));
    expect(response.headers.get("Content-Type")).toContain("image/svg+xml");
    const svg = await response.text();
    expect(svg).toContain("<path d=");
    expect(svg).not.toContain("onload");
  });

  it.each(["not.a.symbol", "__proto__", "constructor", "../../package.json"])("returns a safe 404 for %s", (name) => {
    expect(GET(new Request(`http://localhost/api/sf-symbols?name=${encodeURIComponent(name)}`)).status).toBe(404);
  });
});
