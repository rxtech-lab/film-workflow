import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("Project storage")
@MainActor
struct ProjectStorageTests {
    private func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStorageTests-\(UUID().uuidString)")
            .appendingPathExtension("rxfilmstudio")
    }

    @Test("Media helpers write inside the package and return package-relative paths")
    func mediaHelpersRoundTrip() throws {
        let storage = ProjectStorage(packageURL: temporaryPackage())
        defer { try? FileManager.default.removeItem(at: storage.packageURL) }
        try storage.ensureDirectories()

        let audio = try storage.saveAudio(Data([1, 2, 3]), extension: "mp3", kind: .narration)
        #expect(audio.hasPrefix("Media/Narration/"))
        #expect(audio.hasSuffix(".mp3"))
        let url = storage.absoluteURL(for: audio)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(storage.relativePath(for: url) == audio)

        let image = try storage.saveImage(Data([9]), fileExtension: ".PNG")
        #expect(image.hasPrefix("Media/Images/") && image.hasSuffix(".png"))

        let copy = try #require(storage.copyStoredFile(atRelative: image))
        #expect(copy.hasPrefix("Media/Images/") && copy != image)

        storage.deleteFile(at: audio)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An in-memory container resolves to an ephemeral storage, a store URL to its package")
    func containerResolution() throws {
        let schema = Schema([ProjectGroup.self])
        let memory = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let ephemeral = ProjectStorage.forContainer(memory)
        #expect(ephemeral.packageURL.path.hasPrefix(FileStorage.tempDir.path))
        #expect(ProjectStorage.forContainer(memory) === ephemeral)

        let package = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let storeURL = package.appendingPathComponent(ProjectStorage.storeFilename)
        let onDisk = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let resolved = ProjectStorage.forContainer(onDisk)
        #expect(resolved.packageURL.standardizedFileURL == package.standardizedFileURL)

        let group = ProjectGroup(name: "g")
        onDisk.mainContext.insert(group)
        #expect(ProjectStorage.for(model: group) === resolved)
        ProjectStorage.unregister(container: onDisk)
    }
}
