import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

type Job = {
  id: string;
  userId: string;
  reservationId: string | null;
  capability: "video";
  status: "queued" | "running" | "succeeded" | "failed" | "cancelled";
  requestJson: Record<string, unknown>;
  resultObjectKey: string | null;
  resultMeta: Record<string, unknown> | null;
  errorCode: string | null;
  errorMessage: string | null;
  progressPercent: number;
  createdAt: Date;
  updatedAt: Date;
};

function job(overrides: Partial<Job> = {}): Job {
  return {
    id: "job-1",
    userId: "user-a",
    reservationId: "res-1",
    capability: "video",
    status: "running",
    requestJson: { operationName: "models/veo-3.1/operations/abc", model: "veo-3.1-generate-001", priceModel: "veo-3.1-generate", durationSeconds: 8, numberOfVideos: 1 },
    resultObjectKey: null,
    resultMeta: null,
    errorCode: null,
    errorMessage: null,
    progressPercent: 5,
    createdAt: new Date(Date.now() - 60_000),
    updatedAt: new Date(),
    ...overrides,
  };
}

/**
 * Stands in for the drizzle query builder, which is chained and lazy. Every
 * `update().set().where()` is recorded; `lockWins` decides what the optimistic
 * lock's `.returning()` hands back, which is the whole point of these tests.
 */
function setup(options: { lockWins?: boolean } = {}) {
  const updates: Array<Record<string, unknown>> = [];
  const stored: Array<{ key: string; contentType: string; bytes: number }> = [];
  const usage: Array<Record<string, unknown>> = [];
  const reservations: Array<{ success: boolean }> = [];

  const builder = () => {
    const chain: Record<string, unknown> = {};
    chain.set = (values: Record<string, unknown>) => { updates.push(values); return chain; };
    chain.where = () => chain;
    chain.returning = async () => (options.lockWins === false ? [] : [{ id: "job-1" }]);
    // An un-awaited `.where()` still has to settle for the calls that do not
    // ask for `returning()`.
    chain.then = (resolve: (value: unknown) => unknown) => Promise.resolve([]).then(resolve);
    return chain;
  };

  vi.doMock("@/lib/db", () => ({ db: { update: () => builder() } }));
  vi.doMock("@/lib/db/schema", () => ({ aiJobs: { id: "id", userId: "user_id", status: "status", progressPercent: "progress_percent" } }));
  vi.doMock("drizzle-orm", () => ({ and: (...a: unknown[]) => a, eq: (...a: unknown[]) => a, lt: (...a: unknown[]) => a }));
  vi.doMock("@/lib/ai/google-models", () => ({ googleApiKey: () => "test-key" }));
  vi.doMock("@/lib/billing/repository", () => ({
    closeReservation: async ({ success }: { success: boolean }) => { reservations.push({ success }); },
  }));
  vi.doMock("@/lib/billing/usage", () => ({
    recordUnitUsage: async (input: Record<string, unknown>) => { usage.push(input); return { chargedPoints: 4200 }; },
  }));
  vi.doMock("@/lib/storage/s3", () => ({
    putObject: async ({ key, body, contentType }: { key: string; body: Buffer; contentType: string }) => {
      stored.push({ key, contentType, bytes: body.length });
      return { key };
    },
  }));
  return { updates, stored, usage, reservations };
}

const RUNNING = new Response(JSON.stringify({ done: false }), { status: 200 });

function doneOperation(uri = "https://generativelanguage.googleapis.com/v1beta/files/x:download") {
  return { done: true, response: { generateVideoResponse: { generatedSamples: [{ video: { uri, mimeType: "video/mp4" } }] } } };
}

beforeEach(() => vi.resetModules());
afterEach(() => vi.unstubAllGlobals());

describe("pollVideoJob", () => {
  it("only bumps the progress estimate while the operation is running", async () => {
    const { updates } = setup();
    vi.stubGlobal("fetch", vi.fn(async () => RUNNING.clone()));
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    expect(result.finalize).toBeUndefined();
    expect(result.job.status).toBe("running");
    // ~60s elapsed at one point per three seconds.
    expect(result.job.progressPercent).toBe(20);
    expect(updates[0]).toMatchObject({ progressPercent: 20 });
  });

  it("downloads, stores and bills the clip when it wins the lock", async () => {
    const { updates, stored, usage, reservations } = setup({ lockWins: true });
    const fetchMock = vi.fn(async (url: string) => {
      if (url.includes("/operations/")) return new Response(JSON.stringify(doneOperation()), { status: 200 });
      return new Response(new Uint8Array([1, 2, 3, 4]), { status: 200, headers: { "content-type": "video/mp4" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    // The poll itself returns immediately at the lock value.
    expect(result.job.progressPercent).toBe(90);
    expect(result.finalize).toBeTypeOf("function");

    await result.finalize!();
    expect(stored[0]).toMatchObject({ key: "videos/user-a/job-1.mp4", contentType: "video/mp4", bytes: 4 });
    expect(usage[0]).toMatchObject({ provider: "google", model: "veo-3.1-generate", capability: "video", unit: "video_seconds", units: 8 });
    expect(reservations).toEqual([{ success: true }]);
    expect(updates.at(-1)).toMatchObject({ status: "succeeded", progressPercent: 100, resultObjectKey: "videos/user-a/job-1.mp4" });
  });

  it("does not finalize twice when a second poll loses the lock", async () => {
    setup({ lockWins: false });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(doneOperation()), { status: 200 })));
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    expect(result.finalize).toBeUndefined();
    expect(result.job.progressPercent).toBe(90);
  });

  it("fails the job and releases the hold when the operation reports an error", async () => {
    const { updates, reservations } = setup();
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ done: true, error: { code: 400, message: "prompt rejected" } }), { status: 200 })));
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    expect(result.job.status).toBe("failed");
    expect(result.job.errorMessage).toBe("prompt rejected");
    expect(updates[0]).toMatchObject({ status: "failed" });
    expect(reservations).toEqual([{ success: false }]);
  });

  it("keeps the job running when Google itself has a bad minute", async () => {
    const { updates, reservations } = setup();
    vi.stubGlobal("fetch", vi.fn(async () => new Response("upstream", { status: 503 })));
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    expect(result.job.status).toBe("running");
    expect(updates).toEqual([]);
    expect(reservations).toEqual([]);
  });

  it("hands the lock back so the next poll retries a transient download failure", async () => {
    const { updates, reservations } = setup({ lockWins: true });
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (url.includes("/operations/")) return new Response(JSON.stringify(doneOperation()), { status: 200 });
      return new Response("busy", { status: 503 });
    }));
    const { pollVideoJob } = await import("@/lib/ai/video-jobs");

    const result = await pollVideoJob(job());
    await result.finalize!();
    // Back below the lock value, and the hold is left open for the retry.
    expect(updates.at(-1)).toMatchObject({ progressPercent: 50 });
    expect(reservations).toEqual([]);
  });
});
