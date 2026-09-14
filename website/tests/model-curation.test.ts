import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
// Importing the real module pulls next-auth in, which vitest cannot resolve; only `isAdmin` is used here.
vi.mock("@/lib/auth", () => ({ isAdmin: (user: { roles: string[] }) => user.roles.includes("admin") }));

type Row = {
  id: string;
  modelId: string;
  capability: string;
  displayNameOverride: string | null;
  enabled: boolean;
  isDefault: boolean;
  sortOrder: number;
};

function row(input: Partial<Row> & Pick<Row, "modelId" | "capability">): Row {
  return { id: `row-${input.modelId}`, displayNameOverride: null, enabled: true, isDefault: false, sortOrder: 0, ...input };
}

let curated: Row[] = [];
const inserted = vi.fn(async (rows: unknown[]) => rows);
const clearedCapability = vi.fn(async (capability: string) => curated.filter((row) => row.capability === capability));

vi.mock("@/lib/models/repository", () => ({
  enabledCatalogModels: async () => curated.filter((entry) => entry.enabled),
  listCatalogModels: async () => curated,
  insertCatalogModels: (rows: unknown[]) => inserted(rows),
  insertCatalogModel: async () => curated[0],
  deleteCatalogModelsForCapability: (capability: string) => clearedCapability(capability),
}));

/** The two chat models and one image model the stubbed gateway offers, all priced. */
const GATEWAY_MODELS = [
  { id: "openai/gpt-5.4-mini", name: "GPT-5.4 mini", type: "language", pricing: { input: "0.00000025", output: "0.000002" } },
  { id: "alibaba/qwen-3-14b", name: "Qwen3-14B", type: "language", pricing: { input: "0.00000008", output: "0.00000024" } },
  { id: "bfl/flux-pro-1.1", name: "FLUX 1.1 [pro]", type: "image", tags: ["image-generation"], pricing: { image: "0.04" } },
];

beforeEach(() => {
  curated = [];
  inserted.mockClear();
  clearedCapability.mockClear();
  vi.resetModules();
  process.env.AI_GATEWAY_API_KEY = "test-key";
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ data: GATEWAY_MODELS }), { status: 200, headers: { "content-type": "application/json" } })));
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("curated catalog", () => {
  it("offers only the models an admin added", async () => {
    curated = [row({ modelId: "openai/gpt-5.4-mini", capability: "chat" })];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    expect((await modelCatalog()).map((model) => model.id)).toEqual(["openai/gpt-5.4-mini"]);
  });

  it("offers nothing when nothing is curated, rather than falling back to discovery", async () => {
    const { discoveredCatalog, modelCatalog } = await import("@/lib/ai/catalog");
    expect((await discoveredCatalog()).length).toBeGreaterThan(0);
    expect(await modelCatalog()).toEqual([]);
  });

  it("leaves a disabled row out", async () => {
    curated = [
      row({ modelId: "openai/gpt-5.4-mini", capability: "chat" }),
      row({ modelId: "alibaba/qwen-3-14b", capability: "chat", enabled: false }),
    ];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    expect((await modelCatalog()).map((model) => model.id)).toEqual(["openai/gpt-5.4-mini"]);
  });

  it("prefers the admin's name but keeps the provider's live price", async () => {
    curated = [row({ modelId: "bfl/flux-pro-1.1", capability: "image", displayNameOverride: "House Image" })];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    const [model] = await modelCatalog();
    expect(model.displayName).toBe("House Image");
    // The estimate is never stored alongside the override — it comes from pricing every time.
    expect(model.estimate).toEqual({ unit: "images", pointsPerUnit: 40 });
    expect(model.provider).toBe("gateway");
  });

  it("drops a curated row the provider no longer offers", async () => {
    curated = [
      row({ modelId: "openai/gpt-5.4-mini", capability: "chat" }),
      row({ modelId: "vendor/retired-model", capability: "chat" }),
    ];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    expect((await modelCatalog()).map((model) => model.id)).toEqual(["openai/gpt-5.4-mini"]);
  });

  it("orders by the admin's sort order, not the provider's alphabet", async () => {
    curated = [
      row({ modelId: "alibaba/qwen-3-14b", capability: "chat", sortOrder: 5 }),
      row({ modelId: "openai/gpt-5.4-mini", capability: "chat", sortOrder: 1 }),
    ];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    expect((await modelCatalog()).map((model) => model.id)).toEqual(["openai/gpt-5.4-mini", "alibaba/qwen-3-14b"]);
  });

  it("marks the default and leaves the others unflagged", async () => {
    curated = [
      row({ modelId: "openai/gpt-5.4-mini", capability: "chat", isDefault: true }),
      row({ modelId: "alibaba/qwen-3-14b", capability: "chat" }),
    ];
    const { modelCatalog } = await import("@/lib/ai/catalog");
    const models = await modelCatalog();
    expect(models.filter((model) => model.isDefault).map((model) => model.id)).toEqual(["openai/gpt-5.4-mini"]);
    expect(models.find((model) => model.id === "alibaba/qwen-3-14b")?.isDefault).toBeUndefined();
  });

  it("refuses a model that is discovered but not curated", async () => {
    curated = [row({ modelId: "openai/gpt-5.4-mini", capability: "chat" })];
    const { requireCatalogModel } = await import("@/lib/ai/catalog");
    await expect(requireCatalogModel("openai/gpt-5.4-mini", "chat")).resolves.toMatchObject({ provider: "gateway" });
    await expect(requireCatalogModel("alibaba/qwen-3-14b", "chat")).rejects.toThrow(/MODEL_NOT_ALLOWED/);
  });
});

