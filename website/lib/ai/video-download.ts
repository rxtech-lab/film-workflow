const CHUNK_BYTES = 64 * 1024;
const MAX_BYTES = 300 * 1024 * 1024;

/** Small, bounded range requests keep slow transfers from restarting the entire video. */
export async function downloadVideo(uri: string, key: string) {
  const controller = new AbortController();
  const deadline = AbortSignal.any([controller.signal, AbortSignal.timeout(180_000)]);
  let total: number | undefined;
  let contentType: string | null = null;

  async function rangeAt(offset: number): Promise<Buffer> {
    for (let attempt = 0; ; attempt += 1) {
      try {
        const signal = AbortSignal.any([deadline, AbortSignal.timeout(30_000)]);
        let url = uri;
        for (let hop = 0; hop < 5; hop += 1) {
          const response = await fetch(url, {
            headers: { "x-goog-api-key": key, Range: `bytes=${offset}-${offset + CHUNK_BYTES - 1}`, "Accept-Encoding": "identity" },
            redirect: "manual", cache: "no-store", signal,
          });
          if (response.status >= 300 && response.status < 400) {
            const location = response.headers.get("location");
            await response.body?.cancel();
            if (!location) throw new Error("INVALID_PROVIDER_RESPONSE");
            url = new URL(location, url).toString();
            continue;
          }
          if (!response.ok) {
            await response.body?.cancel();
            throw new Error(`PROVIDER_${response.status}`);
          }
          const range = response.headers.get("content-range")?.match(/^bytes (\d+)-(\d+)\/(\d+)$/);
          if (response.status === 206) {
            if (!range || Number(range[1]) !== offset || Number(range[2]) < offset || Number(range[2]) >= offset + CHUNK_BYTES || Number(range[3]) <= Number(range[2]) || (total !== undefined && total !== Number(range[3]))) {
              await response.body?.cancel();
              throw new Error("INVALID_VIDEO_RANGE");
            }
            total = Number(range[3]);
          } else if (offset !== 0) {
            await response.body?.cancel();
            throw new Error("INVALID_VIDEO_RANGE");
          }
          if ((total ?? Number(response.headers.get("content-length"))) > MAX_BYTES) {
            await response.body?.cancel();
            throw new Error("VIDEO_TOO_LARGE");
          }
          const bytes = Buffer.from(await response.arrayBuffer());
          if (!bytes.length || (range && bytes.length !== Number(range[2]) - offset + 1)) throw new TypeError("Incomplete video download");
          if (bytes.length > MAX_BYTES) throw new Error("VIDEO_TOO_LARGE");
          contentType ??= response.headers.get("content-type");
          total ??= bytes.length; // Server ignored Range and returned the entire file.
          return bytes;
        }
        throw new Error("VIDEO_DOWNLOAD_REDIRECT_LOOP");
      } catch (cause) {
        const retryable = cause instanceof TypeError || (cause instanceof Error && (/^PROVIDER_(429|5\d\d)$/.test(cause.message) || ["AbortError", "TimeoutError"].includes(cause.name)));
        if (!retryable || attempt === 2 || deadline.aborted) throw cause;
      }
    }
  }

  try {
    const first = await rangeAt(0);
    const chunks = [first];
    let nextOffset = first.length;
    // Four workers bound request concurrency while keeping slow links moving.
    await Promise.all(Array.from({ length: 4 }, async () => {
      while (nextOffset < total!) {
        const offset = nextOffset;
        nextOffset += CHUNK_BYTES;
        const bytes = await rangeAt(offset);
        const expected = Math.min(CHUNK_BYTES, total! - offset);
        if (bytes.length !== expected) throw new TypeError("Incomplete video download");
        chunks[1 + Math.floor((offset - first.length) / CHUNK_BYTES)] = bytes;
      }
    }));
    return { bytes: Buffer.concat(chunks), contentType };
  } finally {
    controller.abort();
  }
}
