import AppKit
import AVFoundation
import Foundation
import SwiftData

/// Turns a file into an `ImportedAsset`: the copy into `Media/Imported`, the
/// duration/size probe and the poster frame. The import sheet, the MCP
/// `footage_import` tool and the marketplace all go through here so an asset
/// looks the same however it arrived.
@MainActor
enum MediaImporter {
    /// Copies `url` into the package and inserts the asset.
    static func importCopy(url: URL, kind: ImportedAssetKind, name: String, groupID: UUID?, storage: ProjectStorage, context: ModelContext) async throws -> ImportedAsset {
        let asset = ImportedAsset(name: name, kind: kind, originalPath: url.path)
        asset.groupID = groupID
        asset.relativePath = try storage.copyFile(from: url, kind: .imported, fallbackExtension: kind == .image ? "png" : "mp4")
        await probe(asset, mediaURL: storage.absoluteURL(for: asset.relativePath!), kind: kind, storage: storage)
        context.insert(asset)
        return asset
    }

    /// Fills in dimensions, duration and the poster frame from the media itself.
    static func probe(_ asset: ImportedAsset, mediaURL: URL, kind: ImportedAssetKind, storage: ProjectStorage) async {
        switch kind {
        case .video:
            if let probed = await VideoThumbnailer.probe(url: mediaURL) {
                asset.width = probed.width; asset.height = probed.height; asset.durationSeconds = probed.duration
            }
            asset.thumbnailFilePath = await VideoThumbnailer.generate(for: mediaURL, storage: storage)
        case .audio:
            let seconds = CMTimeGetSeconds(AVURLAsset(url: mediaURL).duration)
            asset.durationSeconds = seconds.isFinite ? seconds : 0
        case .image:
            if let image = NSImage(contentsOf: mediaURL) {
                asset.width = Int(image.size.width); asset.height = Int(image.size.height)
            }
        }
    }
}
