import Foundation
import VideoEditorCore

extension MarketplaceKind {
    /// The kind a piece of the film could be published as, or nil when it
    /// could not be one: the marketplace has no shelf for it, or the kind's
    /// content slot refuses the file. Captions have no kind at all.
    ///
    /// Audio accepts movies too, because `MarketplaceAuthoringService.upload`
    /// extracts the track for an audio or sound-effect item. Footage accepts
    /// stills as well as clips; which shelf it lands on is the server's to
    /// decide from the file, not this call's.
    static func forFootage(_ kind: SourceKind, file: URL?) -> MarketplaceKind? {
        let ext = file?.pathExtension.lowercased() ?? ""
        switch kind {
        // A composition publishes its whole project, not the file in front of
        // it; the render only proves there is something to show for it.
        case .remotion: return file != nil ? .remotion : nil
        case .video: return ["mp4", "mov"].contains(ext) ? .footage : nil
        case .image: return ["png", "jpg", "jpeg", "webp"].contains(ext) ? .footage : nil
        case .audio: return ["mp3", "wav", "m4a", "aac", "mp4", "mov"].contains(ext) ? .audio : nil
        case .captions, .zoom: return nil
        }
    }

    /// Whether a source of this kind could ever be an item, before its file is
    /// known. The timeline offers the action on this alone: resolving a clip to
    /// a file is asynchronous, and too much work to do while drawing a menu.
    static func canBeFootage(_ kind: SourceKind) -> Bool {
        switch kind {
        case .video, .audio, .image, .remotion: return true
        case .captions, .zoom: return false
        }
    }

    /// Whether a draft of this kind can be seeded from its file alone. A
    /// Remotion composition cannot: its content is an archive of the whole
    /// project, which only `MarketplaceSeedRequest.remotion` can build.
    var seedsFromFileAlone: Bool { self != .remotion }
}

extension FootageCell {
    /// What this take would become in the marketplace, if anything. Nil once
    /// there is nothing on disk to publish — captions, and Remotion before its
    /// first render.
    var marketplaceKind: MarketplaceKind? {
        MarketplaceKind.forFootage(kind, file: mediaURL)
    }
}

extension MarketplaceAuthoringSeed {
    /// A draft seeded from a piece of the film, or nil when that piece cannot
    /// be one: there is no file, nothing about it fits a kind, or the kind
    /// needs more than a file. Whether the user may author at all is the
    /// caller's to check — every call site already observes `canAuthor` so its
    /// menu is rebuilt when it lands.
    init?(title: String, sourceKind: SourceKind, file: URL?) {
        guard let file, let kind = MarketplaceKind.forFootage(sourceKind, file: file), kind.seedsFromFileAlone else { return nil }
        self.init(title: title, kind: kind, contentFile: file)
    }
}
