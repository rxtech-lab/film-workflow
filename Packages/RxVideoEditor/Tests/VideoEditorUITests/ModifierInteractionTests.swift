import Foundation
import Testing
import VideoEditorCore
import VideoEffectsCore
@testable import VideoEditorUI

@Suite @MainActor
struct ModifierInteractionTests {
    @Test("Effect, in, out and join targets remain distinct across zoom levels", arguments: [4.0, 40.0, 200.0])
    func dropTargets(zoom: Double) throws {
        let source = ClipSource(id: "still", kind: .image, displayName: "Still")
        let a = Clip(source: source, start: 0, duration: 4), b = Clip(source: source, start: 4, duration: 4)
        let track = Track(kind: .video, name: "V1", clips: [a, b])
        let timeline = Timeline(tracks: [track])
        func hit(_ kind: ModifierKind, _ seconds: Double) -> ModifierDropTarget? {
            ModifierDropHitTesting.target(item: .init(kind: kind, definitionID: kind == .effect ? "rx.saturation" : "rx.cross-dissolve"),
                                          point: CGPoint(x: seconds * zoom, y: 20), track: track, timeline: timeline, pixelsPerSecond: zoom)
        }
        #expect(hit(.effect, 2) == .effect(a.id))
        #expect(hit(.transition, 1) == .transition(.start(a.id)))
        #expect(hit(.transition, 3) == .transition(.end(a.id)))
        #expect(hit(.transition, 4) == .transition(.between(outgoing: a.id, incoming: b.id)))
        #expect(hit(.transition, 5) == .transition(.start(b.id)))
        #expect(hit(.transition, 7) == .transition(.end(b.id)))
        #expect(hit(.effect, 9) == nil)
    }

    @Test("A join accepts drops near the cut, not only on it", arguments: [40.0, 200.0])
    func joinZone(zoom: Double) throws {
        let source = ClipSource(id: "still", kind: .image, displayName: "Still")
        let a = Clip(source: source, start: 0, duration: 4), b = Clip(source: source, start: 4, duration: 4)
        let track = Track(kind: .video, name: "V1", clips: [a, b])
        let timeline = Timeline(tracks: [track])
        func hit(_ pixels: Double) -> ModifierDropTarget? {
            ModifierDropHitTesting.target(item: .init(kind: .transition, definitionID: "rx.cross-dissolve"),
                                          point: CGPoint(x: 4 * zoom + pixels, y: 20), track: track, timeline: timeline, pixelsPerSecond: zoom)
        }
        let join = ModifierDropTarget.transition(.between(outgoing: a.id, incoming: b.id))
        let tolerance = ModifierDropHitTesting.joinTolerance(shorterClipWidth: 4 * zoom)
        #expect(tolerance >= 24)
        #expect(hit(-24) == join)
        #expect(hit(24) == join)
        #expect(hit(-tolerance - 1) == .transition(.end(a.id)))
        #expect(hit(tolerance + 1) == .transition(.start(b.id)))
    }
}
