import Foundation

/// Splits oversized audio into provider-sized pieces and stitches the resulting
/// transcripts back onto one timeline.
///
/// Necessary because `api.openai.com/v1/audio/transcriptions` rejects requests
/// over 25 MB. Chunk seams can cut mid-utterance; `mergeSentenceContinuations`
/// in `CaptionCueBuilder` heals most of that afterwards, which is why chunks are
/// kept long (10 minutes) rather than small.
nonisolated struct CaptionAudioChunker {

    struct Chunk: Sendable {
        let url: URL
        let startMs: Int
        let durationMs: Int
        /// True when this is the original file rather than an exported piece,
        /// so callers know not to delete it.
        let isOriginal: Bool
    }

    static let defaultMaxDurationMs = 10 * 60 * 1000
    /// A little under OpenAI's 25 MB cap, leaving room for the multipart framing.
    static let defaultMaxBytes = 24 * 1024 * 1024

    /// Returns the original file untouched when it already fits, otherwise
    /// exported `.m4a` pieces.
    @concurrent
    static func chunk(
        _ url: URL,
        durationMs: Int,
        sizeBytes: Int,
        maxDurationMs: Int = defaultMaxDurationMs,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> [Chunk] {
        if sizeBytes <= maxBytes, durationMs <= maxDurationMs || durationMs <= 0 {
            return [Chunk(url: url, startMs: 0, durationMs: durationMs, isOriginal: true)]
        }
        guard durationMs > 0 else {
            // Can't split what we can't measure; let the provider reject it and
            // report its own error rather than guessing.
            return [Chunk(url: url, startMs: 0, durationMs: durationMs, isOriginal: true)]
        }

        // Shrink the window if bytes rather than duration are the binding
        // constraint, so a high-bitrate file still lands under the cap.
        var windowMs = maxDurationMs
        if sizeBytes > 0 {
            let bytesPerMs = Double(sizeBytes) / Double(durationMs)
            if bytesPerMs > 0 {
                let byteLimitedMs = Int(Double(maxBytes) / bytesPerMs)
                windowMs = min(windowMs, max(byteLimitedMs, 30_000))
            }
        }

        var chunks: [Chunk] = []
        var start = 0
        while start < durationMs {
            try Task.checkCancellation()
            let length = min(windowMs, durationMs - start)
            let exported = try await AudioConversion.exportChunk(
                url, startMs: start, durationMs: length
            )
            chunks.append(
                Chunk(url: exported, startMs: start, durationMs: length, isOriginal: false)
            )
            start += length
        }
        return chunks
    }

    static func cleanUp(_ chunks: [Chunk]) {
        for chunk in chunks where !chunk.isOriginal {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }

    /// Shifts each chunk's phrases by its start offset and concatenates them.
    static func merge(
        _ parts: [(transcript: CaptionTranscript, startMs: Int)],
        totalDurationMs: Int,
        providerName: String
    ) -> CaptionTranscript {
        var phrases: [CaptionPhrase] = []

        for part in parts {
            for phrase in part.transcript.phrases {
                var shifted = phrase
                shifted.offsetMs += part.startMs
                shifted.words = phrase.words.map { word in
                    var copy = word
                    copy.offsetMs += part.startMs
                    return copy
                }
                phrases.append(shifted)
            }
        }

        phrases.sort { $0.offsetMs < $1.offsetMs }

        let derivedDuration = max(totalDurationMs, phrases.map(\.endMs).max() ?? 0)
        return CaptionTranscript(
            durationMs: derivedDuration,
            phrases: phrases,
            providerName: providerName,
            detectedLanguage: parts.compactMap {
                $0.transcript.detectedLanguage.isEmpty ? nil : $0.transcript.detectedLanguage
            }.first ?? ""
        )
    }
}
