import XCTest
@testable import VideoEditorUI

@MainActor
final class TimelineViewportTests: XCTestCase {
    func testVisiblePlayheadKeepsItsScreenPosition() {
        // Playhead at 10 s, 20 px/s, scrolled 100 px: it sits at screen x 100.
        let offset = TimelineViewport.scrollOffset(keeping: 10, from: 20, to: 40, offsetX: 100, viewportWidth: 800)
        XCTAssertEqual(offset, 300)
        XCTAssertEqual(10 * 40 - offset, 100, "playhead stays at the same screen x after zooming in")

        let zoomedOut = TimelineViewport.scrollOffset(keeping: 10, from: 20, to: 10, offsetX: 100, viewportWidth: 800)
        XCTAssertEqual(10 * 10 - zoomedOut, 100, "and after zooming out")
    }

    func testOffscreenPlayheadAnchorsOnViewportCentre() {
        // Playhead at 100 s is far right of a viewport showing 5–45 s.
        let offset = TimelineViewport.scrollOffset(keeping: 100, from: 20, to: 40, offsetX: 100, viewportWidth: 800)
        // Centre time was (100 + 400) / 20 = 25 s; it must still sit at x 400.
        XCTAssertEqual(25 * 40 - offset, 400)
    }

    func testOffsetNeverGoesNegative() {
        let offset = TimelineViewport.scrollOffset(keeping: 1, from: 20, to: 2, offsetX: 0, viewportWidth: 800)
        XCTAssertEqual(offset, 0)
    }
}
