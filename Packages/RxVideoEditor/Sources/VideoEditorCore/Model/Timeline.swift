import CoreGraphics
import Foundation

/// What kind of media a clip plays. `remotion` is a video whose file only
/// exists once the app has rendered it; `captions` is a list of timed cues.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image
    case captions
    case remotion

    public var hasVideo: Bool { self == .video || self == .remotion }
    public var hasAudio: Bool { self == .video || self == .remotion || self == .audio }
}

/// Opaque reference to something the host app can resolve to media.
///
/// `id` is defined by the app (for example `"video:<uuid>"`); the package
/// never interprets it, it only hands it back to the `MediaResolver`.
public struct ClipSource: Codable, Sendable, Hashable {
    public var id: String
    public var kind: SourceKind
    public var displayName: String

    public var capabilities: TimelineEditingCapabilities

    public init(id: String, kind: SourceKind, displayName: String, capabilities: TimelineEditingCapabilities? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.capabilities = capabilities ?? .defaults(for: kind)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, displayName, capabilities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        displayName = try c.decode(String.self, forKey: .displayName)
        capabilities = try c.decodeIfPresent(TimelineEditingCapabilities.self, forKey: .capabilities) ?? .defaults(for: kind)
    }
}

/// How a clip's picture fills the sequence frame.
public enum FitMode: String, Codable, Sendable, CaseIterable {
    /// Scale to fit, letterboxed.
    case fit
    /// Scale to fill, cropped.
    case fill
    /// Stretch to the frame.
    case stretch
}

public struct ClipTransform: Codable, Sendable, Hashable {
    public var fit: FitMode
    /// Extra scale on top of the fit, 1 = none.
    public var scale: Double
    /// Offset as a fraction of the frame, 0 = centred.
    public var offsetX: Double
    public var offsetY: Double

    public init(fit: FitMode = .fit, scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.fit = fit
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public static let identity = ClipTransform()
}

/// Text styling for caption and title overlays.
public struct TextStyle: Codable, Sendable, Hashable {
    public var fontName: String
    /// Fraction of the frame height.
    public var fontSize: Double
    public var colorHex: String
    public var backgroundHex: String
    public var backgroundOpacity: Double
    /// 0 = top, 0.5 = middle, 1 = bottom.
    public var verticalPosition: Double
    public var bold: Bool

    public init(
        fontName: String = "Helvetica Neue",
        fontSize: Double = 0.05,
        colorHex: String = "#FFFFFF",
        backgroundHex: String = "#000000",
        backgroundOpacity: Double = 0.6,
        verticalPosition: Double = 0.9,
        bold: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.backgroundHex = backgroundHex
        self.backgroundOpacity = backgroundOpacity
        self.verticalPosition = verticalPosition
        self.bold = bold
    }

    public static let caption = TextStyle()
}

/// One item on a track. Times are seconds on the timeline; `inPoint` is the
/// lower bound of the source range, including during reverse playback.
public struct Clip: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var source: ClipSource
    public var start: TimeInterval
    public var duration: TimeInterval
    public var inPoint: TimeInterval
    /// Source seconds consumed per timeline second; always finite and positive.
    public var playbackRate: Double
    public var isReversed: Bool
    /// Full source length, when known, for trimming bounds.
    public var sourceDuration: TimeInterval?
    public var volume: Float
    public var opacity: Float
    public var transform: ClipTransform
    public var text: TextStyle?

    public init(
        id: UUID = UUID(),
        source: ClipSource,
        start: TimeInterval,
        duration: TimeInterval,
        inPoint: TimeInterval = 0,
        playbackRate: Double = 1,
        isReversed: Bool = false,
        sourceDuration: TimeInterval? = nil,
        volume: Float = 1,
        opacity: Float = 1,
        transform: ClipTransform = .identity,
        text: TextStyle? = nil
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.duration = duration
        self.inPoint = inPoint
        self.playbackRate = playbackRate
        self.isReversed = isReversed
        self.sourceDuration = sourceDuration
        self.volume = volume
        self.opacity = opacity
        self.transform = transform
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, start, duration, inPoint, playbackRate, isReversed, sourceDuration, volume, opacity, transform, text
    }

