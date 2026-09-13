import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("Marketplace installer", .serialized)
@MainActor
struct MarketplaceInstallerTests {
    private func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MarketplaceInstallerTests-\(UUID().uuidString)")
            .appendingPathExtension("rxfilmstudio")
    }

    private func manifest(_ kind: MarketplaceKind, title: String, filename: String) -> InstalledMarketplaceManifest {
        InstalledMarketplaceManifest(itemID: UUID().uuidString, kind: kind, title: title, category: "test", description: "", contentFilename: filename, contentRelativePath: "content", previewImagePath: nil, metadata: .init(), installedAt: Date())
    }

    @Test("A Remotion prompt becomes a composition carrying the prompt")
    func remotionPrompt() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let prompt = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-\(UUID().uuidString).md")
        try Data("  Open on black, then a slow push in.\n".utf8).write(to: prompt)
        defer { try? FileManager.default.removeItem(at: prompt) }

        let added = try await MarketplaceInstaller.addToFilm(manifest(.remotionPrompt, title: "Cold open", filename: "cold-open.md"), contentURL: prompt, document: document)
        #expect(added.kind == .remotion)
        let projects = try document.container.mainContext.fetch(FetchDescriptor<RemotionProject>())
        #expect(projects.map(\.name) == ["Cold open"])
        #expect(projects.first?.prompt == "Open on black, then a slow push in.")
        await document.close()
    }

    @Test("Audio is copied into the package as an imported asset")
    func audio() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("door-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let added = try await MarketplaceInstaller.addToFilm(manifest(.soundEffect, title: "Door", filename: "door.wav"), contentURL: audio, document: document, groupID: nil)
        #expect(added.kind == .imported)
        let assets = try document.container.mainContext.fetch(FetchDescriptor<ImportedAsset>())
        let asset = try #require(assets.first)
        #expect(asset.name == "Door")
        #expect(asset.kindEnum == .audio)
        let stored = try #require(asset.relativePath)
        #expect(stored.hasPrefix("Media/Imported/"))
        #expect(FileManager.default.fileExists(atPath: document.storage.absoluteURL(for: stored).path))
        await document.close()
    }

    @Test("Global kinds are refused")
    func globalKinds() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("font-\(UUID().uuidString).ttf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: MarketplaceError.notAddable(.font)) {
            try await MarketplaceInstaller.addToFilm(manifest(.font, title: "Rx Serif", filename: "RxSerif.ttf"), contentURL: file, document: document)
        }
        await document.close()
    }
}
