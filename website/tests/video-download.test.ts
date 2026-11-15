import { afterEach, expect, it, vi } from "vitest";
import { downloadVideo } from "@/lib/ai/video-download";

afterEach(() => vi.unstubAllGlobals());

it("retries the interrupted range without downloading earlier chunks again", async () => {
  const first = new Uint8Array(64 * 1024).fill(1);
  const ranges: string[] = [];
  let interrupted = false;
  vi.stubGlobal("fetch", vi.fn(async (_url, options) => {
    ranges.push(options.headers.Range);
    if (ranges.length === 1) return new Response(first, { status: 206, headers: { "content-range": "bytes 0-65535/65538", "content-type": "video/mp4" } });
    if (!interrupted) { interrupted = true; throw new DOMException("Timed out", "TimeoutError"); }
    return new Response(new Uint8Array([2, 3]), { status: 206, headers: { "content-range": "bytes 65536-65537/65538" } });
  }));
  const result = await downloadVideo("https://generativelanguage.googleapis.com/video", "test-key");
  expect(result.bytes.length).toBe(65538);
  expect([...result.bytes.subarray(-3)]).toEqual([1, 2, 3]);
  expect(ranges).toEqual(["bytes=0-65535", "bytes=65536-131071", "bytes=65536-131071"]);
});

it("accepts a full response from a server that ignores ranges", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response(new Uint8Array([1, 2, 3]))));
  expect((await downloadVideo("https://example.com/video", "test-key")).bytes.length).toBe(3);
});

it("assembles concurrent ranges in file order even when they finish out of order", async () => {
  const size = 64 * 1024;
  const finishes: number[] = [];
  vi.stubGlobal("fetch", vi.fn(async (_url, options) => {
    const offset = Number(options.headers.Range.match(/bytes=(\d+)/)[1]);
    const index = offset / size;
    if (index === 1) await new Promise((resolve) => setTimeout(resolve, 10));
    finishes.push(index);
    return new Response(new Uint8Array(size).fill(index), { status: 206, headers: { "content-range": `bytes ${offset}-${offset + size - 1}/${size * 3}` } });
  }));
  const result = await downloadVideo("https://example.com/video", "test-key");
  expect(finishes).toEqual([0, 2, 1]);
  expect([result.bytes[0], result.bytes[size], result.bytes[size * 2]]).toEqual([0, 1, 2]);
});

it("rejects an incorrect content range", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response(new Uint8Array([1]), { status: 206, headers: { "content-range": "bytes 10-10/11" } })));
  await expect(downloadVideo("https://example.com/video", "test-key")).rejects.toThrow("INVALID_VIDEO_RANGE");
});

it("bounds repeated timeouts to three attempts", async () => {
  const fetchMock = vi.fn(async () => { throw new DOMException("Timed out", "TimeoutError"); });
  vi.stubGlobal("fetch", fetchMock);
  await expect(downloadVideo("https://example.com/video", "test-key")).rejects.toThrow("Timed out");
  expect(fetchMock).toHaveBeenCalledTimes(3);
});
