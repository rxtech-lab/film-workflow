import { beforeEach, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/auth", () => ({ isAdmin: () => true }));
const fixture = vi.hoisted(() => ({ create: vi.fn(), update: vi.fn(), metadata: {} as Record<string, unknown> }));
vi.mock("@/lib/marketplace/repository", () => ({
  getCategory: async () => ({ kind: "audio" }),
  insertItem: fixture.create,
  updateItem: fixture.update,
  requireItem: async () => ({ kind: "audio", contentKey: "song.mp3", metadata: fixture.metadata }),
}));
const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const tracks = [{ language: "en", cues: [{ start: 0, end: 1, text: "Hello" }] }, { language: "zh-Hans", cues: [{ start: 0, end: 1, text: "你好" }] }];
const admin = { id: "admin", name: "Admin", email: "", roles: ["admin"] };
beforeEach(() => {
  fixture.create.mockReset().mockResolvedValue({ id });
  fixture.update.mockReset();
  fixture.metadata = { durationSeconds: 90, lyricTracks: tracks, preview: { startSeconds: 30 } };
});

it("stores original and translated captions when a music draft is created", async () => {
  const { createItem } = await import("@/lib/marketplace/authoring");
  expect(await createItem(admin, { kind: "audio", categoryId: id, title: "Song", description: "", pricePoints: 0, metadata: { lyricTracks: tracks }, translations: {} })).toEqual({ ok: true, id });
  expect(fixture.create.mock.calls[0][0].metadata.lyricTracks).toEqual(tracks);
});

it("keeps captions from older clients, saves edits, and supports removing every language", async () => {
  const { updateItem } = await import("@/lib/marketplace/authoring");
  const input = { kind: "audio" as const, categoryId: id, title: "Song", description: "", pricePoints: 0, metadata: {}, translations: {} };
  expect(await updateItem(admin, id, input)).toEqual({ ok: true });
  expect(fixture.update.mock.calls.at(-1)?.[1].metadata).toMatchObject(fixture.metadata);
  expect(await updateItem(admin, id, { ...input, metadata: { lyricTracks: tracks.slice(0, 1) } })).toEqual({ ok: true });
  expect(fixture.update.mock.calls.at(-1)?.[1].metadata.lyricTracks).toEqual(tracks.slice(0, 1));
  expect(await updateItem(admin, id, { ...input, metadata: { lyricTracks: [] } })).toEqual({ ok: true });
  expect(fixture.update.mock.calls.at(-1)?.[1].metadata).toMatchObject({ durationSeconds: 90, lyricTracks: [], preview: { startSeconds: 30 } });
});
