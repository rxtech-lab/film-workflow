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

    private func manifest(_ kind: MarketplaceKind, title: String, filename: String, metadata: MarketplaceItemMetadata = .init()) -> InstalledMarketplaceManifest {
        InstalledMarketplaceManifest(itemID: UUID().uuidString, kind: kind, title: title, category: "test", description: "", contentFilename: filename, contentRelativePath: "content", previewImagePath: nil, metadata: metadata, installedAt: Date())
    }

    /// A minimal but complete project tree, zipped the way publishing does.
    private func archive(prompt: String, width: Int = 1920, height: Int = 1080, fps: Int = 30, seconds: Double = 8) throws -> URL {
        let fm = FileManager.default
        let projectDir = fm.temporaryDirectory.appendingPathComponent("RemotionSource-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: projectDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir.appendingPathComponent("public"), withIntermediateDirectories: true)
        try Data("export const Composition = () => null;\n".utf8).write(to: projectDir.appendingPathComponent("src/Composition.tsx"))
        try Data("{\"name\":\"demo\"}\n".utf8).write(to: projectDir.appendingPathComponent("package.json"))
        try Data("cover".utf8).write(to: projectDir.appendingPathComponent("public/cover.txt"))
        defer { try? fm.removeItem(at: projectDir) }

        let destination = fm.temporaryDirectory.appendingPathComponent("composition-\(UUID().uuidString).zip")
        try RemotionProjectArchive.write(
            project: projectDir,
            descriptor: .init(name: "Cold open", prompt: prompt, compositionWidth: width, compositionHeight: height,
                              compositionFps: fps, durationSeconds: seconds),
            to: destination)
        return destination
    }

    @Test("A Remotion archive unpacks into a composition of this film's own")
    func remotionArchive() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let zip = try archive(prompt: "  Open on black, then a slow push in.\n", width: 1080, height: 1920, fps: 24, seconds: 6)
        defer { try? FileManager.default.removeItem(at: zip) }

        let added = try await MarketplaceInstaller.addToFilm(manifest(.remotion, title: "Cold open", filename: "cold-open.zip"), contentURL: zip, document: document)
        #expect(added.kind == .remotion)
        let projects = try document.container.mainContext.fetch(FetchDescriptor<RemotionProject>())
        #expect(projects.map(\.name) == ["Cold open"])
        let project = try #require(projects.first)
        // The descriptor carries what the files cannot.
        #expect(project.prompt == "Open on black, then a slow push in.")
        #expect(project.compositionWidth == 1080)
        #expect(project.compositionHeight == 1920)
        #expect(project.compositionFps == 24)
        #expect(project.durationSeconds == 6)
        // The source is on disk in this film, ready to render.
        #expect(FileManager.default.fileExists(atPath: project.projectDir.appendingPathComponent("src/Composition.tsx").path))
        #expect(FileManager.default.fileExists(atPath: project.projectDir.appendingPathComponent("public/cover.txt").path))
        #expect(project.compositionSource.contains("export const Composition"))
        await document.close()
    }

    @Test("An installed still is imported as an image, not as video")
    func imageFootage() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let still = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: still)
        defer { try? FileManager.default.removeItem(at: still) }

        let added = try await MarketplaceInstaller.addToFilm(
            manifest(.footage, title: "Harbor dawn", filename: "frame.png", metadata: .init(mediaType: "image")),
            contentURL: still, document: document)
        #expect(added.kind == .imported)
        let assets = try document.container.mainContext.fetch(FetchDescriptor<ImportedAsset>())
        #expect(assets.map(\.kindEnum) == [.image])
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
