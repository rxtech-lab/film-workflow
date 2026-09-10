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
