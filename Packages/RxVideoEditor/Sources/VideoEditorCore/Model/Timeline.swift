import VideoEffectsCore
import CoreGraphics
import Foundation

/// What kind of media a clip plays. `remotion` previews live and resolves to
/// a rendered video for export; `captions` is a list of timed cues; `zoom`
/// carries no media at all, only a recording's zoom settings.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image
    case captions
    case remotion
    case zoom

    public var hasVideo: Bool { self == .video || self == .remotion }
    public var hasAudio: Bool { self == .video || self == .remotion || self == .audio }

    /// Kinds with no internal clock, whose clips are a span rather than a
    /// window onto source media: trimming one does not walk an in point.
    public var isTimeless: Bool { self == .image || self == .zoom }
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

/// Horizontal placement of caption text inside the frame.
public enum CaptionAlignment: String, Codable, Sendable, CaseIterable {
    case leading
    case center
    case trailing
}

/// Text styling for caption and title overlays. Drawn by `TextRenderer` for
/// the preview and burn-in, and mapped onto a tx3g track when captions are
/// embedded, so every field here is one the export can honour.
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
    public var italic: Bool
    public var alignment: CaptionAlignment
    /// Outline width as a fraction of the font size; 0 = none.
    public var strokeWidth: Double
    public var strokeHex: String

    public init(
        fontName: String = "Helvetica Neue",
        fontSize: Double = 0.05,
        colorHex: String = "#FFFFFF",
        backgroundHex: String = "#000000",
        backgroundOpacity: Double = 0.6,
        verticalPosition: Double = 0.9,
        bold: Bool = true,
        italic: Bool = false,
        alignment: CaptionAlignment = .center,
        strokeWidth: Double = 0,
        strokeHex: String = "#000000"
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.backgroundHex = backgroundHex
        self.backgroundOpacity = backgroundOpacity
        self.verticalPosition = verticalPosition
        self.bold = bold
        self.italic = italic
        self.alignment = alignment
        self.strokeWidth = strokeWidth
        self.strokeHex = strokeHex
    }

    public static let caption = TextStyle()

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, colorHex, backgroundHex, backgroundOpacity, verticalPosition, bold
        case italic, alignment, strokeWidth, strokeHex
    }

    /// Tolerant of fields added later: anything missing takes the default
    /// caption style's value, so timelines saved before a field existed decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextStyle.caption
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? d.colorHex
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? d.backgroundHex
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? d.backgroundOpacity
        verticalPosition = try c.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? d.verticalPosition
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
        alignment = try c.decodeIfPresent(CaptionAlignment.self, forKey: .alignment) ?? d.alignment
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex) ?? d.strokeHex
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(backgroundHex, forKey: .backgroundHex)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(verticalPosition, forKey: .verticalPosition)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(strokeHex, forKey: .strokeHex)
    }
}

