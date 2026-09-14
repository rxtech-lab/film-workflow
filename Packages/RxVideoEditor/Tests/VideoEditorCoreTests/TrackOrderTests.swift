import AppKit
import Foundation
import Testing
import VideoEffectsCore
@testable import VideoEditorCore

@Suite("Track order") @MainActor
struct TrackOrderTests {
    @Test("Reordering retains tracks, clips and transitions and survives saving")
    func preservesEdit() throws {
        var timeline = Timeline()
        let clip = Clip(source: ClipSource(id: "still", kind: .image, displayName: "Still"), start: 2, duration: 5)
        let video = try #require(timeline.tracks.first { $0.kind == .video })
        try TimelineEditor.insert(&timeline, clip: clip, on: video.id)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .start(clip.id))
        timeline.tracks[2].isMuted = true
        let before = timeline
        let reordered = [before.tracks[3], before.tracks[1], before.tracks[0], before.tracks[2]]
        try TimelineEditor.reorderTracks(&timeline, trackIDs: reordered.map(\.id))
        #expect(timeline.tracks == reordered)
        #expect(timeline.transitions == before.transitions)
        #expect(timeline.id == before.id)
        #expect(try TimelineCodec.decode(TimelineCodec.encode(timeline)) == timeline)
        try TimelineEditor.reorderTracks(&timeline, trackIDs: before.tracks.map(\.id))
        #expect(timeline == before)
    }

    @Test("Incomplete, duplicate and foreign IDs are refused atomically")
    func invalidOrders() throws {
        var timeline = Timeline()
        let before = timeline
        let ids = timeline.tracks.map(\.id)
        for order in [[], Array(ids.dropLast()), ids + [UUID()], [ids[0], ids[0], ids[2], ids[3]],
                      [UUID(), ids[1], ids[2], ids[3]]] {
            #expect(throws: TimelineEditError.invalidTrackOrder) {
                try TimelineEditor.reorderTracks(&timeline, trackIDs: order)
            }
            #expect(timeline == before)
        }
        try TimelineEditor.reorderTracks(&timeline, trackIDs: ids)
        #expect(timeline == before)
    }

    @Test("Moving an overlay below a video changes the exported picture")
    func exportOrder() async throws {
        let root = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blue = root.appendingPathComponent("blue.png"), red = root.appendingPathComponent("red.png")
        try Fixtures.png(color: .blue, size: CGSize(width: 64, height: 64), at: blue)
        try Fixtures.png(color: .red, size: CGSize(width: 64, height: 64), at: red)
        let source = ClipSource(id: "blue", kind: .image, displayName: "Blue")
        let overlay = Track(kind: .overlay, name: "T1", clips: [Clip(source: source, start: 0, duration: 1)])
        let video = Track(kind: .video, name: "V1", clips: [Clip(
            source: ClipSource(id: "red", kind: .image, displayName: "Red"), start: 0, duration: 1
        )])
        let audio = Track(kind: .audio, name: "A1")
        var timeline = Timeline(width: 64, height: 64, tracks: [overlay, video, audio])
        let resolver = FixtureResolver(files: ["blue": .file(blue, naturalDuration: nil, naturalSize: nil),
                                               "red": .file(red, naturalDuration: nil, naturalSize: nil)])
        for moved in [false, true] {
            if moved { try TimelineEditor.reorderTracks(&timeline, trackIDs: [video.id, audio.id, overlay.id]) }
            let output = root.appendingPathComponent("\(moved).mp4")
            try await TimelineExporter.export(timeline, resolver: resolver, to: output, preset: .h264) { _ in }
            let color = try await Fixtures.averageColor(of: output, at: 0.5)
            #expect(moved ? color.r > 0.8 && color.b < 0.2 : color.b > 0.8 && color.r < 0.2)
        }
    }
}
