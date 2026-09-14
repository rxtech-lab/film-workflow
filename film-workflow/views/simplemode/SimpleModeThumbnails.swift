import Foundation
import SwiftData

/// Poster frames for the sourceIds an agent puts on an option card.
///
/// The agent writes `imageUrl: "imported:<uuid>"` because that is the id it
/// already knows; this turns it into a file the renderer can show.
@MainActor
enum SimpleModeThumbnails {
    static func url(for source: String, in document: ProjectDocument) -> URL? {
        if let direct = URL(string: source), direct.isFileURL { return direct }
        guard let (prefix, id) = DocumentMediaResolver.parse(source) else { return nil }
        let context = ModelContext(document.container)

        switch prefix {
        case .imported:
            guard let asset = try? context.fetch(
                FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == id })
            ).first else { return nil }
            // A still is its own thumbnail; a clip has a generated one.
            if let thumbnail = asset.thumbnailFilePath {
                return document.storage.absoluteURL(for: thumbnail)
            }
            return asset.kindEnum == .image ? asset.resolveURL() : nil
        case .image:
            guard let image = try? context.fetch(
                FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == id })
            ).first else { return nil }
            return image.imageURL
        default:
            return nil
        }
    }
}
