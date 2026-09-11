import Foundation

/// Footage opts into each operation independently, following `TimelineDraggable`.
@MainActor public protocol TimelineDurationChangeable: TimelineDraggable {
    var canChangeDuration: Bool { get }
}
@MainActor public protocol TimelineCuttable: TimelineDraggable {
    var canCut: Bool { get }
}
@MainActor public protocol TimelineReversible: TimelineDraggable {
    var canReverse: Bool { get }
}
@MainActor public protocol TimelineSpeedChangeable: TimelineDraggable {
    var canChangeSpeed: Bool { get }
}

public extension TimelineDurationChangeable { var canChangeDuration: Bool { true } }
public extension TimelineCuttable { var canCut: Bool { true } }
public extension TimelineReversible { var canReverse: Bool { true } }
public extension TimelineSpeedChangeable { var canChangeSpeed: Bool { true } }

/// Stored in the drag payload and project so editing does not need the library model.
public struct TimelineEditingCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let duration = Self(rawValue: 1 << 0)
    public static let cut = Self(rawValue: 1 << 1)
    public static let reverse = Self(rawValue: 1 << 2)
    public static let speed = Self(rawValue: 1 << 3)
    public static let drag = Self(rawValue: 1 << 4)

    /// Compatibility for projects and payloads saved before capabilities existed.
    public static func defaults(for kind: SourceKind) -> Self {
        switch kind {
        case .audio: return [.duration, .cut, .reverse, .speed, .drag]
        case .video, .remotion: return [.duration, .cut, .speed, .drag]
        case .image, .captions: return [.duration, .cut, .drag]
        }
    }
}

public extension TimelineDraggable {
    var timelineEditingCapabilities: TimelineEditingCapabilities {
        var result: TimelineEditingCapabilities = canDrag ? [.drag] : []
        if (self as? any TimelineDurationChangeable)?.canChangeDuration == true { result.insert(.duration) }
        if (self as? any TimelineCuttable)?.canCut == true { result.insert(.cut) }
        if (self as? any TimelineReversible)?.canReverse == true { result.insert(.reverse) }
        if (self as? any TimelineSpeedChangeable)?.canChangeSpeed == true { result.insert(.speed) }
        return result
    }
}
