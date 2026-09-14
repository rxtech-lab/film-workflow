import Foundation

/// Shrinks audio before it is uploaded to a hosted transcription provider.
///
/// A film's own audio is usually uncompressed — an hour of 48 kHz stereo WAV is
/// over 600 MB — while hosted providers cap what one request may carry: Azure
/// fast transcription at 300 MB, OpenAI at 25 MB. Re-encoding to 16 kHz mono
/// AAC costs one local pass and turns that hour into roughly 15 MB, so the
/// upload fits, chunked providers need a fraction of the requests, and the
/// transcript is unaffected: every speech model resamples to 16 kHz mono before
/// it listens.
///
/// Local Whisper never comes through here. It reads the file off disk, so
/// re-encoding would spend time and detail for nothing.
nonisolated enum CaptionAudioCompressor {

    /// What Whisper, Azure and Gemini all resample to internally. 32 kbps is
    /// the most Apple's AAC encoder accepts at this rate — see
    /// `AudioConversion.compressForSpeech`.
    static let sampleRate = 16_000.0
    static let bitRate = 32_000

    /// Bytes one millisecond of the encoded file costs. The tenth on top is the
    /// MP4 container's share, measured rather than derived: a 32 kbps stream
    /// lands at about 4.25 B/ms on disk against the 4.0 the bitrate implies.
    static let bytesPerMs = Double(bitRate) / 8_000 * 1.1

    /// Re-encoding has to save at least this much to be worth a full pass over
    /// the file; audio that is already speech-sized is left alone.
    static let worthwhileRatio = 0.9

    /// Below this the audio goes up as one quick request whatever its bitrate,
    /// so a re-encode would trade fidelity for an upload nobody waits on. A
    /// short narration WAV is the case this protects.
    static let minimumSizeBytes = 4 * 1024 * 1024

    /// Falls back to plain size when the duration is unknown and the estimate
    /// below can't be made.
    static let unknownDurationThreshold = 24 * 1024 * 1024

    struct Result: Sendable {
        let request: CaptionTranscribeRequest
        /// The temp file this created, for the caller to delete once the upload
        /// is done. Nil when the original audio is being used as it is.
        let temporaryURL: URL?
    }

    /// Whether this request's audio would be re-encoded, so callers can say so
    /// in their progress before the pass starts.
    ///
    /// `requiredBytes` is the provider's hard per-request cap, where it has one.
    static func willCompress(_ request: CaptionTranscribeRequest, requiredBytes: Int? = nil) -> Bool {
        if let requiredBytes, request.sizeBytes > requiredBytes { return true }
        return isWorthCompressing(sizeBytes: request.sizeBytes, durationMs: request.durationMs)
    }

    /// Whether re-encoding this much audio would pay for itself.
    static func isWorthCompressing(sizeBytes: Int, durationMs: Int) -> Bool {
        guard sizeBytes > minimumSizeBytes else { return false }
        guard durationMs > 0 else { return sizeBytes > unknownDurationThreshold }
        return Double(durationMs) * bytesPerMs < Double(sizeBytes) * worthwhileRatio
    }

    /// Returns the request to upload, re-encoded when that helps.
    ///
    /// Below `requiredBytes` a failed re-encode is only a missed optimization,
    /// so the original is uploaded and the provider still gets its chance. At or
    /// above it the re-encode was the one way the upload could have succeeded,
    /// so the failure is reported rather than hidden behind a "too large" that
    /// wouldn't tell the user what actually went wrong.
    static func compressForUpload(
        _ request: CaptionTranscribeRequest,
        requiredBytes: Int? = nil
    ) async throws -> Result {
        let unchanged = Result(request: request, temporaryURL: nil)
        guard willCompress(request, requiredBytes: requiredBytes) else { return unchanged }
        let required = requiredBytes.map { request.sizeBytes > $0 } ?? false

        let compressed: URL
        do {
            compressed = try await AudioConversion.compressForSpeech(
                request.audioURL,
                sampleRate: sampleRate,
                bitRate: bitRate
            )
        } catch {
            if required || error is CancellationError { throw error }
            print("[captions] Could not compress \(request.audioURL.lastPathComponent), "
                  + "uploading it as it is: \(error.localizedDescription)")
            return unchanged
        }

        // A re-encode that didn't actually shrink anything is strictly worse
        // than the original: it only removed detail.
        let size = AudioProbe.fileSizeBytes(of: compressed)
        guard size > 0, size < request.sizeBytes else {
            try? FileManager.default.removeItem(at: compressed)
            return unchanged
        }

        var updated = request
        updated.audioURL = compressed
        updated.mimeType = AudioProbe.mimeType(for: compressed)
        updated.sizeBytes = size
        return Result(request: updated, temporaryURL: compressed)
    }
}
