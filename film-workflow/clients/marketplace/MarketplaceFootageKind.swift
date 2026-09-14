import Foundation
import VideoEditorCore

extension MarketplaceKind {
    /// The kind a piece of the film could be published as, or nil when it
    /// could not be one: the marketplace has no shelf for it, or the kind's
    /// content slot refuses the file. Stills and captions have no kind at all.
    ///
    /// Audio accepts movies too, because `MarketplaceAuthoringService.upload`
    /// extracts the track for an audio or sound-effect item.
    static func forFootage(_ kind: SourceKind, file: URL) -> MarketplaceKind? {
        guard canBeFootage(kind) else { return nil }
        let ext = file.pathExtension.lowercased()
        switch kind {
        case .video, .remotion: return ["mp4", "mov"].contains(ext) ? .footage : nil
        case .audio: return ["mp3", "wav", "m4a", "aac", "mp4", "mov"].contains(ext) ? .audio : nil
        case .image, .captions: return nil
        }
    }

    /// Whether a source of this kind could ever be an item, before its file is
    /// known. The timeline offers the action on this alone: resolving a clip to
    /// a file is asynchronous, and too much work to do while drawing a menu.
    static func canBeFootage(_ kind: SourceKind) -> Bool {
        switch kind {
        case .video, .audio, .remotion: return true
        case .image, .captions: return false
        }
    }
}

extension FootageCell {
    /// What this take would become in the marketplace, if anything. Nil once
    /// there is nothing on disk to upload — captions, and Remotion before its
    /// first render.
    var marketplaceKind: MarketplaceKind? {
        guard let mediaURL else { return nil }
        return .forFootage(kind, file: mediaURL)
    }
}

extension MarketplaceAuthoringSeed {
    /// A draft seeded from a piece of the film, or nil when that piece cannot
    /// be one: there is no file, or nothing about it fits a kind. Whether the
    /// user may author at all is the caller's to check — every call site
    /// already observes `canAuthor` so its menu is rebuilt when it lands.
    init?(title: String, sourceKind: SourceKind, file: URL?) {
        guard let file, let kind = MarketplaceKind.forFootage(sourceKind, file: file) else { return nil }
        self.init(title: title, kind: kind, contentFile: file)
    }
}
