import AVFoundation
import Foundation

nonisolated enum AudioConversionError: LocalizedError {
    case cannotRead(URL)
    case converterUnavailable
    case exportFailed(String)
    case noAudioTrack(URL)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let url):
            return "Could not read \(url.lastPathComponent)."
        case .converterUnavailable:
            return "Could not create an audio converter for this format."
        case .exportFailed(let detail):
            return "Audio export failed: \(detail)"
        case .noAudioTrack(let url):
            return "\(url.lastPathComponent) contains no audio track."
        }
    }
}

/// Format conversion and time-range extraction.
///
/// Both operations write into `FileStorage.tempDir`, which is cleared at launch,
/// so a crash mid-transcription can't leak hundreds of megabytes permanently.
nonisolated struct AudioConversion {

    /// Transcodes to 16 kHz mono Float32 WAV — what Whisper actually consumes.
    ///
    /// Normally unnecessary: WhisperKit's `AudioProcessor` performs this same
    /// conversion internally when handed a file path. This exists for the cases
    /// its `AVAudioFile`-based loader can't open at all (Opus-in-Ogg, some
    /// WebM), which is why callers gate on
    /// `AudioProbe.isReadableByAVAudioFile`.
    @concurrent
    static func toWhisperWAV(_ source: URL) async throws -> URL {
        // Route through AVAssetReader rather than AVAudioFile: the whole point
        // of this path is inputs AVAudioFile rejects.
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConversionError.noAudioTrack(source)
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        let destination = FileStorage.temporaryFileURL(extension: "wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw AudioConversionError.converterUnavailable
        }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)

        guard reader.startReading() else {
            throw AudioConversionError.exportFailed(
                reader.error?.localizedDescription ?? "reader would not start"
            )
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let frameCount = byteCount / 4 // Float32 mono
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
                  ),
                  let channel = buffer.floatChannelData?[0]
            else { continue }

            var status = noErr
            status = CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: byteCount, destination: channel
            )
            guard status == kCMBlockBufferNoErr else { continue }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            try file.write(from: buffer)
        }

        if reader.status == .failed {
            throw AudioConversionError.exportFailed(
                reader.error?.localizedDescription ?? "unknown reader failure"
            )
        }
        return destination
    }

    /// Exports `[startMs, startMs + durationMs)` as an `.m4a`.
    ///
    /// Used to split oversized audio for providers with request caps. AAC keeps
    /// the chunks small enough to stay under those caps without a second pass.
    @concurrent
    static func exportChunk(_ source: URL, startMs: Int, durationMs: Int) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw AudioConversionError.noAudioTrack(source)
        }
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioConversionError.exportFailed("could not create an export session")
        }

        let destination = FileStorage.temporaryFileURL(extension: "m4a")
        // Millisecond timescale so chunk boundaries line up exactly with the
        // offsets used to shift the resulting transcripts.
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
            duration: CMTime(value: CMTimeValue(durationMs), timescale: 1000)
        )

        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw AudioConversionError.exportFailed(error.localizedDescription)
        }
        return destination
    }
}
