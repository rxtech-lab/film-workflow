import AVFoundation
import CoreGraphics
import Foundation

/// Anything the library can drag onto the timeline.
///
/// A conformer names its media through a `ClipSource`, whose kind decides the
/// tracks it may sit on (`canBePlaced(on:)`), and says how long it is. Video
/// and imported files know their length; generated audio does not, so the
/// file is asked once and remembered in `MediaDurationCache`, and the drag
/// payload (`dragItem`) carries whatever is known at that moment.
@MainActor
public protocol TimelineDraggable {
    var canDrag: Bool { get }
    /// Identity and kind on the timeline; the host app's resolver maps it to a file.
    var clipSource: ClipSource { get }
    /// The playable or showable file. Nil for captions and unrendered Remotion.
    var mediaURL: URL? { get }
    /// Length recorded on the model, when it has one. Stills return nil.
    var storedDuration: TimeInterval? { get }
    /// Pixel size of the picture, when known.
    var naturalSize: CGSize? { get }
    /// A picture for drag cards and cells.
    var thumbnailURL: URL? { get }
}

public extension TimelineDraggable {
    var canDrag: Bool { true }
    var storedDuration: TimeInterval? { nil }
    var naturalSize: CGSize? { nil }
    var thumbnailURL: URL? { nil }

    var timelineKind: SourceKind { clipSource.kind }

    /// Whether a track of this kind can hold the footage.
    func canBePlaced(on track: TrackKind) -> Bool { canDrag && track.accepts(timelineKind) }

    /// The track kinds that can hold the footage, in layout order.
    var placeableTracks: [TrackKind] { TrackKind.allCases.filter(canBePlaced(on:)) }

    /// True for media with a running time; stills and captions hold for a chosen length.
    var isTimed: Bool { timelineKind == .audio || timelineKind == .video || timelineKind == .remotion }

    /// The length as far as it is known without touching the file.
    var knownDuration: TimeInterval? {
        if let storedDuration, storedDuration > 0 { return storedDuration }
        if isTimed, let mediaURL { return MediaDurationCache.cached(mediaURL) }
        return nil
    }

    /// The length, reading the file if nothing has recorded it yet.
    func loadDuration() async -> TimeInterval? {
        if let knownDuration { return knownDuration }
        guard isTimed, let mediaURL else { return nil }
        return await MediaDurationCache.duration(of: mediaURL)
    }

    /// The drag payload: source, known length and size.
    var dragItem: FootageDragItem {
        var source = clipSource
        source.capabilities = timelineEditingCapabilities
        return FootageDragItem(
            source: source,
            duration: knownDuration,
            naturalWidth: naturalSize.map { Int($0.width) },
            naturalHeight: naturalSize.map { Int($0.height) }
        )
    }
}

public extension FootageDragItem {
    /// Whether a track of this kind can hold the dragged footage.
    func canBePlaced(on track: TrackKind) -> Bool { source.capabilities.contains(.drag) && track.accepts(source.kind) }
}

/// Lengths of media files, read once per file.
@MainActor
public enum MediaDurationCache {
    private static var cache: [URL: TimeInterval] = [:]

    /// A length already read, without touching the file.
    public static func cached(_ url: URL) -> TimeInterval? { cache[url] }

    public static func duration(of url: URL) async -> TimeInterval? {
        if let hit = cache[url] { return hit }
        guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        cache[url] = seconds
        return seconds
    }
}
