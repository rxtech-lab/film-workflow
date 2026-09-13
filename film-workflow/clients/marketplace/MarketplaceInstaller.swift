import Foundation
import SwiftData

/// Puts an installed item into a film. Footage and audio become imported
/// assets; a Remotion prompt becomes a composition project carrying that
/// prompt. Fonts, effects and transitions are global and have nothing to add.
@MainActor
enum MarketplaceInstaller {
    static func addToFilm(_ manifest: InstalledMarketplaceManifest, contentURL: URL, document: ProjectDocument, groupID: UUID? = nil) async throws -> LibraryItemID {
        let context = document.container.mainContext
        switch manifest.kind {
        case .footage, .audio, .soundEffect:
            guard let kind = manifest.kind.importedAssetKind else { throw MarketplaceError.notAddable(manifest.kind) }
            let asset = try await MediaImporter.importCopy(url: contentURL, kind: kind, name: manifest.title, groupID: groupID, storage: document.storage, context: context)
            try context.save()
            return LibraryItemID(kind: .imported, id: asset.id)
        case .remotionPrompt:
            let prompt = (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
            let project = RemotionProject(name: manifest.title)
            project.groupID = groupID
            project.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            context.insert(project)
            try context.save()
            return LibraryItemID(kind: .remotion, id: project.id)
        case .font, .transition, .effect:
            throw MarketplaceError.notAddable(manifest.kind)
        }
    }
}
