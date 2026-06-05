import Foundation

/// Joins the per-batch audio chunks returned by `AzureTTSClient` back into a single file.
///
/// Azure's real-time endpoint can only synthesize ~10 minutes of audio per request, so long
/// projects are split into batches and synthesized separately. Both output formats we request
/// can be concatenated losslessly:
///   • MP3 (`audio-24khz-48kbitrate-mono-mp3`) is constant-bitrate, so frames concatenate directly.
///   • WAV (`riff-24khz-16bit-mono-pcm`) needs the RIFF headers merged: take the format from the
///     first chunk, concatenate every `data` payload, and rewrite the chunk sizes.
nonisolated enum AzureAudioStitcher {
    enum StitchError: LocalizedError {
        case invalidWAV

        var errorDescription: String? {
            switch self {
            case .invalidWAV:
                return "Failed to stitch the generated audio: a WAV chunk was malformed."
            }
        }
    }

    static func stitch(_ chunks: [Data], format: AzureAudioFormat) throws -> Data {
        let nonEmpty = chunks.filter { !$0.isEmpty }
        guard nonEmpty.count > 1 else {
            return nonEmpty.first ?? Data()
        }

        switch format {
        case .mp3:
            // CBR MP3 frames are self-delimiting, so a byte-wise concatenation plays as one stream.
            var out = Data()
            for chunk in nonEmpty { out.append(chunk) }
            return out
        case .wav:
            return try stitchWAV(nonEmpty)
        }
    }

    // MARK: - WAV

    private static func stitchWAV(_ chunks: [Data]) throws -> Data {
        var fmtChunk: Data?
        var pcm = Data()

        for chunk in chunks {
            guard let parsed = parseWAV(chunk) else { throw StitchError.invalidWAV }
            if fmtChunk == nil { fmtChunk = parsed.fmt }
            pcm.append(parsed.data)
        }

        guard let fmt = fmtChunk else { throw StitchError.invalidWAV }

        let dataSize = UInt32(pcm.count)
        // RIFF size = 4 ("WAVE") + (8 + fmt payload) + (8 + data payload).
        let riffChunkSize = 4 + (8 + UInt32(fmt.count)) + (8 + dataSize)

        var out = Data()
        out.append(ascii("RIFF"))
        out.append(uint32LE(riffChunkSize))
        out.append(ascii("WAVE"))
        out.append(ascii("fmt "))
        out.append(uint32LE(UInt32(fmt.count)))
        out.append(fmt)
        out.append(ascii("data"))
        out.append(uint32LE(dataSize))
        out.append(pcm)
        return out
    }

    /// Extracts the `fmt ` payload and the `data` payload from a RIFF/WAVE container, skipping any
    /// other chunks (e.g. `fact`, `LIST`) that Azure may include.
    private static func parseWAV(_ data: Data) -> (fmt: Data, data: Data)? {
        guard data.count >= 12,
              readASCII(data, at: 0, length: 4) == "RIFF",
              readASCII(data, at: 8, length: 4) == "WAVE" else { return nil }

        var fmt: Data?
        var pcm: Data?
        var offset = 12

        while offset + 8 <= data.count {
            let id = readASCII(data, at: offset, length: 4)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            guard payloadStart + size <= data.count else { break }

            let payload = data.subdata(in: payloadStart ..< (payloadStart + size))
            if id == "fmt " { fmt = payload }
            else if id == "data" { pcm = payload }

            // Chunks are word-aligned: an odd-sized payload is followed by a pad byte.
            offset = payloadStart + size + (size % 2)
        }

        guard let fmt, let pcm else { return nil }
        return (fmt, pcm)
    }

    // MARK: - Byte helpers

    private static func ascii(_ s: String) -> Data { s.data(using: .ascii)! }

    private static func uint32LE(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    private static func readASCII(_ data: Data, at offset: Int, length: Int) -> String {
        let start = data.startIndex + offset
        return String(data: data.subdata(in: start ..< (start + length)), encoding: .ascii) ?? ""
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value |= UInt32(data[start + i]) << (8 * i)
        }
        return value
    }
}
