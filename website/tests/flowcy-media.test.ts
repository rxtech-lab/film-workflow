import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("@/lib/auth/bearer", () => ({ requireApiUser: vi.fn(async () => ({ id: "user" })) }));
import { flowcyMedia } from "@/lib/ai/flowcy-media";
beforeEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.stubEnv("FILM_MEDIA_SHARED_SECRET", "test-shared-secret"); });
describe("Flowcy media migration", () => {
  it("forwards native bearer identity, options and idempotency without provider credentials", async () => {
    vi.stubEnv("FLOWCY_MEDIA_URL", "https://www.flowcy.dev");
    const fetcher = vi.fn().mockResolvedValue(new Response('{"job_id":"flowcy-one"}', { status: 202 })); vi.stubGlobal("fetch", fetcher);
    const response = await flowcyMedia(new Request("https://www.rxfilm.app/api/v1/ai/videos", { method: "POST", headers: { authorization: "Bearer native-token", "content-type": "application/json", "idempotency-key": "once" }, body: '{"prompt":"Tree"}' }), "/api/v1/ai/videos");
    expect(response.status).toBe(202);
    expect(String(fetcher.mock.calls[0][0])).toBe("https://www.flowcy.dev/api/v1/ai/videos");
    const options = fetcher.mock.calls[0][1];
    expect(options.headers.get("authorization")).toBe("Bearer native-token"); expect(options.headers.get("idempotency-key")).toBe("once");
    expect(options.body).toBe('{"prompt":"Tree"}'); expect(options.redirect).toBe("error");
  });
  it("requires a bearer token and preserves upstream failures", async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response('{"error":"Limited"}', { status: 429, headers: { "retry-after": "30" } })); vi.stubGlobal("fetch", fetcher);
    expect((await flowcyMedia(new Request("https://www.rxfilm.app"), "/api/v1/models")).status).toBe(401); expect(fetcher).not.toHaveBeenCalled();
    const response = await flowcyMedia(new Request("https://www.rxfilm.app", { headers: { authorization: "Bearer token" } }), "/api/v1/models");
    expect(response.status).toBe(429); expect(response.headers.get("retry-after")).toBe("30");
  });
});
