import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A caption cue: seconds on the source's own clock.
public struct TextCue: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// The same cue in other languages, keyed by BCP-47. A clip whose
    /// `CaptionOptions` name one of these draws it instead of, or above,
    /// `text`; resolvers that have no translations leave this empty.
    public var translations: [String: String]

    public init(start: TimeInterval, end: TimeInterval, text: String, translations: [String: String] = [:]) {
        self.start = start
        self.end = end
        self.text = text
        self.translations = translations
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, text, translations
    }

    /// Tolerant of cues encoded before translations rode along.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
    }
}

/// What a `ClipSource` turned out to be.
public enum ResolvedMedia: Sendable {
    /// A playable file. `naturalDuration` is nil for stills.
    case file(URL, naturalDuration: TimeInterval?, naturalSize: CGSize?)
    case captions([TextCue])

    public var fileURL: URL? {
        if case .file(let url, _, _) = self { return url }
        return nil
    }
}

public enum MediaResolverError: Error, Sendable, Equatable {
    /// A Remotion source that has not been rendered for the current settings.
    case unrendered(ClipSource)
    case missing(ClipSource)
}

/// Implemented by the host app: maps source ids to files and cues.
public protocol MediaResolver: Sendable {
    func resolve(_ source: ClipSource) async throws -> ResolvedMedia
    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage?
    func libraryPreview(for source: ClipSource) async -> LibPreviewSource?
}

public extension MediaResolver {
    func libraryPreview(for source: ClipSource) async -> LibPreviewSource? { nil }
}

extension UTType {
    /// Matches the UTI the app exports in its Info.plist.
    public static let rxFootage = UTType(exportedAs: "rxlab.film-workflow.footage", conformingTo: .data)
}

/// The drag payload for footage moving from a library onto the timeline.
public struct FootageDragItem: Codable, Sendable, Hashable, Transferable {
    public var source: ClipSource
    /// Natural length, when known. Stills and captions decide their own.
    public var duration: TimeInterval?
    public var naturalWidth: Int?
    public var naturalHeight: Int?

    public init(source: ClipSource, duration: TimeInterval? = nil, naturalWidth: Int? = nil, naturalHeight: Int? = nil) {
        self.source = source
        self.duration = duration
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxFootage)
    }

    /// Default length when dropped: media plays fully, stills hold 5 s.
    public static let defaultStillDuration: TimeInterval = 5

    public var defaultClipDuration: TimeInterval {
        if let duration, duration > 0 { return duration }
        return Self.defaultStillDuration
    }
}
