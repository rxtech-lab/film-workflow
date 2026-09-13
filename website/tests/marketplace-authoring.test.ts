import { beforeEach, describe, expect, it, vi } from "vitest";
import { parseTemplate, projectTemplateDefinition, templateSummary } from "@/lib/marketplace/template";
import { validateAssetHeader } from "@/lib/marketplace/upload-validation";

vi.mock("server-only", () => ({}));
const fixtures = vi.hoisted(() => ({ user: null as null | { id: string; name: string; email: string; roles: string[] }, rows: new Map<string, Record<string, unknown>>(), updates: vi.fn(), status: vi.fn(), bytes: Buffer.from("{}"), header: Buffer.from("89504e470d0a1a0a", "hex"), size: 8, contentType: "image/png" }));
vi.mock("@/lib/auth", () => ({ getCurrentUser: async () => fixtures.user, isAdmin: (u: { roles: string[] }) => u.roles.includes("admin") }));
vi.mock("@/lib/marketplace/repository", () => ({
  getItem: async (id: string) => fixtures.rows.get(id), requireItem: async (id: string) => { const row = fixtures.rows.get(id); if (!row) throw new Error("NOT_FOUND"); return row; },
  updateItemAssets: fixtures.updates, setItemStatus: fixtures.status, getCategory: vi.fn(), insertCategory: vi.fn(), insertItem: vi.fn(), updateItem: vi.fn(), countPurchases: vi.fn(), deleteItemRow: vi.fn(),
  listAllCategories: async () => [], listAllItemsForAdmin: async () => ({ items: [], currentPage: 1, pageCount: 1, total: 0 }),
}));
vi.mock("@/lib/storage/s3", () => ({
  createPresignedUpload: vi.fn(), deleteObject: vi.fn(async () => {}), getObjectBytes: async () => ({ bytes: fixtures.bytes }),
  inspectObject: async (key: string) => ({ metadata: { author: "admin", role: key.includes("preview-video") ? "preview-video" : "content" }, header: fixtures.header, sizeBytes: fixtures.size, contentType: fixtures.contentType }),
  isMarketplaceObject: (id: string, key: string) => key.startsWith(`marketplace/${id}/`) && !key.includes(".."),
  marketplaceObjectKey: (id: string, role: string, name: string) => `marketplace/${id}/${role}/${name}`,
  marketplaceUploadLimits: { content: 100000, "preview-image": 100000, "preview-video": 100000 }, putObject: vi.fn(), objectDownloadURL: vi.fn(),
}));
const admin = { id: "admin", name: "Admin", email: "", roles: ["admin"] };
const itemId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const dependencyId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const template = () => ({ version: 1, prompt: "Make a travel video", videoStyle: "Warm colors", editingGuidance: "Adapt to the footage", width: 1920, height: 1080, fps: 30,
  shots: [{ id: "opening", title: "Opening", instructions: "Wide view", durationSeconds: 5, footageRequirementId: "landscape", effects: [] }],
  footageRequirements: [{ id: "landscape", title: "Landscape", mediaType: "video", required: true, instructions: "Provide a wide landscape shot" }], marketplaceItems: [] as { itemId: string; purpose: string; required: boolean }[] });
const item = (patch = {}) => ({ id: itemId, kind: "project_template", status: "draft", contentKey: "content.json", previewImageKey: "cover.png", previewVideoKey: "preview.mp4", metadata: { durationSeconds: 120, preview: { mock: true } }, ...patch });
beforeEach(() => { fixtures.user = admin; fixtures.rows.clear(); fixtures.rows.set(itemId, item()); fixtures.updates.mockReset(); fixtures.status.mockReset(); fixtures.bytes = Buffer.from(JSON.stringify(template())); fixtures.header = Buffer.from("89504e470d0a1a0a", "hex"); fixtures.size = 8; fixtures.contentType = "image/png"; });

describe("portable template definitions", () => {
  it("round-trips an adaptable recipe and publishes only complete definitions", () => {
    expect(parseTemplate(JSON.stringify(template()), true).shots[0].id).toBe("opening");
    expect(() => parseTemplate(JSON.stringify({ ...template(), prompt: "" }), true)).toThrow();
    expect(projectTemplateDefinition.parse({ ...template(), prompt: "", shots: [], footageRequirements: [] }).shots).toEqual([]);
  });
  it("rejects original project fields, file paths, duplicate IDs and unresolved references", () => {
    expect(projectTemplateDefinition.safeParse({ ...template(), sourcePath: "/Users/example/video.mov" }).success).toBe(false);
    expect(projectTemplateDefinition.safeParse({ ...template(), prompt: "Read /Users/example/video.mov" }).success).toBe(false);
    const duplicate = template(); duplicate.shots.push(duplicate.shots[0]); expect(projectTemplateDefinition.safeParse(duplicate).success).toBe(false);
    const broken = template(); broken.shots[0].footageRequirementId = "missing"; expect(projectTemplateDefinition.safeParse(broken).success).toBe(false);
  });
  it("public summaries omit the complete prompt and shot recipe", () => {
    const summary = templateSummary(projectTemplateDefinition.parse(template()));
    expect(summary.shotCount).toBe(1); expect(summary).not.toHaveProperty("prompt"); expect(summary).not.toHaveProperty("shots");
  });
});

