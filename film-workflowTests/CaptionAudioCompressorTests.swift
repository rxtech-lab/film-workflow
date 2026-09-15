import Foundation
import Testing

@testable import film_workflow

/// The decision to re-encode before uploading, which is pure arithmetic over a
/// file's size and duration. The encode itself is AVFoundation's and isn't
/// exercised here.
@Suite("Caption audio compression")
struct CaptionAudioCompressorTests {

    private let hourMs = 60 * 60 * 1000

    private func request(sizeBytes: Int, durationMs: Int) -> CaptionTranscribeRequest {
        CaptionTranscribeRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            mimeType: "audio/wav",
            sizeBytes: sizeBytes,
            durationMs: durationMs
        )
    }

    @Test("An uncompressed WAV is worth re-encoding")
    func compressesUncompressedAudio() {
        // One hour of 48 kHz 16-bit stereo.
        let wav = 48_000 * 2 * 2 * 3600
        #expect(CaptionAudioCompressor.isWorthCompressing(sizeBytes: wav, durationMs: hourMs))
    }

    @Test("Audio already at speech bitrate is left alone")
    func skipsSpeechSizedAudio() {
        let alreadySmall = Int(Double(hourMs) * CaptionAudioCompressor.bytesPerMs)
        #expect(!CaptionAudioCompressor.isWorthCompressing(sizeBytes: alreadySmall, durationMs: hourMs))
    }

    @Test("A 128 kbps music file still halves")
    func compressesMusicBitrate() {
        let mp3 = 128_000 / 8 * 3600
        #expect(CaptionAudioCompressor.isWorthCompressing(sizeBytes: mp3, durationMs: hourMs))
    }

    @Test("Without a duration, only large files are re-encoded")
    func fallsBackToSizeAlone() {
        let threshold = CaptionAudioCompressor.unknownDurationThreshold
        #expect(CaptionAudioCompressor.isWorthCompressing(sizeBytes: threshold + 1, durationMs: 0))
        #expect(!CaptionAudioCompressor.isWorthCompressing(sizeBytes: threshold, durationMs: 0))
        #expect(!CaptionAudioCompressor.isWorthCompressing(sizeBytes: 0, durationMs: 0))
    }

    @Test("A short narration is uploaded as it is")
    func skipsSmallAudio() {
        // A minute of 24 kHz mono 16-bit WAV — uncompressed, but it uploads in
        // one request either way.
        let narration = 24_000 * 2 * 60
        #expect(narration < CaptionAudioCompressor.minimumSizeBytes)
        #expect(!CaptionAudioCompressor.isWorthCompressing(sizeBytes: narration, durationMs: 60_000))
    }

    @Test("Audio over a provider's cap is re-encoded even when the saving is small")
    func compressesWhateverExceedsTheCap() {
        // Already at speech bitrate, but longer than Azure's 300 MB request cap
        // allows — re-encoding is the only way the upload can succeed.
        let overCap = AzureFastTranscriptionClient.maxBytes + 1
        let durationMs = Int(Double(overCap) / CaptionAudioCompressor.bytesPerMs)
        let oversized = request(sizeBytes: overCap, durationMs: durationMs)

        #expect(!CaptionAudioCompressor.isWorthCompressing(sizeBytes: overCap, durationMs: durationMs))
        #expect(!CaptionAudioCompressor.willCompress(oversized, requiredBytes: nil))
        #expect(CaptionAudioCompressor.willCompress(
            oversized,
            requiredBytes: AzureFastTranscriptionClient.maxBytes
        ))
    }

    @Test("An hour of speech lands well inside Azure's request cap")
    func compressedHourFitsAzure() {
        let compressed = Int(Double(hourMs) * CaptionAudioCompressor.bytesPerMs)
        #expect(compressed < AzureFastTranscriptionClient.maxBytes)
        // And inside OpenAI's per-chunk budget once the chunker's 10-minute
        // window is applied.
        let tenMinutes = Int(Double(10 * 60 * 1000) * CaptionAudioCompressor.bytesPerMs)
        #expect(tenMinutes < CaptionAudioChunker.defaultMaxBytes)
    }
}
