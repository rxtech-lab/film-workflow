import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ reserve: vi.fn(), insert: vi.fn(), delegate: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/auth/bearer", () => ({ requireApiUser: async () => ({ id: "user-a" }) }));
vi.mock("@/lib/ai/flowcy-media", () => ({ sharedMediaModel: async (_request: Request, id: string) => ({ id, provider: "google" }), sharedMediaRate: () => 100000000, flowcyMedia: mocks.delegate, mediaPayload: async (response: Response) => { if (!response.ok) throw new Error("SHARED_MEDIA_FAILURE"); return response.json(); } }));
vi.mock("@/lib/ai/video-jobs", () => ({ VIDEO_FEATURE: "Video · Google" }));
vi.mock("@/lib/ai/http", () => ({ noStoreHeaders: () => ({}), aiRouteError: (cause: Error) => Response.json({ error: cause.message }, { status: cause.message.startsWith("VIDEO_OPTIONS_INVALID") ? 400 : 502 }) }));
vi.mock("@/lib/billing/config", () => ({ billingConfig: { videoReservationPoints: 1 }, reserveWithMargin: (n: number) => n }));
vi.mock("@/lib/billing/unit-pricing", () => ({ pointsForNanoUsd: () => 1000 }));
vi.mock("@/lib/billing/repository", () => ({ reserveCredits: mocks.reserve }));
vi.mock("@/lib/db", () => ({ db: { insert: () => ({ values: (value: unknown) => { mocks.insert(value); return { onConflictDoNothing: async () => undefined }; } }) } }));
vi.mock("@/lib/db/schema", () => ({ aiJobs: {} }));
import { POST } from "@/app/api/v1/ai/videos/route";
const input = { model: "gemini-omni-1.2-flash", prompt: "Sunset", aspect_ratio: "16:9", resolution: "720p", duration_seconds: 15, person_generation: "allow_adult" };
const request = (patch = {}) => new Request("https://www.rxfilm.app/api/v1/ai/videos", { method: "POST", headers: { authorization: "Bearer token", "idempotency-key": "same" }, body: JSON.stringify({ ...input, ...patch }) });
beforeEach(() => { vi.clearAllMocks(); mocks.reserve.mockResolvedValue({ id: "reservation" }); mocks.delegate.mockImplementation(async () => Response.json({ job_id: "flowcy-one" })); });
describe("shared video submission retains Film Studio credits", () => {
  it("reserves credits before delegating and persists the remote handle", async () => {
    expect((await POST(request())).status).toBe(202);
    expect(mocks.reserve).toHaveBeenCalledWith(expect.objectContaining({ operationKey: "same", points: 1000 }));
    expect(mocks.insert).toHaveBeenCalledWith(expect.objectContaining({ id: "flowcy-one", reservationId: "reservation", requestJson: expect.objectContaining({ remoteJobId: "flowcy-one", durationSeconds: 15 }) }));
    expect(mocks.reserve.mock.invocationCallOrder[0]).toBeLessThan(mocks.delegate.mock.invocationCallOrder[0]);
  });
  it("forwards owned presigned inputs without downloading through the app server", async () => {
    const frame = { mime_type: "image/png", object_key: "ai-media/video-inputs/user-a/frame" };
    expect((await POST(request({ first_frame: frame }))).status).toBe(202);
    const delegated = mocks.delegate.mock.calls[0][0] as Request;
    expect((await delegated.json()).first_frame).toEqual(frame);
  });
  it("rejects another account's object before billing or delegation", async () => {
    expect((await POST(request({ first_frame: { mime_type: "image/png", object_key: "ai-media/video-inputs/user-b/frame" } }))).status).toBe(400);
    expect(mocks.reserve).not.toHaveBeenCalled(); expect(mocks.delegate).not.toHaveBeenCalled();
  });
  it("rejects invalid interpolation before billing", async () => {
    const frame = { mime_type: "image/png", object_key: "ai-media/video-inputs/user-a/frame" };
    expect((await POST(request({ first_frame: frame, last_frame: frame }))).status).toBe(400); expect(mocks.reserve).not.toHaveBeenCalled();
  });
  it("retains the reservation when remote submission is uncertain", async () => {
    mocks.delegate.mockResolvedValue(new Response("unavailable", { status: 503 }));
    expect((await POST(request())).status).toBe(502); expect(mocks.insert).not.toHaveBeenCalled();
  });
});
