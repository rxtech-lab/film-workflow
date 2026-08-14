import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

describe("S3 storage paths", () => {
  beforeEach(() => {
    process.env.S3_BUCKET = "film-workflow";
    process.env.S3_PUBLIC_URL = "https://media.filmstudio.rxlab.app/";
  });

  it("builds custom-domain URLs without exposing the S3 endpoint", async () => {
    const { publicObjectURL } = await import("@/lib/storage/s3");
    expect(publicObjectURL("music/user a/file.wav")).toBe(
      "https://media.filmstudio.rxlab.app/music/user%20a/file.wav",
    );
  });

  it("keeps the bucket out of the endpoint so keys are not doubled under it", async () => {
    // An endpoint ending in the bucket name makes the SDK write `<bucket>/<key>`, which no
    // publicObjectURL() ever points at — uploads succeed and every download 404s.
    const seen: Array<Record<string, unknown>> = [];
    vi.doMock("@aws-sdk/client-s3", () => ({
      S3Client: class { constructor(config: Record<string, unknown>) { seen.push(config); } send: () => Promise<void> = async () => {} },
      PutObjectCommand: class { constructor(public input: unknown) {} },
      GetObjectCommand: class {}, HeadObjectCommand: class {}, DeleteObjectCommand: class {},
    }));
    vi.resetModules();
    process.env.S3_ENDPOINT = "https://account.r2.cloudflarestorage.com/film-workflow";
    process.env.S3_ACCESS_KEY_ID = "key";
    process.env.S3_SECRET_ACCESS_KEY = "secret";
    const { putObject } = await import("@/lib/storage/s3");
    await putObject({ key: "music/user-a/song.mp3", body: Buffer.from("x"), contentType: "audio/mpeg" });
    expect(seen[0]?.endpoint).toBe("https://account.r2.cloudflarestorage.com");
    vi.doUnmock("@aws-sdk/client-s3");
    vi.resetModules();
  });

  it("accepts only transcription keys owned by the authenticated user", async () => {
    const { ownsTranscriptionObject } = await import("@/lib/storage/s3");
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-a/clip.m4a")).toBe(true);
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-b/clip.m4a")).toBe(false);
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-a/../user-b/clip.m4a")).toBe(false);
  });
});
