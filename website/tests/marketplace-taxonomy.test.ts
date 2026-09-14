import { beforeEach, describe, expect, it, vi } from "vitest";

const fixtures = vi.hoisted(() => ({
  remove: vi.fn(), update: vi.fn(), revalidate: vi.fn(), admin: true,
}));
const categoryId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const admin = { id: "admin", name: "Admin", email: "", roles: ["admin"] };

vi.mock("server-only", () => ({}));
vi.mock("@/lib/auth", () => ({
  isAdmin: (user: { roles: string[] }) => user.roles.includes("admin"),
  requireAdminPageUser: async () => {
    if (!fixtures.admin) throw new Error("Forbidden");
    return { id: "admin", name: "Admin", email: "", roles: ["admin"] };
  },
}));
vi.mock("next/cache", () => ({ revalidatePath: fixtures.revalidate }));
vi.mock("next/navigation", () => ({ redirect: vi.fn() }));
vi.mock("@/lib/db", () => ({
  db: {
    delete: () => ({ where: () => ({ returning: fixtures.remove }) }),
    update: () => ({ set: (patch: object) => ({ where: () => ({ returning: () => fixtures.update(patch) }) }) }),
  },
}));

import { deleteCategory, updateCategory } from "@/lib/marketplace/authoring";
import * as actions from "@/lib/marketplace/actions";

beforeEach(() => {
  fixtures.admin = true;
  fixtures.remove.mockReset().mockResolvedValue([{ id: categoryId }]);
  fixtures.update.mockReset().mockImplementation(async (patch) => [{ id: categoryId, kind: "audio", slug: "relax", ...patch }]);
  fixtures.revalidate.mockReset();
});

describe("category editing and deletion", () => {
  it("saves the trimmed name and selected icon while keeping the slug", async () => {
    expect(await updateCategory(admin, { id: categoryId, name: " Lo-Fi ", icon: "waveform", slug: "changed" })).toEqual({
      ok: true, category: { id: categoryId, kind: "audio", slug: "relax", name: "Lo-Fi", icon: "waveform", translations: {} },
    });
    expect(fixtures.update.mock.calls[0][0]).not.toHaveProperty("slug");
  });

  it("saves the name in the other languages the app ships, alongside the row's own", async () => {
    expect(await updateCategory(admin, { id: categoryId, name: "Lo-Fi", icon: "waveform", translations: { "zh-Hans": { name: " 舒缓 " } } }))
      .toMatchObject({ ok: true, category: { name: "Lo-Fi", translations: { "zh-Hans": { name: "舒缓" } } } });
    expect(fixtures.update.mock.calls[0][0]).toMatchObject({ translations: { "zh-Hans": { name: "舒缓" } } });
  });

  it("uses the default symbol when the picker is cleared", async () => {
    expect(await updateCategory(admin, { id: categoryId, name: "Relax", icon: "" })).toMatchObject({ ok: true, category: { icon: "folder" } });
  });

  it("deletes an empty category and refreshes the taxonomy and item pages", async () => {
    expect(await actions.deleteCategory({ id: categoryId })).toEqual({ ok: true });
    expect(fixtures.remove).toHaveBeenCalledOnce();
    expect(fixtures.revalidate).toHaveBeenCalledWith("/admin/marketplace", "layout");
  });

  it.each([null, {}, { id: "bad-id" }])("rejects invalid deletion input before touching the database", async (input) => {
    expect(await deleteCategory(admin, input)).toEqual({ ok: false, error: "Invalid category." });
    expect(fixtures.remove).not.toHaveBeenCalled();
  });

  it("rejects non-admin deletion through both the service and page action", async () => {
    await expect(deleteCategory({ ...admin, roles: [] }, { id: categoryId })).rejects.toThrow("admin role");
    fixtures.admin = false;
    await expect(actions.deleteCategory({ id: categoryId })).rejects.toThrow("Forbidden");
    expect(fixtures.remove).not.toHaveBeenCalled();
  });

  it.each([
    Object.assign(new Error("foreign key violation"), { code: "23503" }),
    new Error("Failed query", { cause: { code: "23503" } }),
  ])("reports items, including drafts and concurrently added items, without deleting them", async (error) => {
    fixtures.remove.mockRejectedValue(error);
    expect(await actions.deleteCategory({ id: categoryId })).toEqual({
      ok: false, error: "This category still contains items, including drafts. Move them to another category before deleting it.",
    });
    expect(fixtures.revalidate).not.toHaveBeenCalled();
  });

  it("reports stale categories accurately for editing and deletion", async () => {
    fixtures.remove.mockResolvedValue([]);
    fixtures.update.mockResolvedValue([]);
    expect(await actions.deleteCategory({ id: categoryId })).toEqual({ ok: false, error: "This category no longer exists." });
    expect(await actions.updateCategory({ id: categoryId, name: "Relax", icon: "tag" })).toEqual({ ok: false, error: "This category no longer exists." });
    expect(fixtures.revalidate).not.toHaveBeenCalled();
  });
});