    /// Tolerant of fields added later: anything missing takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(ClipSource.self, forKey: .source)
        start = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        inPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .inPoint) ?? 0
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        guard playbackRate.isFinite, playbackRate > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .playbackRate, in: c, debugDescription: "Playback rate must be positive and finite")
        }
        isReversed = try c.decodeIfPresent(Bool.self, forKey: .isReversed) ?? false
        sourceDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .identity
        text = try c.decodeIfPresent(TextStyle.self, forKey: .text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode(inPoint, forKey: .inPoint)
        try c.encode(playbackRate, forKey: .playbackRate)
        try c.encode(isReversed, forKey: .isReversed)
        try c.encodeIfPresent(sourceDuration, forKey: .sourceDuration)
        try c.encode(volume, forKey: .volume)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(transform, forKey: .transform)
        try c.encodeIfPresent(text, forKey: .text)
    }

    public var sourceRangeDuration: TimeInterval { duration * playbackRate }
    public var sourceEnd: TimeInterval { inPoint + sourceRangeDuration }

    public func sourceTime(at timelineTime: TimeInterval) -> TimeInterval {
        let elapsed = min(duration, max(0, timelineTime - start)) * playbackRate
        return isReversed ? sourceEnd - elapsed : inPoint + elapsed
    }

    public var end: TimeInterval { start + duration }
    public var range: Range<TimeInterval> { start..<end }

    public func overlaps(_ other: Clip) -> Bool {
        other.id != id && start < other.end && other.start < end
    }
}

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case overlay

    public func accepts(_ kind: SourceKind) -> Bool {
        switch self {
        case .video: return kind == .video || kind == .image || kind == .remotion
        case .audio: return kind == .audio || kind == .video || kind == .remotion
        case .overlay: return kind == .captions || kind == .image
        }
    }
}

public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String
    public var clips: [Clip]
    public var isMuted: Bool

    public init(id: UUID = UUID(), kind: TrackKind, name: String, clips: [Clip] = [], isMuted: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.clips = clips
        self.isMuted = isMuted
    }

    public var end: TimeInterval { clips.map(\.end).max() ?? 0 }

    /// Clips ordered by start time.
    public var sortedClips: [Clip] { clips.sorted { $0.start < $1.start } }

    public func clip(at time: TimeInterval) -> Clip? {
        clips.first { $0.range.contains(time) }
    }
}

/// A sequence: frame size, rate and its tracks. Track order is bottom to top
/// for the picture (later video tracks draw over earlier ones, overlays last).
public struct Timeline: Codable, Sendable, Hashable {
    public static let formatVersion = 1

    public var id: UUID
    public var width: Int
    public var height: Int
    public var fps: Int
    public var tracks: [Track]
    public var backgroundHex: String

    public init(
        id: UUID = UUID(),
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 30,
        tracks: [Track]? = nil,
        backgroundHex: String = "#000000"
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.fps = fps
        self.tracks = tracks ?? Timeline.defaultTracks()
        self.backgroundHex = backgroundHex
    }

    /// The FCP-like starting layout: captions over one video lane, two audio lanes.
    public static func defaultTracks() -> [Track] {
        [
            Track(kind: .overlay, name: "T1"),
            Track(kind: .video, name: "V1"),
            Track(kind: .audio, name: "A1"),
            Track(kind: .audio, name: "A2"),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id, width, height, fps, tracks, backgroundHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? Timeline.defaultTracks()
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(backgroundHex, forKey: .backgroundHex)
    }

    public var duration: TimeInterval { tracks.map(\.end).max() ?? 0 }
    public var size: CGSize { CGSize(width: width, height: height) }
    public var frameDuration: TimeInterval { 1 / Double(max(1, fps)) }
    public var isEmpty: Bool { tracks.allSatisfy { $0.clips.isEmpty } }

    public var allClips: [Clip] { tracks.flatMap(\.clips) }

    public func track(containing clipID: UUID) -> Track? {
        tracks.first { $0.clips.contains { $0.id == clipID } }
    }

    public func clip(id: UUID) -> Clip? {
        allClips.first { $0.id == id }
    }

    public subscript(trackID id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Snaps a time to the frame grid.
    public func quantized(_ time: TimeInterval) -> TimeInterval {
        let frame = (time / frameDuration).rounded()
        return max(0, frame * frameDuration)
    }
}
