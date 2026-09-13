import { fileExtension, type UploadRequest, type MarketplaceKind } from "./schema";

/** Verify storage facts and file signatures rather than trusting client metadata. */
export function validateAssetHeader(
  input: UploadRequest & { kind: MarketplaceKind },
  actual: { sizeBytes: number; contentType: string; header: Uint8Array }, maxBytes: number,
) {
  const fail = (reason: string): never => { throw new Error(`UPLOAD_INVALID:${reason}`); };
  if (actual.sizeBytes !== input.sizeBytes || actual.sizeBytes <= 0 || actual.sizeBytes > maxBytes) fail("The uploaded file size does not match or exceeds the limit.");
  if (actual.contentType.split(";")[0].toLowerCase() !== input.contentType.split(";")[0].toLowerCase()) fail("The uploaded content type does not match.");
  const b = Buffer.from(actual.header), ext = fileExtension(input.filename);
  const starts = (hex: string) => b.subarray(0, hex.length / 2).toString("hex") === hex;
  const ascii = (start: number, end: number) => b.subarray(start, end).toString("ascii");
  let valid = false;
  switch (ext) {
    case "json": valid = b.toString("utf8").trimStart().startsWith("{"); break;
    case "md": case "txt": valid = !b.includes(0); break;
    case "png": valid = starts("89504e470d0a1a0a"); break;
    case "jpg": case "jpeg": valid = starts("ffd8ff"); break;
    case "webp": valid = ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP"; break;
    case "wav": valid = ascii(0, 4) === "RIFF" && ascii(8, 12) === "WAVE"; break;
    case "webm": valid = starts("1a45dfa3"); break;
    case "mp4": case "mov": case "m4a": valid = ["ftyp", "moov", "mdat", "wide"].includes(ascii(4, 8)); break;
    case "mp3": valid = ascii(0, 3) === "ID3" || (b[0] === 255 && (b[1] & 224) === 224); break;
    case "aac": valid = b[0] === 255 && (b[1] & 240) === 240; break;
    case "ttf": valid = starts("00010000") || ascii(0, 4) === "true"; break;
    case "otf": valid = ascii(0, 4) === "OTTO"; break;
  }
  if (!valid) fail("The file contents do not match its extension.");
}
