import AVFoundation
import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Export options")
struct ExportOptionsTests {
    @Test("Resolution presets scale the longest edge and keep the aspect ratio")
    func resolutionSizes() {
        let landscape = CGSize(width: 1920, height: 1080)
        #expect(TimelineExporter.Resolution.source.size(for: landscape) == landscape)
        #expect(TimelineExporter.Resolution.p720.size(for: landscape) == CGSize(width: 1280, height: 720))
        #expect(TimelineExporter.Resolution.p2160.size(for: landscape) == CGSize(width: 3840, height: 2160))
        // Portrait: the preset names the long edge, so 1080p is 1080 × 1920.
        #expect(TimelineExporter.Resolution.p1080.size(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 1080, height: 1920))
        #expect(TimelineExporter.Resolution.p480.size(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 480, height: 854))
        // Square and odd sizes come out even for the encoder.
        #expect(TimelineExporter.Resolution.p720.size(for: CGSize(width: 1000, height: 1000)) == CGSize(width: 1280, height: 1280))
        #expect(TimelineExporter.Resolution.p480.size(for: CGSize(width: 333, height: 100)) == CGSize(width: 854, height: 256))
        #expect(TimelineExporter.Resolution.p720.size(for: .zero) == .zero)
    }

    @Test("Normalizing fixes the container to the kind of export")
    func normalized() {
        var options = TimelineExporter.Options(video: nil, audio: .aac, resolution: .p720, container: .mp4)
        #expect(options.normalized.container == .m4a)
        #expect(options.fileExtension == "m4a")
        #expect(options.outputSize(for: CGSize(width: 1920, height: 1080)) == nil)
        #expect(options.summary == "AAC · M4A Audio")

        options.video = .hevc
        options.container = .m4a
        #expect(options.normalized.container == .mp4)
        #expect(options.outputSize(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 1280, height: 720))
        options.container = .mov
        #expect(options.normalized.container == .mov)
        #expect(options.summary == "HEVC + AAC · QuickTime Movie")
        #expect(TimelineExporter.Options().summary == "H.264 + AAC · MP4")
    }

    @Test("Options survive a round trip through JSON")
    func codable() throws {
        let options = TimelineExporter.Options(video: .hevc, audio: nil, resolution: .p1440, container: .mov, captions: .sidecar)
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(TimelineExporter.Options.self, from: data) == options)
    }

    @Test("Options saved before caption delivery existed burn captions in, and audio files carry none")
    func captionDelivery() throws {
        let legacy = Data(#"{"video":"h264","audio":"aac","resolution":"p720","container":"mp4"}"#.utf8)
        let decoded = try JSONDecoder().decode(TimelineExporter.Options.self, from: legacy)
        #expect(decoded.captions == .burnIn)
        #expect(decoded.burnsInCaptions)
        #expect(decoded.video == .h264 && decoded.resolution == .p720)
        let silentLegacy = Data(#"{"audio":"aac","resolution":"source","container":"m4a"}"#.utf8)
        #expect(try JSONDecoder().decode(TimelineExporter.Options.self, from: silentLegacy).video == nil)

        let audioOnly = TimelineExporter.Options(video: nil, captions: .embedded)
        #expect(audioOnly.normalized.captions == .none)
        #expect(!audioOnly.burnsInCaptions)
        #expect(!TimelineExporter.Options(captions: .embedded).burnsInCaptions)
    }
}

@Suite("Export with options")
struct ExportWithOptionsTests {
    private func tone(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try #require(buffer.floatChannelData)
        for i in 0..<96_000 {
            let value = Float(sin(2 * .pi * 440 * Double(i) / 48_000)) * 0.5
            samples[0][i] = value
            samples[1][i] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// A 2 s timeline: a blue video on V1 and a tone on A1.
    private func fixture(in dir: URL) throws -> (Timeline, FixtureResolver) {
        let movie = dir.appendingPathComponent("blue.mp4")
        try Fixtures.video(color: .blue, seconds: 2, at: movie)
        let audio = dir.appendingPathComponent("tone.caf")
        try tone(at: audio)
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = t.tracks.first { $0.kind == .video }!.id
        let a = t.tracks.first { $0.kind == .audio }!.id
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "video:b", kind: .video, displayName: "B"), start: 0, duration: 2), on: v)
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "audio:t", kind: .audio, displayName: "T"), start: 0, duration: 2), on: a)
        let resolver = FixtureResolver(files: [
            "video:b": .file(movie, naturalDuration: 2, naturalSize: CGSize(width: 320, height: 180)),
            "audio:t": .file(audio, naturalDuration: 2, naturalSize: nil),
        ])
        return (t, resolver)
    }

    @Test("Scales the picture, drops audio and writes a QuickTime movie")
    @MainActor func scaledSilentMov() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (t, resolver) = try fixture(in: dir)
        let output = dir.appendingPathComponent("out.mov")
        let options = TimelineExporter.Options(video: .h264, audio: nil, resolution: .p480, container: .mov)
        try await TimelineExporter.export(t, resolver: resolver, to: output, options: options) { _ in }

        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 854, height: 480))
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 2) < 0.1)
        let blue = try await Fixtures.averageColor(of: output, at: 1)
        #expect(blue.b > 0.6 && blue.r < 0.3 && blue.g < 0.3)
    }

    @Test("Audio only writes an m4a with no picture, whatever container was asked for")
    @MainActor func audioOnly() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (t, resolver) = try fixture(in: dir)
        let output = dir.appendingPathComponent("out.m4a")
        let options = TimelineExporter.Options(video: nil, audio: .aac, resolution: .p1080, container: .mp4)
        try await TimelineExporter.export(t, resolver: resolver, to: output, options: options) { _ in }

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 2) < 0.1)
    }

    @Test("Nothing to write is an error, not an empty file")
    @MainActor func nothingToExport() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (t, resolver) = try fixture(in: dir)
        let output = dir.appendingPathComponent("none.mp4")
        await #expect(throws: TimelineExportError.self) {
            try await TimelineExporter.export(t, resolver: resolver, to: output, options: TimelineExporter.Options(video: nil, audio: nil)) { _ in }
        }
        // Audio-only on a timeline without audio.
        var silent = Timeline(width: 320, height: 180, fps: 30)
        let v = silent.tracks.first { $0.kind == .video }!.id
        try TimelineEditor.insert(&silent, clip: Clip(source: ClipSource(id: "video:b", kind: .video, displayName: "B"), start: 0, duration: 1), on: v)
        await #expect(throws: TimelineExportError.self) {
            try await TimelineExporter.export(silent, resolver: resolver, to: output, options: TimelineExporter.Options(video: nil)) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
