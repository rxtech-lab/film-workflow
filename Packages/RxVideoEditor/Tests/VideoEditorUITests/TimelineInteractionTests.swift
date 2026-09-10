import XCTest
import VideoEditorCore
@testable import VideoEditorUI

final class TimelineInteractionTests: XCTestCase {
    @MainActor
    func testNarrowClipsAndCapabilityHitTesting() {
        for width in [4.0, 12, 100, 1000] {
            XCTAssertEqual(TimelineClipInteraction.mode(at: 0, width: width, capabilities: [.duration, .drag], tool: .select), .trimLeading)
            XCTAssertEqual(TimelineClipInteraction.mode(at: width, width: width, capabilities: [.duration, .drag], tool: .select), .trimTrailing)
            XCTAssertEqual(TimelineClipInteraction.mode(at: width / 2, width: width, capabilities: [.duration, .drag], tool: .select), .move)
            XCTAssertNil(TimelineClipInteraction.mode(at: 0, width: width, capabilities: [.duration, .drag], tool: .blade))
            XCTAssertNil(TimelineClipInteraction.mode(at: 0, width: width, capabilities: [], tool: .select))
        }
    }

    @MainActor
    func testSpeedBarEdgesRetimeWhileLowerEdgesTrim() {
        let capabilities: TimelineEditingCapabilities = [.duration, .speed, .drag]
        for width in [4.0, 12, 100, 1000] {
            XCTAssertEqual(TimelineClipInteraction.mode(at: 0, y: 5, width: width, capabilities: capabilities, tool: .select, showsSpeedOverlay: true), .retimeLeading)
            XCTAssertEqual(TimelineClipInteraction.mode(at: width, y: 5, width: width, capabilities: capabilities, tool: .select, showsSpeedOverlay: true), .retimeTrailing)
            XCTAssertEqual(TimelineClipInteraction.mode(at: 0, y: 25, width: width, capabilities: capabilities, tool: .select, showsSpeedOverlay: true), .trimLeading)
            XCTAssertEqual(TimelineClipInteraction.mode(at: width, y: 25, width: width, capabilities: capabilities, tool: .select, showsSpeedOverlay: true), .trimTrailing)
            XCTAssertNil(TimelineClipInteraction.mode(at: 0, y: 5, width: width, capabilities: capabilities, tool: .blade, showsSpeedOverlay: true))
        }
        var clip = Clip(source: ClipSource(id: "audio", kind: .audio, displayName: "Audio"), start: 0, duration: 2)
        XCTAssertFalse(TimelineClipInteraction.showsSpeedOverlay(for: clip))
        clip.playbackRate = 1.2
        XCTAssertTrue(TimelineClipInteraction.showsSpeedOverlay(for: clip))
        clip.source.capabilities.remove(.speed)
        XCTAssertFalse(TimelineClipInteraction.showsSpeedOverlay(for: clip))
    }
}
