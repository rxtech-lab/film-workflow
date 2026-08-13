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

  it("accepts only transcription keys owned by the authenticated user", async () => {
    const { ownsTranscriptionObject } = await import("@/lib/storage/s3");
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-a/clip.m4a")).toBe(true);
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-b/clip.m4a")).toBe(false);
    expect(ownsTranscriptionObject("user-a", "transcriptions/user-a/../user-b/clip.m4a")).toBe(false);
  });
});
