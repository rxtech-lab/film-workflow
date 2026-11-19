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

    func testLargeTimelineMountsOnlyNearbyRows() {
        let offset: CGFloat = 20 + 900 * 53
        let window = TimelineRowWindow(offset: offset, height: 318, rulerHeight: 20, rowHeight: 53)
        let nearby = TimelineRowWindow(offset: offset + 15, height: 318, rulerHeight: 20, rowHeight: 53)

        XCTAssertEqual(window, nearby)
        XCTAssertEqual(window.indices(trackCount: 1_931, pinnedRows: [], activeRow: nil, clipRowOffset: 0), Array(896..<912))
        XCTAssertEqual(window.indices(trackCount: 902, pinnedRows: [], activeRow: nil, clipRowOffset: 0), Array(896..<902))
    }

    func testVisiblePinsAndDragSourcesOutsideTheWindowAreMounted() {
        let window = TimelineRowWindow(offset: 20 + 900 * 53, height: 106, rulerHeight: 20, rowHeight: 53)
        let indices = window.indices(trackCount: 1_931, pinnedRows: [0, 20, 30], activeRow: 1_000, clipRowOffset: 100)

        XCTAssertEqual(indices, [0, 20] + Array(796..<808) + Array(896..<908) + [1_000])
    }
}
