import CoreGraphics
import Foundation

public struct RecordingPointerSample: Codable, Hashable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var clicked: Bool
    public init(time: Double, x: Double, y: Double, clicked: Bool = false) { self.time = time; self.x = x; self.y = y; self.clicked = clicked }
}
public struct RecordingVisibility: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var visible: Bool
    public init(start: Double, end: Double, visible: Bool) { self.start = start; self.end = end; self.visible = visible }
}
public struct RecordingZoom: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var scale: Double
    public var x: Double
    public var y: Double
    public var followsPointer: Bool
    public init(start: Double, end: Double, scale: Double = 2, x: Double = 0.5, y: Double = 0.5, followsPointer: Bool = true) {
        self.start = start; self.end = end; self.scale = scale; self.x = x; self.y = y; self.followsPointer = followsPointer
    }
}
/// A zoom whose extent is the clip's own timeline range, so the lane is the
/// only place its start and end are written.
public struct RecordingZoomSettings: Codable, Hashable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double
    public var followsPointer: Bool
    public init(scale: Double = 2, x: Double = 0.5, y: Double = 0.5, followsPointer: Bool = true) {
        self.scale = scale; self.x = x; self.y = y; self.followsPointer = followsPointer
    }
}
public struct RecordingCameraKeyframe: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var time: Double
    public var size: Double
    public var x: Double
    public var y: Double
    public var shape: RecordingClipPresentation.Shape
    public init(time: Double, size: Double = 0.22, x: Double = 0.85, y: Double = 0.82, shape: RecordingClipPresentation.Shape = .roundedRectangle) { self.time = time; self.size = size; self.x = x; self.y = y; self.shape = shape }
}
public struct RecordingClipPresentation: Codable, Hashable, Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable { case screen, camera, cursor }
    public enum Shape: String, Codable, CaseIterable, Sendable { case rectangle, roundedRectangle, circle }
    public enum Cursor: String, Codable, CaseIterable, Sendable { case arrow, hand, crosshair, circle }
    public var timeOffset: Double = 0
    public var sourceAspectRatio: Double?
    public var cameraAspectRatio: Double?
    public var screenTransform: ClipTransform?
    public var role: Role = .screen
    public var pointer: [RecordingPointerSample] = []
    public var visibility: [RecordingVisibility] = []
    public var zooms: [RecordingZoom] = []
    public var autoZoom: Bool = false
    public var zoomScale: Double = 2
    public var smoothing: Double = 0.12
    public var cursor: Cursor = .arrow
    public var cursorSize: Double = 0.025
    public var showClicks: Bool = true
    public var shape: Shape = .roundedRectangle
    public var cameraSize: Double = 0.22
    public var cameraX: Double = 0.85
    public var cameraY: Double = 0.82
    public var cameraFollowsZoom: Bool = false
    public var cameraKeyframes: [RecordingCameraKeyframe]?
    public init() {}

    public func evaluated(at time: Double) -> Self {
        guard let keyframes = cameraKeyframes, !keyframes.isEmpty else { return self }
        let frames = keyframes.sorted { $0.time < $1.time }
        let a = frames.last { $0.time <= time } ?? RecordingCameraKeyframe(time: 0, size: cameraSize, x: cameraX, y: cameraY, shape: shape)
        let b = frames.first { $0.time > time } ?? a
        let t = min(1, max(0, (time - a.time) / max(0.000001, b.time - a.time))), e = t * t * (3 - 2 * t)
        var result = self; result.cameraSize = a.size + (b.size - a.size) * e; result.cameraX = a.x + (b.x - a.x) * e; result.cameraY = a.y + (b.y - a.y) * e; result.shape = a.shape; return result
    }
    public func pointer(at time: Double) -> RecordingPointerSample? {
        guard let first = pointer.first, time >= first.time else { return nil }
        let time = max(0, time - max(0, smoothing))
        var low = 0, high = pointer.count
        while low < high { let m = (low + high) / 2; if pointer[m].time <= time { low = m + 1 } else { high = m } }
        let a = pointer[max(0, low - 1)]
        guard low < pointer.count else { return a }
        let b = pointer[low], f = max(0, min(1, (time - a.time) / max(0.000001, b.time - a.time)))
        return .init(time: time, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, clicked: a.clicked)
    }
    public func isVisible(at time: Double) -> Bool { visibility.last { $0.start <= time && time < $0.end }?.visible ?? true }
    public func zoom(at time: Double) -> (scale: Double, x: Double, y: Double) {
        var interval = zooms.last { $0.start <= time && time < $0.end }
        if interval == nil, autoZoom, let click = pointer.last(where: { $0.clicked && $0.time <= time && time < $0.time + 2.5 }) {
            interval = .init(start: click.time, end: click.time + 2.5, scale: zoomScale, x: click.x, y: click.y)
        }
        guard let z = interval else { return (1, 0.5, 0.5) }
        let edge = min(1, max(0, min(time - z.start, z.end - time) / 0.3))
        let ease = edge * edge * (3 - 2 * edge), scale = 1 + (max(1, min(8, z.scale)) - 1) * ease
        let p = z.followsPointer ? pointer(at: time) : nil
        let half = 0.5 / scale
        return (scale, min(1 - half, max(half, p?.x ?? z.x)), min(1 - half, max(half, p?.y ?? z.y)))
    }
}

