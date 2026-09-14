import Foundation
import SwiftData

/// Puts an installed item into a film. Footage and audio become imported
/// assets; a Remotion archive is unpacked into a composition project of this
/// film's own. Fonts, effects and transitions are global and have nothing to add.
@MainActor
enum MarketplaceInstaller {
    static func addToFilm(_ manifest: InstalledMarketplaceManifest, contentURL: URL, document: ProjectDocument, groupID: UUID? = nil) async throws -> LibraryItemID {
        let context = document.container.mainContext
        switch manifest.kind {
        case .footage, .audio, .soundEffect:
            // The manifest decides, not the kind: footage is a still or a clip.
            guard let kind = manifest.importedAssetKind else { throw MarketplaceError.notAddable(manifest.kind) }
            let asset = try await MediaImporter.importCopy(url: contentURL, kind: kind, name: manifest.title, groupID: groupID, storage: document.storage, context: context)
            asset.marketplaceItemId = manifest.itemID
            try context.save()
            return LibraryItemID(kind: .imported, id: asset.id)
        case .remotion:
            // Saved before unpacking: `projectDir` is derived from the model's
            // own storage, so the row has to exist before the files can land.
            let project = RemotionProject(name: manifest.title)
            project.marketplaceItemId = manifest.itemID
            project.groupID = groupID
            context.insert(project)
            try context.save()
            let descriptor = try RemotionProjectArchive.read(archive: contentURL, into: project.projectDir)
            project.prompt = descriptor.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            project.compositionWidth = descriptor.compositionWidth
            project.compositionHeight = descriptor.compositionHeight
            project.compositionFps = descriptor.compositionFps
            project.durationSeconds = descriptor.durationSeconds
            // The unpacked file is authoritative; the render service only
            // writes Composition.tsx back out when it is missing.
            project.compositionSource = (try? String(contentsOf: project.projectDir.appendingPathComponent("src/Composition.tsx"), encoding: .utf8)) ?? ""
            project.updatedAt = Date()
            try context.save()
            return LibraryItemID(kind: .remotion, id: project.id)
        case .font, .transition, .effect, .projectTemplate:
            throw MarketplaceError.notAddable(manifest.kind)
        }
    }
}
