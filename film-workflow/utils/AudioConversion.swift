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

    /// Re-encodes the whole file as mono AAC at a speech bitrate.
    ///
    /// `exportChunk`'s `AVAssetExportPresetAppleM4A` can't be given a bitrate —
    /// it always writes stereo at roughly 128 kbps — so a reader/writer pair is
    /// what gets a long uncompressed recording under a provider's request cap.
    /// 16 kHz mono is what every speech model resamples to before it listens,
    /// so the transcript is unaffected by the loss.
    ///
    /// The bitrate is not free to choose: Apple's AAC encoder caps it against
    /// the sample rate and reports the mismatch only when the first buffer is
    /// appended, as `-11861 Cannot Encode Media`. 32 kbps is the most 16 kHz
    /// mono accepts; raising one means raising the other.
    @concurrent
    static func compressForSpeech(
        _ source: URL,
        sampleRate: Double = 16_000,
        bitRate: Int = 32_000
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConversionError.noAudioTrack(source)
        }

        // Decode to PCM at the target rate first; the reader resamples, so the
        // encoder is handed exactly what it is configured to write.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw AudioConversionError.exportFailed("this audio can't be decoded for re-encoding")
        }
        reader.add(output)

        let destination = FileStorage.temporaryFileURL(extension: "m4a")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        var mono = AudioChannelLayout()
        mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw AudioConversionError.exportFailed("AAC at \(Int(sampleRate)) Hz mono is unavailable")
        }
        writer.add(input)

        guard reader.startReading() else {
            throw AudioConversionError.exportFailed(
                reader.error?.localizedDescription ?? "reader would not start"
            )
        }
        guard writer.startWriting() else {
            throw AudioConversionError.exportFailed(
                writer.error?.localizedDescription ?? "writer would not start"
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            // A pull loop rather than `requestMediaDataWhenReady`: cancellation
            // and the failure paths stay in one place, and yielding while the
            // encoder catches up costs nothing on a background pass.
            while true {
                try Task.checkCancellation()
                guard input.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(5))
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard input.append(sample) else {
                    throw AudioConversionError.exportFailed(
                        writer.error?.localizedDescription ?? "the encoder rejected a sample"
                    )
                }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw AudioConversionError.exportFailed(
                reader.error?.localizedDescription ?? "unknown reader failure"
            )
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw AudioConversionError.exportFailed(
                writer.error?.localizedDescription ?? "unknown writer failure"
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