public extension Timeline {
    /// Only the screen in this insertion supplies the shared zoom motion.
    /// Unlinking edit groups intentionally does not break presentation relationships.
    func resolvedRecordingClip(_ clip: Clip) -> Clip {
        if clip.recording?.role == .screen {
            var result = clip
            result.recording?.screenTransform = clip.transform
            // The lane, when it holds anything, is the whole truth: click
            // synthesis would otherwise fill the gaps between its clips.
            let lane = laneZooms(for: clip)
            if !lane.isEmpty { result.recording?.zooms = lane; result.recording?.autoZoom = false }
            return result
        }
        guard let id = clip.recordingInstanceID, var p = clip.recording, p.role != .screen,
              let leaderClip = allClips.first(where: { $0.recordingInstanceID == id && $0.recording?.role == .screen && $0.end > clip.start && $0.start < clip.end })
        else { return clip }
        // Resolve the leader first, so siblings inherit its lane zooms and not
        // the empty array it was stored with. This terminates: the screen
        // branch above returns without recursing.
        let leader = resolvedRecordingClip(leaderClip)
        guard let screen = leader.recording else { return clip }
        if p.role == .camera, p.cameraAspectRatio == nil { p.cameraAspectRatio = p.sourceAspectRatio }
        p.sourceAspectRatio = screen.sourceAspectRatio; p.screenTransform = leader.transform
        p.zooms = screen.zooms; p.autoZoom = screen.autoZoom; p.zoomScale = screen.zoomScale
        if p.pointer.isEmpty { p.pointer = screen.pointer }
        var result = clip; result.recording = p; return result
    }

    /// This screen's zoom lane clips, mapped from timeline seconds onto the
    /// presentation clock the renderer evaluates zooms on, and clamped to the
    /// screen itself. A clip cannot overlap another on its own track and the
    /// mapping is monotonic, so the intervals cannot overlap either.
    func laneZooms(for leader: Clip) -> [RecordingZoom] {
        guard let instance = leader.recordingInstanceID, let p = leader.recording else { return [] }
        var result: [RecordingZoom] = []
        for track in tracks where track.kind == .zoom && track.isEnabled {
            for zoom in track.renderedClips where zoom.recordingInstanceID == instance && zoom.end > leader.start && zoom.start < leader.end {
                guard let settings = zoom.recordingZoom else { continue }
                let a = leader.sourceTime(at: max(zoom.start, leader.start)) + p.timeOffset
                let b = leader.sourceTime(at: min(zoom.end, leader.end)) + p.timeOffset
                // Reverse playback walks the source backwards, so a > b there.
                let start = min(a, b), end = max(a, b)
                guard end > start else { continue }
                var interval = RecordingZoom(start: start, end: end, scale: settings.scale, x: settings.x, y: settings.y, followsPointer: settings.followsPointer)
                // The clip is the interval's identity. Minting a new one here
                // would make two resolutions of the same clip compare unequal.
                interval.id = zoom.id
                result.append(interval)
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}

public extension Clip {
    /// The timeline second at a source second: the inverse of `sourceTime(at:)`.
    func timelineTime(atSource time: TimeInterval) -> TimeInterval {
        isReversed ? start + (sourceEnd - time) / playbackRate
                   : start + (time - inPoint) / playbackRate
    }
}

public extension RecordingClipPresentation {
    /// Zoom windows around the recorded clicks, on the presentation clock.
    ///
    /// Clicks closer together than `minimumGap` past the end of the window they
    /// follow extend it instead of opening a new one, so a double click reads as
    /// one continuous zoom rather than a stutter of re-targets. The gap is what
    /// leaves room for a zoom out and back in between two windows.
    func autoZoomWindows(hold: Double = 2.5, minimumGap: Double = 0.6) -> [(start: Double, end: Double, x: Double, y: Double)] {
        let clicks = pointer.filter(\.clicked).sorted { $0.time < $1.time }
        guard let first = clicks.first else { return [] }
        var result: [(start: Double, end: Double, x: Double, y: Double)] = []
        var current = (start: first.time, end: first.time + hold, x: first.x, y: first.y)
        for click in clicks.dropFirst() {
            if click.time < current.end + minimumGap {
                current.end = max(current.end, click.time + hold)
            } else {
                result.append(current)
                current = (start: click.time, end: click.time + hold, x: click.x, y: click.y)
            }
        }
        result.append(current)
        // A window shorter than the two 0.3s eases never reaches full scale.
        return result.filter { $0.end - $0.start >= 2 * 0.3 }
    }
}
