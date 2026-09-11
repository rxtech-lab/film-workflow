import Foundation
import VideoEditorCore

enum TimelineTool { case select, blade }

/// Shared mouse-down hit testing; selection never changes which edge is editable.
enum TimelineClipInteraction {
    enum Mode {
        case move, trimLeading, trimTrailing, retimeLeading, retimeTrailing, volume

        var isRetiming: Bool { self == .retimeLeading || self == .retimeTrailing }
        var isLeading: Bool { self == .trimLeading || self == .retimeLeading }
    }

    static let speedOverlayHeight: CGFloat = 18

    /// The waveform strip along the bottom of a clip that has audio; dragging
    /// it up or down changes the clip's volume.
    static func waveformHeight(for kind: SourceKind) -> CGFloat {
        guard kind.hasAudio else { return 0 }
        return kind == .audio ? 28 : 14
    }

    /// Dragging the waveform this many points changes the volume by 100%.
    static let volumePointsPerUnit: CGFloat = 40
    static let volumeRange: ClosedRange<Float> = 0...2

    /// The volume a drag that began at `original` and has travelled
    /// `translation` points vertically (positive = down) previews. The
    /// result sticks at 100% so a drag can land there without hunting.
    static func volume(from original: Float, translation: CGFloat) -> Float {
        let raw = original - Float(translation / volumePointsPerUnit)
        let clamped = min(volumeRange.upperBound, max(volumeRange.lowerBound, raw))
        return abs(clamped - 1) < 0.04 ? 1 : clamped
    }

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

    /// `waveformTop` is the y where the waveform strip begins, or nil when
    /// the clip has none. The clip's edges still trim inside the strip; the
    /// rest of the strip adjusts volume, and the body above it moves.
    static func mode(at x: CGFloat, y: CGFloat = .infinity, width: CGFloat, capabilities: TimelineEditingCapabilities, tool: TimelineTool, showsSpeedOverlay: Bool = false, waveformTop: CGFloat? = nil) -> Mode? {
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
        if let waveformTop, y.isFinite, y >= waveformTop { return .volume }
        return capabilities.contains(.drag) ? .move : nil
    }
}
