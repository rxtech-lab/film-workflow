import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("Project documents")
@MainActor
struct ProjectDocumentTests {
    private func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDocumentTests-\(UUID().uuidString)")
            .appendingPathExtension("rxfilmstudio")
    }

    @Test("Create writes the package layout, open reads it back")
    func createAndOpen() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }

        let created = try ProjectDocument.create(at: url)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.appendingPathComponent("Document.json").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent("Media/Music").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent("Renders/Sequences").path))

        let project = MusicProject(name: "Theme")
        created.container.mainContext.insert(project)
        created.save()
        #expect(fm.fileExists(atPath: created.storage.storeURL.path))
        await created.close()

        let reopened = try ProjectDocument.open(url)
        #expect(reopened.id == created.id)
        #expect(reopened.displayName == url.deletingPathExtension().lastPathComponent)
        let names = try reopened.container.mainContext.fetch(FetchDescriptor<MusicProject>()).map(\.name)
        #expect(names == ["Theme"])
        #expect(ProjectStorage.forContainer(reopened.container) === reopened.storage)
        await reopened.close()
    }

    @Test("Opening a plain folder or a missing path fails cleanly")
    func openRejectsNonPackages() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAFilm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: ProjectDocumentError.self) { try ProjectDocument.open(folder) }
        #expect(throws: ProjectDocumentError.self) {
            try ProjectDocument.open(folder.appendingPathComponent("missing.rxfilmstudio"))
        }
        #expect(throws: ProjectDocumentError.self) { try ProjectDocument.create(at: folder) }
    }

    @Test("Package names are sanitised and always carry the extension")
    func sanitisedNames() {
        let base = URL(fileURLWithPath: "/tmp")
        let plain = ProjectDocumentController.sanitized(base.appendingPathComponent("My Film"))
        #expect(plain.lastPathComponent == "My Film.rxfilmstudio")
        let odd = ProjectDocumentController.sanitized(base.appendingPathComponent("a#b%c?.rxfilmstudio"))
        #expect(odd.lastPathComponent == "a-b-c-.rxfilmstudio")
        let empty = ProjectDocumentController.sanitized(base.appendingPathComponent("   "))
        #expect(empty.lastPathComponent == "Untitled Film.rxfilmstudio")
    }
}