describe("curation authoring", () => {
  const admin = { id: "admin-1", name: "Admin", email: "admin@test", roles: ["admin"] };

  it("refuses to add a model no provider offers", async () => {
    const { addModel } = await import("@/lib/models/authoring");
    const result = await addModel(admin, { modelId: "vendor/not-real", capability: "chat" });
    expect(result).toEqual({ ok: false, error: "No provider offers that model for that capability right now." });
  });

  it("refuses to add a model under the wrong capability", async () => {
    const { addModel } = await import("@/lib/models/authoring");
    expect(await addModel(admin, { modelId: "openai/gpt-5.4-mini", capability: "image" })).toMatchObject({ ok: false });
  });

  it("rejects a non-admin", async () => {
    const { addModel } = await import("@/lib/models/authoring");
    await expect(addModel({ ...admin, roles: ["user"] }, { modelId: "openai/gpt-5.4-mini", capability: "chat" })).rejects.toThrow();
  });

  it("clears one capability and reports the count, leaving the others alone", async () => {
    curated = [
      row({ modelId: "openai/gpt-5.4-mini", capability: "chat" }),
      row({ modelId: "alibaba/qwen-3-14b", capability: "chat" }),
      row({ modelId: "bfl/flux-pro-1.1", capability: "image" }),
    ];
    const { removeAllForCapability } = await import("@/lib/models/authoring");
    expect(await removeAllForCapability(admin, { capability: "chat" })).toEqual({ ok: true, removed: 2 });
    expect(clearedCapability).toHaveBeenCalledWith("chat");
  });

  it("refuses to clear without a capability, so nothing can empty the whole catalog", async () => {
    const { removeAllForCapability } = await import("@/lib/models/authoring");
    expect(await removeAllForCapability(admin, {})).toMatchObject({ ok: false });
    expect(await removeAllForCapability(admin, { capability: "everything" })).toMatchObject({ ok: false });
    expect(clearedCapability).not.toHaveBeenCalled();
  });

  it("rejects a non-admin clearing a capability", async () => {
    const { removeAllForCapability } = await import("@/lib/models/authoring");
    await expect(removeAllForCapability({ ...admin, roles: ["user"] }, { capability: "chat" })).rejects.toThrow();
    expect(clearedCapability).not.toHaveBeenCalled();
  });

  it("adds only what is missing when topping the list up", async () => {
    curated = [row({ modelId: "openai/gpt-5.4-mini", capability: "chat" })];
    const { addAllDiscovered } = await import("@/lib/models/authoring");
    const result = await addAllDiscovered(admin, { capability: "chat" });
    expect(result).toMatchObject({ ok: true });
    expect(inserted).toHaveBeenCalledWith([{ modelId: "alibaba/qwen-3-14b", capability: "chat" }]);
  });
});
