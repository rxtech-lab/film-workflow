import AVFoundation
import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Clip editing capabilities and retiming")
struct RetimeTests {
    private func fixture(reversed: Bool = false) -> (Timeline, Clip) {
        let clip = Clip(source: ClipSource(id: "audio", kind: .audio, displayName: "Audio"),
                        start: 2, duration: 6, inPoint: 2, playbackRate: 2,
                        isReversed: reversed, sourceDuration: 20)
        return (Timeline(tracks: [Track(kind: .audio, name: "A1", clips: [clip])]), clip)
    }

    @Test("Percentage and duration keep the complete source range; overlap is atomic")
    func speed() throws {
        var (timeline, clip) = fixture()
        try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 1.2)
        let changed = try #require(timeline.clip(id: clip.id))
        #expect(changed.duration == 10 && changed.inPoint == 2 && changed.sourceRangeDuration == 12)
        try TimelineEditor.retime(&timeline, clipID: clip.id, duration: 3)
        #expect(timeline.clip(id: clip.id)?.playbackRate == 4)
        let next = Clip(source: clip.source, start: 6, duration: 2)
        try TimelineEditor.insert(&timeline, clip: next, on: timeline.tracks[0].id)
        let before = timeline
        #expect(throws: TimelineEditError.overlap) { try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 1) }
        #expect(timeline == before)
        for invalid in [0, -1, Double.nan, .infinity] {
            #expect(throws: TimelineEditError.invalidSpeed) { try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: invalid) }
        }
        #expect(timeline == before)
    }

    @Test("Splits and trims follow the source clock in either direction", arguments: [false, true])
    func sourceMapping(reversed: Bool) throws {
        var (timeline, clip) = fixture(reversed: reversed)
        let rightID = try #require(try TimelineEditor.split(&timeline, clipID: clip.id, at: 4))
        let left = try #require(timeline.clip(id: clip.id))
        let right = try #require(timeline.clip(id: rightID))
        #expect(left.duration == 2 && right.duration == 4)
        #expect(left.isReversed == reversed && right.playbackRate == 2)
        for time in [2.5, 3.5, 4.5, 7.5] {
            let part = time < 4 ? left : right
            #expect(abs(part.sourceTime(at: time) - clip.sourceTime(at: time)) < 0.000001)
        }
        #expect(left.inPoint == (reversed ? 10 : 2))
        #expect(right.inPoint == (reversed ? 2 : 6))

        (timeline, _) = fixture(reversed: reversed)
        let id = timeline.allClips[0].id
        try TimelineEditor.trimLeading(&timeline, clipID: id, by: 1)
        var trimmed = try #require(timeline.clip(id: id))
        #expect(trimmed.end == 8 && trimmed.duration == 5)
        #expect(trimmed.inPoint == (reversed ? 2 : 4))
        try TimelineEditor.trimTrailing(&timeline, clipID: id, by: -1)
        trimmed = try #require(timeline.clip(id: id))
        #expect(trimmed.start == 3 && trimmed.end == 7)
        #expect(trimmed.inPoint == 4)
        try TimelineEditor.trimTrailing(&timeline, clipID: id, by: 100)
        trimmed = try #require(timeline.clip(id: id))
        #expect(trimmed.sourceEnd <= 20)
        #expect(trimmed.inPoint >= 0)
    }

    @Test("Dragging either speed edge preserves the source and the opposite timeline edge", arguments: [false, true])
    func retimeEdges(reversed: Bool) throws {
        var (timeline, original) = fixture(reversed: reversed)
        try TimelineEditor.retime(&timeline, clipID: original.id, duration: 4, anchor: .end)
        var clip = try #require(timeline.clip(id: original.id))
        #expect(clip.start == 4 && clip.end == original.end)
        #expect(clip.playbackRate == 3 && clip.sourceRangeDuration == original.sourceRangeDuration)
        #expect(clip.inPoint == original.inPoint && clip.isReversed == reversed)
        try TimelineEditor.retime(&timeline, clipID: clip.id, duration: 3, anchor: .start)
        clip = try #require(timeline.clip(id: clip.id))
        #expect(clip.start == 4 && clip.end == 7 && clip.playbackRate == 4)
        #expect(clip.inPoint == original.inPoint && clip.sourceEnd == original.sourceEnd)
        let before = timeline
        #expect(throws: TimelineEditError.invalidDuration) {
            try TimelineEditor.retime(&timeline, clipID: clip.id, duration: 8, anchor: .end)
        }
        #expect(timeline == before)
        try TimelineEditor.insert(&timeline, clip: Clip(source: clip.source, start: 0, duration: 2), on: timeline.tracks[0].id)
        let withNeighbour = timeline
        #expect(throws: TimelineEditError.overlap) {
            try TimelineEditor.retime(&timeline, clipID: clip.id, duration: 6, anchor: .end)
        }
        #expect(timeline == withNeighbour)
    }

    @Test("Reverse retains the range and duration, and can be toggled back")
    func reverse() throws {
        var (timeline, clip) = fixture()
        let before = timeline
        try TimelineEditor.reverse(&timeline, clipID: clip.id)
        let reversed = try #require(timeline.clip(id: clip.id))
        #expect(reversed.sourceTime(at: 2) == 14)
        #expect(reversed.sourceTime(at: 8) == 2)
        try TimelineEditor.reverse(&timeline, clipID: clip.id)
        #expect(timeline == before)
    }

    @Test("Capabilities survive save/reopen and reject unavailable edits")
    func capabilities() throws {
        var (timeline, clip) = fixture(reversed: true)
        #expect(try TimelineCodec.decode(TimelineCodec.encode(timeline)) == timeline)
        clip.source.capabilities = []
        timeline.tracks[0].clips = [clip]
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 2) }
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.reverse(&timeline, clipID: clip.id) }
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.split(&timeline, clipID: clip.id, at: 3) }
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.trimTrailing(&timeline, clipID: clip.id, by: -1) }
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.move(&timeline, clipID: clip.id, to: 10) }
        #expect(timeline.allClips == [clip])
        #expect(try TimelineCodec.decode(TimelineCodec.encode(timeline)).allClips[0].source.capabilities.isEmpty)
        let old = Data("{\"id\":\"old\",\"kind\":\"audio\",\"displayName\":\"Audio\"}".utf8)
        #expect(try JSONDecoder().decode(ClipSource.self, from: old).capabilities == [.duration, .cut, .reverse, .speed, .drag])
    }

    @Test("Stills extend at either end without inventing a source offset")
    func stills() throws {
        let clip = Clip(source: ClipSource(id: "image", kind: .image, displayName: "Still"), start: 2, duration: 4)
        var timeline = Timeline(tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        try TimelineEditor.trimLeading(&timeline, clipID: clip.id, by: -1)
        try TimelineEditor.trimTrailing(&timeline, clipID: clip.id, by: 1)
        #expect(timeline.allClips[0].start == 1 && timeline.allClips[0].end == 7)
        #expect(timeline.allClips[0].inPoint == 0)
    }
}

