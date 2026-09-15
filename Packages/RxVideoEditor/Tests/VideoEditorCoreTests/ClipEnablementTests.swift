import AVFoundation
import AppKit
import Foundation
import Testing

@testable import VideoEditorCore

@Suite("Clip and track enablement") @MainActor
struct ClipEnablementTests {
    /// A 2 s stereo tone, so the audio assertions run on real samples.
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

    @Test("Clips and tracks start enabled and survive a save")
    func defaultsAndCodec() throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let clip = Clip(source: ClipSource(id: "image:x", kind: .image, displayName: "X"), start: 0, duration: 2)
        #expect(clip.isEnabled)
        #expect(t.tracks.allSatisfy { $0.isEnabled })
        try TimelineEditor.insert(&t, clip: clip, on: v)
        try TimelineEditor.setEnabled(&t, clipIDs: [clip.id], isEnabled: false)
        try TimelineEditor.setTrackEnabled(&t, trackID: t.tracks[0].id, isEnabled: false)
        #expect(try TimelineCodec.decode(TimelineCodec.encode(t)) == t)
    }

    @Test("A timeline written before the switch existed opens with everything on")
    func decodesOlderTimelines() throws {
        let json = """
        {"formatVersion": 2, "timeline": {"width": 320, "height": 180, "tracks": [
            {"id": "\(UUID().uuidString)", "kind": "video", "name": "V1", "clips": [
                {"source": {"id": "x", "kind": "image", "displayName": "X"}, "start": 0, "duration": 5}
            ], "isMuted": false}
        ]}}
        """
        let t = try TimelineCodec.decode(Data(json.utf8))
        let track = try #require(t.tracks.first)
        #expect(track.isEnabled)
        #expect(try #require(t.allClips.first).isEnabled)
        #expect(t.renderedClips.count == 1)
    }

    @Test("Disabling clips and lanes takes them out of the rendered set, keeping the timeline's length")
    func renderedClips() throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let a = try #require(t.tracks.first { $0.kind == .audio }).id
        let first = Clip(source: ClipSource(id: "image:1", kind: .image, displayName: "One"), start: 0, duration: 2)
        let last = Clip(source: ClipSource(id: "image:2", kind: .image, displayName: "Two"), start: 4, duration: 2)
        let tone = Clip(source: ClipSource(id: "audio:1", kind: .audio, displayName: "Tone"), start: 0, duration: 6)
        try TimelineEditor.insert(&t, clip: first, on: v)
        try TimelineEditor.insert(&t, clip: last, on: v)
        try TimelineEditor.insert(&t, clip: tone, on: a)

        try TimelineEditor.setEnabled(&t, clipIDs: [last.id], isEnabled: false)
        #expect(t.renderedClips.map(\.id) == [first.id, tone.id])
        // The clip keeps its place, so nothing after it moves and the
        // sequence stays as long as it was.
        #expect(t.duration == 6)
        #expect(t.clip(id: last.id)?.start == 4)

        try TimelineEditor.setTrackEnabled(&t, trackID: a, isEnabled: false)
        #expect(t.renderedClips.map(\.id) == [first.id])
        #expect(t.duration == 6)

        try TimelineEditor.setEnabled(&t, clipIDs: [last.id], isEnabled: true)
        try TimelineEditor.setTrackEnabled(&t, trackID: a, isEnabled: true)
        #expect(Set(t.renderedClips.map(\.id)) == Set([first.id, last.id, tone.id]))
    }

    @Test("Unknown clips and tracks are refused without changing the timeline")
    func unknownTargets() throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let clip = Clip(source: ClipSource(id: "image:1", kind: .image, displayName: "One"), start: 0, duration: 2)
        try TimelineEditor.insert(&t, clip: clip, on: v)
        let before = t

        let stranger = UUID()
        #expect(throws: TimelineEditError.unknownClip(stranger)) {
            try TimelineEditor.setEnabled(&t, clipIDs: [clip.id, stranger], isEnabled: false)
        }
        #expect(t == before)
        #expect(throws: TimelineEditError.unknownTrack(stranger)) {
            try TimelineEditor.setTrackEnabled(&t, trackID: stranger, isEnabled: false)
        }
        #expect(t == before)
    }

    @Test("A disabled clip is left out of the picture and renders as a gap")
    func exportSkipsDisabledClips() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let red = dir.appendingPathComponent("red.png"), blue = dir.appendingPathComponent("blue.png")
        try Fixtures.png(color: .red, size: CGSize(width: 64, height: 64), at: red)
        try Fixtures.png(color: .blue, size: CGSize(width: 64, height: 64), at: blue)

        var t = Timeline(width: 64, height: 64, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let o = TimelineEditor.addTrack(&t, kind: .overlay)
        let under = Clip(source: ClipSource(id: "image:red", kind: .image, displayName: "Red"), start: 0, duration: 1)
        let tail = Clip(source: ClipSource(id: "image:red", kind: .image, displayName: "Red"), start: 2, duration: 1)
        let over = Clip(source: ClipSource(id: "image:blue", kind: .image, displayName: "Blue"), start: 0, duration: 1)
        try TimelineEditor.insert(&t, clip: under, on: v)
        try TimelineEditor.insert(&t, clip: tail, on: v)
        try TimelineEditor.insert(&t, clip: over, on: o)
        let resolver = FixtureResolver(files: [
            "image:red": .file(red, naturalDuration: nil, naturalSize: nil),
            "image:blue": .file(blue, naturalDuration: nil, naturalSize: nil),
        ])

        let covered = dir.appendingPathComponent("covered.mp4")
        try await TimelineExporter.export(t, resolver: resolver, to: covered, preset: .h264) { _ in }
        let onTop = try await Fixtures.averageColor(of: covered, at: 0.5)
        #expect(onTop.b > 0.6 && onTop.r < 0.3)

        try TimelineEditor.setEnabled(&t, clipIDs: [over.id, tail.id], isEnabled: false)
        let output = dir.appendingPathComponent("out.mp4")
        try await TimelineExporter.export(t, resolver: resolver, to: output, preset: .h264) { _ in }
        // The overlay is gone, so the picture below it is what renders.
        let uncovered = try await Fixtures.averageColor(of: output, at: 0.5)
        #expect(uncovered.r > 0.6 && uncovered.b < 0.3)
        // The disabled tail still holds its place: the film is as long as it
        // was, with the background where the clip would have been.
        let asset = AVURLAsset(url: output)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 3) < 0.1)
        let gap = try await Fixtures.averageColor(of: output, at: 2.5)
        #expect(gap.r < 0.2 && gap.g < 0.2 && gap.b < 0.2)
    }

    @Test("Disabled clips and lanes are left out of the audio mix")
    func compositionSkipsDisabledAudio() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("blue.mp4")
        try Fixtures.video(color: .blue, seconds: 2, at: movie)
        let audio = dir.appendingPathComponent("tone.caf")
        try tone(at: audio)

        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let lanes = t.tracks.filter { $0.kind == .audio }.map(\.id)
        let picture = Clip(source: ClipSource(id: "video:b", kind: .video, displayName: "B"), start: 0, duration: 2)
        let first = Clip(source: ClipSource(id: "audio:1", kind: .audio, displayName: "One"), start: 0, duration: 2)
        let second = Clip(source: ClipSource(id: "audio:2", kind: .audio, displayName: "Two"), start: 0, duration: 2)
        try TimelineEditor.insert(&t, clip: picture, on: v)
        try TimelineEditor.insert(&t, clip: first, on: lanes[0])
        try TimelineEditor.insert(&t, clip: second, on: lanes[1])
        let resolver = FixtureResolver(files: [
            "video:b": .file(movie, naturalDuration: 2, naturalSize: CGSize(width: 320, height: 180)),
            "audio:1": .file(audio, naturalDuration: 2, naturalSize: nil),
            "audio:2": .file(audio, naturalDuration: 2, naturalSize: nil),
        ])

        try TimelineEditor.setEnabled(&t, clipIDs: [first.id], isEnabled: false)
        try TimelineEditor.setTrackEnabled(&t, trackID: lanes[1], isEnabled: false)
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false, includeSilentAudio: true)
        #expect(built.audioTrackIDs[first.id] == nil)
        #expect(built.audioTrackIDs[second.id] == nil)

        try TimelineEditor.setEnabled(&t, clipIDs: [first.id], isEnabled: true)
        let heard = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false, includeSilentAudio: true)
        #expect(heard.audioTrackIDs[first.id] != nil)
        #expect(heard.audioTrackIDs[second.id] == nil)
    }

    @Test("A clip with no media yet stops holding up an export once it is disabled")
    func disabledPlaceholdersDoNotBlockExport() async throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = try #require(t.tracks.first { $0.kind == .video }).id
        let remotion = ClipSource(id: "remotion:1", kind: .remotion, displayName: "Title")
        let clip = Clip(source: remotion, start: 0, duration: 2)
        try TimelineEditor.insert(&t, clip: clip, on: v)
        let resolver = FixtureResolver(files: [:], unrendered: ["remotion:1"])

        await #expect(throws: CompositionBuildError.self) {
            _ = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false)
        }
        try TimelineEditor.setEnabled(&t, clipIDs: [clip.id], isEnabled: false)
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false)
        #expect(built.placeholders.isEmpty)
    }

    @Test("Captions on a disabled clip or lane are not drawn")
    func captionsFollowTheSwitch() async throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let caption = try #require(t.tracks.first { $0.kind == .caption }).id
        let clip = Clip(source: ClipSource(id: "caption:c", kind: .captions, displayName: "C"), start: 0, duration: 3)
        try TimelineEditor.insert(&t, clip: clip, on: caption)
        let resolver = FixtureResolver(files: ["caption:c": .captions([TextCue(start: 0, end: 3, text: "HELLO")])])

        func textLayers(_ timeline: Timeline) async throws -> Int {
            let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false)
            return built.videoComposition.instructions
                .compactMap { $0 as? TimelineCompositionInstruction }
                .flatMap(\.layers)
                .filter { if case .text = $0 { return true } else { return false } }
                .count
        }

        #expect(try await textLayers(t) == 1)
        try TimelineEditor.setEnabled(&t, clipIDs: [clip.id], isEnabled: false)
        #expect(try await textLayers(t) == 0)
        try TimelineEditor.setEnabled(&t, clipIDs: [clip.id], isEnabled: true)
        try TimelineEditor.setTrackEnabled(&t, trackID: caption, isEnabled: false)
        #expect(try await textLayers(t) == 0)
    }
}
