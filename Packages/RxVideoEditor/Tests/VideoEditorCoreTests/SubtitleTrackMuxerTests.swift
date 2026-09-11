import AVFoundation
import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Subtitle track muxer")
struct SubtitleTrackMuxerTests {
    private func tracks() -> [CaptionTrack] {
        [
            CaptionTrack(languageCode: "en", cues: [TextCue(start: 0.5, end: 1.5, text: "Hello")]),
            CaptionTrack(languageCode: "zh-Hans", cues: [TextCue(start: 0.5, end: 1.5, text: "你好"), TextCue(start: 1.6, end: 2, text: "再见")]),
        ]
    }

    @Test("Adds one tx3g track per language to MP4 and QuickTime movies", arguments: [AVFileType.mp4, .mov])
    func muxes(fileType: AVFileType) async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("blue.mp4")
        try Fixtures.video(color: .blue, seconds: 2, at: movie)
        let output = dir.appendingPathComponent("out.\(fileType == .mov ? "mov" : "mp4")")

        try await SubtitleTrackMuxer.mux(
            movie: movie, tracks: tracks(), style: .caption, frameSize: CGSize(width: 320, height: 180),
            duration: CMTime(seconds: 2, preferredTimescale: 600), fileType: fileType, to: output
        )

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
        #expect(subtitles.count == 2)
        let languages = try await subtitles.asyncMap { try await $0.load(.languageCode) }
        #expect(languages == ["eng", "zho"])
        let tags = try await subtitles.asyncMap { try await $0.load(.extendedLanguageTag) }
        #expect(tags == ["en", "zh-Hans"])
        for track in subtitles {
            let range = try await track.load(.timeRange)
            #expect(abs(CMTimeGetSeconds(range.duration) - 2) < 0.05)
            #expect(try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMSubtitleFormatType_3GText)
        }
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 2) < 0.1)

        // English: a gap, "Hello" from 0.5 s for 1 s, then a gap to the end.
        // The reader may hand back a dataless sample first; only samples with
        // a payload are the track's own.
        let reader = try AVAssetReader(asset: asset)
        let subtitleOutput = AVAssetReaderTrackOutput(track: subtitles[0], outputSettings: nil)
        reader.add(subtitleOutput)
        #expect(reader.startReading())
        var samples: [(bytes: [UInt8], start: Double, duration: Double)] = []
        while let sample = subtitleOutput.copyNextSampleBuffer() {
            let payload = bytes(of: sample)
            guard !payload.isEmpty else { continue }
            samples.append((payload, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), CMTimeGetSeconds(CMSampleBufferGetDuration(sample))))
        }
        reader.cancelReading()
        #expect(samples.map(\.bytes) == [[0, 0], [0, 5] + Array("Hello".utf8), [0, 0]])
        #expect(samples.map { ($0.start * 1000).rounded() } == [0, 500, 1500])
        #expect(samples.map { ($0.duration * 1000).rounded() } == [500, 1000, 500])
    }

    @Test("A movie without a picture is refused")
    func refusesAudioOnly() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.mp4")
        await #expect(throws: (any Error).self) {
            try await SubtitleTrackMuxer.mux(
                movie: dir.appendingPathComponent("missing.mp4"), tracks: tracks(), style: .caption, frameSize: CGSize(width: 320, height: 180),
                duration: CMTime(seconds: 2, preferredTimescale: 600), fileType: .mp4, to: output
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func bytes(of sample: CMSampleBuffer) -> [UInt8] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var out = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &out)
        return out
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
