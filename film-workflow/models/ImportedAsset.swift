import Foundation
import SwiftData

enum ImportedAssetKind: String, Codable, CaseIterable {
    case video
    case audio
    case image

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }
}

/// A file the user brought in from Finder: either copied into `Media/Imported`
/// or referenced in place through a bookmark.
@Model
final class ImportedAsset: GroupableProject {
    var id: UUID = UUID()
    var marketplaceItemId: String?
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupID: UUID?

    var kind: String = ImportedAssetKind.video.rawValue
    /// Package-relative when copied in.
    var relativePath: String?
    /// Set when referenced in place.
    var bookmarkData: Data?
    var bookmarkIsSecurityScoped: Bool = false
    var captureMetadata: Data?
    var originalPath: String = ""

    var durationSeconds: Double = 0
    var width: Int = 0
    var height: Int = 0
    var thumbnailFilePath: String?

    init(name: String, kind: ImportedAssetKind, originalPath: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
        self.kind = kind.rawValue
        self.originalPath = originalPath
    }

    var kindEnum: ImportedAssetKind {
        get { ImportedAssetKind(rawValue: kind) ?? .video }
        set { kind = newValue.rawValue }
    }

    var isReferenced: Bool { relativePath == nil }

    var thumbnailURL: URL? { thumbnailFilePath.map { ProjectStorage.for(model: self).absoluteURL(for: $0) } }

    /// The media file, resolving a bookmark when the asset is referenced.
    func resolveURL() -> URL? {
        if let relativePath {
            return ProjectStorage.for(model: self).absoluteURL(for: relativePath)
        }
        if let bookmarkData {
            var stale = false
            let options: URL.BookmarkResolutionOptions = bookmarkIsSecurityScoped ? [.withSecurityScope] : []
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: options, bookmarkDataIsStale: &stale) {
                if bookmarkIsSecurityScoped { _ = url.startAccessingSecurityScopedResource() }
                if stale, let fresh = try? url.bookmarkData(options: bookmarkIsSecurityScoped ? [.withSecurityScope] : []) {
                    self.bookmarkData = fresh
                }
                return url
            }
        }
        let fallback = URL(fileURLWithPath: originalPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    var dimensionsLabel: String {
        var parts: [String] = []
        if durationSeconds > 0 { parts.append("\(Int(durationSeconds.rounded()))s") }
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        parts.append(isReferenced ? "referenced" : "copied")
        return parts.joined(separator: " · ")
    }
}