@Suite("Retimed and reversed media")
struct RetimedMediaTests {
    private func writeAudio(_ url: URL, ramp: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try #require(buffer.floatChannelData)
        for i in 0..<96_000 {
            let value = ramp ? Float(i) / 96_000 : Float(sin(2 * .pi * 440 * Double(i) / 48_000)) * (i < 48_000 ? 0.7 : 0.1)
            samples[0][i] = value
            samples[1][i] = -value / 2
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test("Reverse crosses chunk boundaries without swapping stereo channels")
    func reverseSamples() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ramp.caf")
        try writeAudio(url, ramp: true)
        let cache = ReversedAudioCache()
        let reversed = try await cache.file(for: url)
        #expect(try await cache.file(for: url) == reversed)
        let file = try AVAudioFile(forReading: reversed)
        #expect(file.length == 96_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)
        for i in [0, 1, 30_463, 30_464, 65_535, 65_536, 95_999] {
            let expected = Float(95_999 - i) / 96_000
            #expect(abs(samples[0][i] - expected) < 0.000001)
            #expect(abs(samples[1][i] + expected / 2) < 0.000001)
        }
    }

    @Test("Audio speed and reverse reach preview, meters and exported samples")
    @MainActor func audioExport() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.caf")
        try writeAudio(url)
        let source = ClipSource(id: "audio", kind: .audio, displayName: "Tone")
        let clip = Clip(source: source, start: 0, duration: 2, sourceDuration: 2)
        var timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .audio, name: "A1", clips: [clip])])
        try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 2)
        try TimelineEditor.reverse(&timeline, clipID: clip.id)
        _ = try TimelineEditor.split(&timeline, clipID: clip.id, at: 0.5)
        let resolver = FixtureResolver(files: ["audio": .file(url, naturalDuration: 2, naturalSize: nil)])
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false)
        #expect(abs(CMTimeGetSeconds(built.duration) - 1) < 0.001)
        #expect(built.audioMix?.inputParameters.allSatisfy { $0.audioTimePitchAlgorithm == .spectral } == true)
        let reader = AudioLevelReader()
        await reader.setSource(AudioLevelSource(asset: built.asset, mix: built.audioMix))
        #expect(await reader.level(at: 0.2).left < 0.2)
        #expect(await reader.level(at: 0.7).left > 0.5)
        let output = dir.appendingPathComponent("retimed.mp4")
        try await TimelineExporter.export(timeline, resolver: resolver, to: output, preset: .h264) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 1) < 0.05)
        await reader.setSource(AudioLevelSource(asset: asset, mix: nil))
        #expect(await reader.level(at: 0.2).left < 0.2)
        #expect(await reader.level(at: 0.7).left > 0.5)
    }

    @Test("Video speed maps source ranges into independent timeline segments")
    @MainActor func videoSpeed() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("video.mp4")
        try Fixtures.video(color: .blue, seconds: 2, at: url)
        let source = ClipSource(id: "video", kind: .video, displayName: "Blue")
        let clips = [Clip(source: source, start: 0, duration: 1, playbackRate: 2),
                     Clip(source: source, start: 2, duration: 4, playbackRate: 0.5)]
        let timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "V1", clips: clips)])
        let resolver = FixtureResolver(files: ["video": .file(url, naturalDuration: 2, naturalSize: nil)])
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false)
        let tracks = built.asset.tracks(withMediaType: .video)
        let track = try #require(tracks.last)
        let segments = track.segments.filter { !$0.isEmpty }
        #expect(segments.count == 2)
        #expect(CMTimeGetSeconds(segments[0].timeMapping.source.duration) == 2)
        #expect(CMTimeGetSeconds(segments[0].timeMapping.target.duration) == 1)
        #expect(CMTimeGetSeconds(segments[1].timeMapping.target.start) == 2)
        #expect(CMTimeGetSeconds(segments[1].timeMapping.target.duration) == 4)
    }
}