/// One item on a track. Times are seconds on the timeline; `inPoint` is the
/// lower bound of the source range, including during reverse playback.
public struct Clip: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Editing links are independent of the recording's presentation identity.
    public var linkGroupID: UUID?
    public var recordingInstanceID: UUID?
    public var recording: RecordingClipPresentation?
    public var recordingShortcuts: [TextCue]?
    /// Zoom lane clips only: the zoom this clip's own range applies to the
    /// recording it names. The interval lives in `start`/`duration`.
    public var recordingZoom: RecordingZoomSettings?
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
    /// Caption clips only: which languages this clip draws and whether it
    /// drops punctuation. Ignored by every other kind of source.
    public var captions: CaptionOptions
    public var effects: [EffectInstance]
    /// Off keeps the clip where it is but out of the render: the preview, the
    /// export and the caption deliveries all skip it, leaving a gap.
    public var isEnabled: Bool

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
        text: TextStyle? = nil,
        captions: CaptionOptions = .transcript,
        effects: [EffectInstance] = [],
        isEnabled: Bool = true,
        linkGroupID: UUID? = nil,
        recordingInstanceID: UUID? = nil,
        recording: RecordingClipPresentation? = nil,
        recordingShortcuts: [TextCue]? = nil,
        recordingZoom: RecordingZoomSettings? = nil
    ) {
        self.id = id
        self.linkGroupID = linkGroupID
        self.recordingInstanceID = recordingInstanceID
        self.recording = recording
        self.recordingShortcuts = recordingShortcuts
        self.recordingZoom = recordingZoom
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
        self.captions = captions
        self.effects = effects
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case linkGroupID, recordingInstanceID, recording, recordingShortcuts, recordingZoom
        case id, source, start, duration, inPoint, playbackRate, isReversed, sourceDuration, volume, opacity, transform, text, captions, effects, isEnabled
    }

    /// Tolerant of fields added later: anything missing takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        linkGroupID = try c.decodeIfPresent(UUID.self, forKey: .linkGroupID)
        recordingInstanceID = try c.decodeIfPresent(UUID.self, forKey: .recordingInstanceID)
        recording = try c.decodeIfPresent(RecordingClipPresentation.self, forKey: .recording)
        recordingShortcuts = try c.decodeIfPresent([TextCue].self, forKey: .recordingShortcuts)
        recordingZoom = try c.decodeIfPresent(RecordingZoomSettings.self, forKey: .recordingZoom)
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
        captions = try c.decodeIfPresent(CaptionOptions.self, forKey: .captions) ?? .transcript
        effects = try c.decodeIfPresent([EffectInstance].self, forKey: .effects) ?? []
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(linkGroupID, forKey: .linkGroupID)
        try c.encodeIfPresent(recordingInstanceID, forKey: .recordingInstanceID)
        try c.encodeIfPresent(recording, forKey: .recording)
        try c.encodeIfPresent(recordingShortcuts, forKey: .recordingShortcuts)
        try c.encodeIfPresent(recordingZoom, forKey: .recordingZoom)
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
        if captions != .transcript { try c.encode(captions, forKey: .captions) }
        try c.encode(effects, forKey: .effects)
        try c.encode(isEnabled, forKey: .isEnabled)
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
    /// A lane for captions alone. A sequence may hold several — one per
    /// language, per speaker, or per section of the film — and they draw over
    /// the picture the way overlay lanes do. Captions still sit on an overlay
    /// track when that is where the user put them.
    case caption
    /// A lane of screen-recording zoom intervals. Its clips supply no picture
    /// and no sound; each one's range is a zoom window on the recording it
    /// belongs to. Only `Timeline.resolvedRecordingClip` reads it.
    case zoom

    public func accepts(_ kind: SourceKind) -> Bool {
        switch self {
        case .video: return kind == .video || kind == .image || kind == .remotion
        case .audio: return kind == .audio || kind == .video || kind == .remotion
        case .overlay: return kind == .captions || kind == .image
        case .caption: return kind == .captions
        // Nothing else belongs on a zoom lane, and a zoom clip belongs nowhere else.
        case .zoom: return kind == .zoom
        }
    }

    /// Lanes drawn over the picture rather than supplying it.
    public var drawsOverPicture: Bool { self == .overlay || self == .caption }

    /// Lanes whose clips can be heard, and so can be muted.
    public var carriesAudio: Bool { self == .video || self == .audio }
}

public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String
    public var alias: String?
    public var displayName: String { alias.flatMap { $0.isEmpty ? nil : $0 }.map { "\(name) · \($0)" } ?? name }
    public var clips: [Clip]
    public var isMuted: Bool
    /// Off leaves the lane and its clips in place but out of the render, the
    /// way disabling each of its clips would.
    public var isEnabled: Bool
    /// Pinned lanes are held on screen as the editor scrolls past them. It is
    /// purely how the lane is shown: the track keeps its place in the order.
    public var isPinned: Bool

    public init(id: UUID = UUID(), kind: TrackKind, name: String, clips: [Clip] = [], isMuted: Bool = false, isEnabled: Bool = true, alias: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.alias = alias
        self.clips = clips
        self.isMuted = isMuted
        self.isEnabled = isEnabled
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, alias, clips, isMuted, isEnabled, isPinned }

    /// Tolerant of fields added later: anything missing takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(TrackKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    public var end: TimeInterval { clips.map(\.end).max() ?? 0 }

    /// Clips ordered by start time.
    public var sortedClips: [Clip] { clips.sorted { $0.start < $1.start } }

    /// The clips the renderer draws and hears, in start order: a disabled
    /// lane offers none, and a disabled clip is left out of the lane's.
    public var renderedClips: [Clip] { isEnabled ? sortedClips.filter(\.isEnabled) : [] }

    public func clip(at time: TimeInterval) -> Clip? {
        clips.first { $0.range.contains(time) }
    }
}