describe("shared admin authoring", () => {
  it("rejects non-admin calls before reading or changing an item", async () => {
    const { publishItem } = await import("@/lib/marketplace/authoring");
    await expect(publishItem({ ...admin, roles: [] }, itemId, true)).rejects.toThrow("admin role");
    expect(fixtures.status).not.toHaveBeenCalled();
  });
  it("requires mock previews and complete content for template publication", async () => {
    const { publishItem } = await import("@/lib/marketplace/authoring");
    fixtures.rows.set(itemId, item({ metadata: { preview: { mock: false } } }));
    expect((await publishItem(admin, itemId, true)).ok).toBe(false);
    fixtures.rows.set(itemId, item());
    expect((await publishItem(admin, itemId, true)).ok).toBe(true);
    expect(fixtures.status).toHaveBeenCalledWith(itemId, "published");
  });
  it("rejects unpublished dependencies and allows published paid dependencies without granting them", async () => {
    const definition = template(); definition.marketplaceItems = [{ itemId: dependencyId, purpose: "Music", required: true }]; fixtures.bytes = Buffer.from(JSON.stringify(definition));
    const { publishItem } = await import("@/lib/marketplace/authoring");
    fixtures.rows.set(dependencyId, { id: dependencyId, kind: "audio", status: "draft", contentKey: "music.mp3", pricePoints: 200 });
    expect((await publishItem(admin, itemId, true)).ok).toBe(false);
    fixtures.rows.set(dependencyId, { ...fixtures.rows.get(dependencyId), status: "published" });
    expect((await publishItem(admin, itemId, true)).ok).toBe(true);
  });
  it("does not attach a file from another slot or item", async () => {
    const { finalizeUpload } = await import("@/lib/marketplace/authoring");
    const result = await finalizeUpload(admin, { itemId, role: "preview-image", filename: "cover.png", contentType: "image/png", sizeBytes: 8, objectKey: `marketplace/${itemId}/content/cover.png` });
    expect(result.ok).toBe(false); expect(fixtures.updates).not.toHaveBeenCalled();
  });
  it("keeps sample duration separate from full content duration", async () => {
    fixtures.rows.set(itemId, item({ kind: "audio" })); fixtures.header = Buffer.from("00000018667479706d703432", "hex"); fixtures.size = 12; fixtures.contentType = "video/mp4";
    const { finalizeUpload } = await import("@/lib/marketplace/authoring");
    const result = await finalizeUpload(admin, { itemId, role: "preview-video", filename: "sample.mp4", contentType: "video/mp4", sizeBytes: 12, objectKey: `marketplace/${itemId}/preview-video/sample.mp4`, metadata: { durationSeconds: 15, width: 720, height: 405 } });
    expect(result.ok).toBe(true);
    expect(fixtures.updates.mock.calls[0][1].metadata).toMatchObject({ durationSeconds: 120, preview: { durationSeconds: 15, width: 720, height: 405 } });
  });
});

describe("admin HTTP authorization", () => {
  it.each([null, { ...admin, roles: [] }])("rejects anonymous and regular-user writes", async (user) => {
    fixtures.user = user;
    const { POST } = await import("@/app/api/v1/admin/marketplace/[...path]/route");
    const response = await POST(new Request(`http://localhost/api/v1/admin/marketplace/items/${itemId}/publish`, { method: "POST", headers: { "Content-Type": "application/json" }, body: '{"published":true}' }), { params: Promise.resolve({ path: ["items", itemId, "publish"] }) });
    expect(response.status).toBe(user ? 403 : 401); expect(fixtures.status).not.toHaveBeenCalled();
  });
  it("allows admin capability lookup without billing", async () => {
    const { GET } = await import("@/app/api/v1/admin/marketplace/[...path]/route");
    const response = await GET(new Request("http://localhost/api/v1/admin/marketplace/capabilities"), { params: Promise.resolve({ path: ["capabilities"] }) });
    expect(response.status).toBe(200); expect(await response.json()).toEqual({ can_author: true, user_id: "admin" });
  });
});

describe("upload file verification", () => {
  it("checks actual sizes, MIME types and signatures", () => {
    const input = { itemId, kind: "footage" as const, role: "preview-image" as const, filename: "cover.png", contentType: "image/png", sizeBytes: 8 };
    const actual = { sizeBytes: 8, contentType: "image/png", header: Buffer.from("89504e470d0a1a0a", "hex") };
    expect(() => validateAssetHeader(input, actual, 20)).not.toThrow();
    expect(() => validateAssetHeader(input, { ...actual, sizeBytes: 9 }, 20)).toThrow();
    expect(() => validateAssetHeader(input, { ...actual, contentType: "text/plain" }, 20)).toThrow();
    expect(() => validateAssetHeader(input, { ...actual, header: Buffer.from("notapng!") }, 20)).toThrow();
  });
});
