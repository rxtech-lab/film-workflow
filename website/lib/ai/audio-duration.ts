import "server-only";

function u32be(data: Buffer, offset: number) { return data.readUInt32BE(offset); }

function wavDuration(data: Buffer) {
  if (data.length < 44 || data.toString("ascii", 0, 4) !== "RIFF" || data.toString("ascii", 8, 12) !== "WAVE") return null;
  let offset = 12;
  let bytesPerSecond = 0;
  let audioBytes = 0;
  while (offset + 8 <= data.length) {
    const kind = data.toString("ascii", offset, offset + 4);
    const size = data.readUInt32LE(offset + 4);
    if (kind === "fmt " && size >= 16 && offset + 8 + size <= data.length) bytesPerSecond = data.readUInt32LE(offset + 16);
    if (kind === "data") { audioBytes = Math.min(size, data.length - offset - 8); break; }
    offset += 8 + size + (size % 2);
  }
  return bytesPerSecond > 0 && audioBytes > 0 ? audioBytes / bytesPerSecond : null;
}

function flacDuration(data: Buffer) {
  if (data.length < 42 || data.toString("ascii", 0, 4) !== "fLaC") return null;
  let offset = 4;
  while (offset + 4 <= data.length) {
    const header = data[offset];
    const type = header & 0x7f;
    const size = data.readUIntBE(offset + 1, 3);
    if (type === 0 && size >= 34 && offset + 4 + size <= data.length) {
      const packed = data.subarray(offset + 14, offset + 22);
      const sampleRate = (packed[0] << 12) | (packed[1] << 4) | (packed[2] >> 4);
      const totalSamples = (packed[3] & 0x0f) * 2 ** 32 + packed.readUInt32BE(4);
      return sampleRate > 0 ? totalSamples / sampleRate : null;
    }
    offset += 4 + size;
    if (header & 0x80) break;
  }
  return null;
}

function mp4Duration(data: Buffer): number | null {
  for (let offset = 0; offset + 24 <= data.length;) {
    const size = u32be(data, offset);
    const kind = data.toString("ascii", offset + 4, offset + 8);
    if (kind === "moov" || kind === "trak" || kind === "mdia") {
      const nested: number | null = mp4Duration(data.subarray(offset + 8, size > 8 ? Math.min(data.length, offset + size) : data.length));
      if (nested) return nested;
    }
    if (kind === "mvhd") {
      const version = data[offset + 8];
      const base = version === 1 ? offset + 28 : offset + 20;
      if (base + (version === 1 ? 12 : 8) <= data.length) {
        const timescale = u32be(data, base);
        const duration = version === 1 ? Number(data.readBigUInt64BE(base + 4)) : u32be(data, base + 4);
        if (timescale > 0) return duration / timescale;
      }
    }
    if (size < 8) break;
    offset += size;
  }
  return null;
}

function mp3Duration(data: Buffer) {
  let offset = data.toString("ascii", 0, 3) === "ID3" && data.length >= 10
    ? 10 + ((data[6] & 0x7f) << 21) + ((data[7] & 0x7f) << 14) + ((data[8] & 0x7f) << 7) + (data[9] & 0x7f)
    : 0;
  const bitrateTable = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
  while (offset + 4 <= data.length) {
    const header = data.readUInt32BE(offset);
    if ((header & 0xffe00000) === 0xffe00000) {
      const bitrate = bitrateTable[(header >> 12) & 0xf] * 1000;
      if (bitrate > 0) return (data.length - offset) * 8 / bitrate;
    }
    offset += 1;
  }
  return null;
}

export function measuredAudioDurationSeconds(data: Buffer, mimeType = "") {
  const duration = wavDuration(data) ?? flacDuration(data) ?? mp4Duration(data) ?? mp3Duration(data);
  if (!duration || !Number.isFinite(duration) || duration <= 0) throw new Error(`AUDIO_DURATION_UNAVAILABLE:${mimeType}`);
  return duration;
}