/// A sequence: frame size, rate and its tracks, ordered top to bottom as shown
/// in the editor. Higher picture tracks draw over lower picture tracks.
public struct Timeline: Codable, Sendable, Hashable {
    /// 2 added caption lanes; see `TimelineCodec.decode`, which moves a film
    /// written before that onto them. 3 added zoom lanes, which need no
    /// migration but cannot be read by a build that has no such kind.
    public static let formatVersion = 3

    public var id: UUID
    public var width: Int
    public var height: Int
    public var fps: Int
    public var tracks: [Track]
    public var backgroundHex: String
    public var transitions: [TransitionInstance]

    /// The compositor and live preview paint from the bottom picture track up.
    public var pictureTracksBackToFront: [Track] {
        tracks.filter { $0.kind == .video || $0.kind.drawsOverPicture }.reversed()
    }

    public init(
        id: UUID = UUID(),
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 30,
        tracks: [Track]? = nil,
        backgroundHex: String = "#000000",
        transitions: [TransitionInstance] = []
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.fps = fps
        self.tracks = tracks ?? Timeline.defaultTracks()
        self.backgroundHex = backgroundHex
        self.transitions = transitions
    }

    /// The FCP-like starting layout: captions over one video lane, two audio lanes.
    public static func defaultTracks() -> [Track] {
        [
            Track(kind: .caption, name: "C1"),
            Track(kind: .video, name: "V1"),
            Track(kind: .audio, name: "A1"),
            Track(kind: .audio, name: "A2"),
        ]
    }

    /// Caption lanes arrived after overlay lanes, which took both captions and
    /// stills, so a film written before that keeps its cues on a `T` lane. One
    /// carrying no pictures is a caption lane in all but name and opens as
    /// one, which is why such a film shows the layout a new film gets.
    ///
    /// Only timelines older than the caption lane go through this, so an
    /// overlay track added since — empty or not — stays the lane it was asked
    /// for. An overlay holding a still is left alone either way.
    static func migratedTracks(_ tracks: [Track]) -> [Track] {
        var number = tracks.filter { $0.kind == .caption }.count
        return tracks.map { track in
            guard track.kind == .overlay, track.clips.allSatisfy({ $0.source.kind == .captions }) else { return track }
            var migrated = track
            migrated.kind = .caption
            number += 1
            // Only the names the editor gave itself are renumbered.
            if migrated.name.hasPrefix("T") { migrated.name = "C\(number)" }
            return migrated
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, width, height, fps, tracks, backgroundHex, transitions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? Timeline.defaultTracks()
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
        transitions = try c.decodeIfPresent([TransitionInstance].self, forKey: .transitions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(backgroundHex, forKey: .backgroundHex)
        try c.encode(transitions, forKey: .transitions)
    }

    public var duration: TimeInterval { tracks.map(\.end).max() ?? 0 }
    public var size: CGSize { CGSize(width: width, height: height) }
    public var frameDuration: TimeInterval { 1 / Double(max(1, fps)) }
    public var isEmpty: Bool { tracks.allSatisfy { $0.clips.isEmpty } }

    public var allClips: [Clip] { tracks.flatMap(\.clips) }

    /// Every clip the renderer reads, disabled lanes and clips dropped. The
    /// timeline keeps its length either way, so a disabled clip renders as a
    /// gap rather than pulling everything after it forward.
    public var renderedClips: [Clip] { tracks.flatMap(\.renderedClips) }

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
