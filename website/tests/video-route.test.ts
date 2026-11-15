import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ reserve: vi.fn(), close: vi.fn(), insert: vi.fn(), read: vi.fn(), remove: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/auth/bearer", () => ({ requireApiUser: async () => ({ id: "user-a" }) }));
vi.mock("@/lib/ai/catalog", () => ({ requireCatalogModel: async (id: string) => ({ id, provider: "google" }), googleVideoPrice: () => ({ model: "gemini-omni-1.2-flash:720p" }) }));
vi.mock("@/lib/ai/google-models", () => ({ googleApiKey: () => "test-key" }));
vi.mock("@/lib/ai/video-jobs", () => ({ VIDEO_FEATURE: "Video · Google" }));
vi.mock("@/lib/ai/http", () => ({ noStoreHeaders: () => ({}), providerError: async () => { throw new Error("Provider rejected"); }, aiRouteError: (cause: Error) => Response.json({ error: cause.message }, { status: cause.message.startsWith("VIDEO_OPTIONS_INVALID") ? 400 : 502 }) }));
vi.mock("@/lib/billing/config", () => ({ billingConfig: { videoReservationPoints: 1 }, reserveWithMargin: (n: number) => n }));
vi.mock("@/lib/billing/unit-pricing", () => ({ estimateReservationPoints: () => 1000 }));
vi.mock("@/lib/billing/repository", () => ({ reserveCredits: mocks.reserve, closeReservation: mocks.close }));
vi.mock("@/lib/storage/s3", () => ({ getObjectBytes: mocks.read, deleteObject: mocks.remove }));
vi.mock("@/lib/db", () => ({ db: { insert: () => ({ values: mocks.insert }) } }));
vi.mock("@/lib/db/schema", () => ({ aiJobs: {} }));
import { POST } from "@/app/api/v1/ai/videos/route";
const input = { model: "gemini-omni-1.2-flash", prompt: "Sunset", aspect_ratio: "16:9", resolution: "720p", duration_seconds: 15, person_generation: "allow_adult" };
function request(patch = {}) { return new Request("http://localhost/api/v1/ai/videos", { method: "POST", body: JSON.stringify({ ...input, ...patch }) }); }
beforeEach(() => {
  vi.clearAllMocks();
  mocks.remove.mockResolvedValue(undefined);
  mocks.reserve.mockResolvedValue({ id: "reservation" });
  mocks.read.mockResolvedValue({ contentType: "image/png", bytes: Buffer.from("image") });
  vi.stubGlobal("fetch", vi.fn(async () => Response.json({ id: "omni123" })));
});
afterEach(() => vi.unstubAllGlobals());
describe("video submission", () => {
  it("persists a resumable interaction and keeps output out of the response", async () => {
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(mocks.insert).toHaveBeenCalledWith(expect.objectContaining({ requestJson: expect.objectContaining({ operationName: "interactions/omni123", durationSeconds: 15 }) }));
    expect(vi.mocked(fetch)).toHaveBeenCalledWith("https://generativelanguage.googleapis.com/v1beta/interactions", expect.objectContaining({ method: "POST" }));
    const options = vi.mocked(fetch).mock.calls[0][1];
    expect(JSON.parse(options?.body as string)).toMatchObject({ background: true, response_format: { delivery: "uri", duration: "15s" } });
  });
  it("resolves owned S3 images and cleans them after submission", async () => {
    const key = "video-inputs/user-a/frame";
    const response = await POST(request({ first_frame: { mime_type: "image/png", object_key: key } }));
    expect(response.status).toBe(202);
    expect(mocks.read).toHaveBeenCalledWith(key, 6_000_000);
    expect(mocks.remove).toHaveBeenCalledWith(key);
  });
  it("rejects another account's object before storage access, billing or Google", async () => {
    const response = await POST(request({ first_frame: { mime_type: "image/png", object_key: "video-inputs/user-b/frame" } }));
    expect(response.status).toBe(400);
    expect(mocks.read).not.toHaveBeenCalled();
    expect(mocks.reserve).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("rejects a 15-second interpolation before billing and still removes uploaded inputs", async () => {
    const frame = { mime_type: "image/png", object_key: "video-inputs/user-a/frame" };
    expect((await POST(request({ first_frame: frame, last_frame: frame }))).status).toBe(400);
    expect(mocks.reserve).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
    expect(mocks.remove).toHaveBeenCalled();
  });
  it("releases the reservation if Google rejects the submission", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("unavailable", { status: 503 })));
    expect((await POST(request())).status).toBe(502);
    expect(mocks.close).toHaveBeenCalledWith(expect.objectContaining({ reservationId: "reservation", success: false }));
    expect(mocks.insert).not.toHaveBeenCalled();
  });
});
