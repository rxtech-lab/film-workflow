import AVFoundation
import Foundation

nonisolated enum AudioProbeError: LocalizedError {
    case unreadable(URL)
    case unknownDuration(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read audio from \(url.lastPathComponent)."
        case .unknownDuration(let url):
            return "Could not determine the duration of \(url.lastPathComponent)."
        }
    }
}

/// Reads facts about an audio file without decoding it.
///
/// Duration matters more than it looks: providers that report their own
/// duration sometimes disagree with the file, and the aligner needs a hard
/// upper bound so the last cue can be pinned to the real end of the audio.
nonisolated struct AudioProbe {

    /// Duration in milliseconds, via `AVURLAsset`.
    @concurrent
    static func durationMs(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                return Int((seconds * 1000).rounded())
            }
        } catch {
            // Fall through to the WAV header path below.
        }

        // Gemini TTS output carries a hand-written RIFF header
        // (`GeminiTTSClient.wrapPCMAsWAV`). AVFoundation reads it fine, but the
        // header is cheap to parse and costs nothing as a fallback.
        if url.pathExtension.lowercased() == "wav",
           let ms = wavDurationMs(of: url) {
            return ms
        }

        throw AudioProbeError.unknownDuration(url)
    }

    /// Duration from a RIFF/WAVE header, reading only the first few KB.
    private static func wavDurationMs(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count > 44 else { return nil }

        let bytes = [UInt8](header)
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        guard bytes.count > 12,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, // "RIFF"
              bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 // "WAVE"
        else { return nil }

        // Walk chunks looking for "fmt " (byte rate) and "data" (size).
        var cursor = 12
        var byteRate: UInt32?
        var dataSize: UInt32?

        while cursor + 8 <= bytes.count {
            let id = String(bytes: bytes[cursor..<min(cursor + 4, bytes.count)], encoding: .ascii) ?? ""
            guard let chunkSize = u32(cursor + 4) else { break }

            if id == "fmt " {
                byteRate = u32(cursor + 16)
            } else if id == "data" {
                dataSize = chunkSize
                break
            }
            cursor += 8 + Int(chunkSize)
            if chunkSize % 2 == 1 { cursor += 1 } // chunks are word-aligned
        }

        guard let byteRate, byteRate > 0, let dataSize, dataSize > 0 else { return nil }
        return Int((Double(dataSize) / Double(byteRate)) * 1000)
    }

    /// MIME type for a file extension.
    ///
    /// iOS records `.m4a` (AAC in an MP4 container) and Gemini wants
    /// `audio/mp4` for those — the mapping matters, not just the prefix.
    /// Port of `debate-bot/internal/server/transcribe_http.go geminiAudioMIME`.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "wav", "wave": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "aiff", "aif": return "audio/aiff"
        case "webm": return "audio/webm"
        case "caf": return "audio/x-caf"
        default: return "audio/mp4"
        }
    }

    static func mimeType(for url: URL) -> String {
        mimeType(forExtension: url.pathExtension)
    }

    /// Whether `AVAudioFile` can open this file directly.
    ///
    /// WhisperKit's own loader uses `AVAudioFile`, so a false here means the
    /// audio must be transcoded before local transcription (Opus-in-Ogg and
    /// some WebM are the realistic cases).
    @concurrent
    static func isReadableByAVAudioFile(_ url: URL) async -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }

    static func fileSizeBytes(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
