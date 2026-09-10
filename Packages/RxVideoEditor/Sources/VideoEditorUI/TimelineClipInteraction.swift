import Foundation
import VideoEditorCore

enum TimelineTool { case select, blade }

/// Shared mouse-down hit testing; selection never changes which edge is editable.
enum TimelineClipInteraction {
    enum Mode {
        case move, trimLeading, trimTrailing, retimeLeading, retimeTrailing

        var isRetiming: Bool { self == .retimeLeading || self == .retimeTrailing }
        var isLeading: Bool { self == .trimLeading || self == .retimeLeading }
    }

    static let speedOverlayHeight: CGFloat = 18

    static func showsSpeedOverlay(for clip: Clip) -> Bool {
        clip.source.capabilities.contains(.speed) && abs(clip.playbackRate - 1) > 0.000001
    }

    static func handleWidth(for width: CGFloat) -> CGFloat { min(10, width / 3) }

    /// The pointer must travel this far before a press on a lane becomes a
    /// selection rectangle instead of a click.
    static let marqueeThreshold: CGFloat = 4

    /// The lanes a selection rectangle spanning `minY`...`maxY` (canvas
    /// coordinates, ruler included) touches, or nil when it lies entirely in
    /// the ruler or there are no lanes. Space below the last lane counts as
    /// the last lane so a drag started there still reaches it.
    static func laneRange(minY: CGFloat, maxY: CGFloat, rulerHeight: CGFloat, laneHeight: CGFloat, laneCount: Int) -> ClosedRange<Int>? {
        guard laneCount > 0, maxY >= rulerHeight else { return nil }
        let pitch = laneHeight + 1
        let first = Int(((max(minY, rulerHeight) - rulerHeight) / pitch).rounded(.down))
        let last = Int(((maxY - rulerHeight) / pitch).rounded(.down))
        let lower = min(max(0, first), laneCount - 1)
        let upper = min(max(lower, last), laneCount - 1)
        return lower...upper
    }

    static func mode(at x: CGFloat, y: CGFloat = .infinity, width: CGFloat, capabilities: TimelineEditingCapabilities, tool: TimelineTool, showsSpeedOverlay: Bool = false) -> Mode? {
        guard tool == .select else { return nil }
        let handle = handleWidth(for: width)
        if showsSpeedOverlay, capabilities.contains(.speed), y >= 0, y < speedOverlayHeight {
            if x <= handle { return .retimeLeading }
            if x >= width - handle { return .retimeTrailing }
        }
        if capabilities.contains(.duration) {
            if x <= handle { return .trimLeading }
            if x >= width - handle { return .trimTrailing }
        }
        return capabilities.contains(.drag) ? .move : nil
    }
}
