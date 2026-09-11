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

    @Test("Sequence zoom is saved inside the document independently for each sequence")
    func sequenceZoomPersists() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }

        let created = try ProjectDocument.create(at: url)
        let wide = SequenceProject(name: "Wide")
        let standard = SequenceProject(name: "Standard")
        created.container.mainContext.insert(wide)
        created.container.mainContext.insert(standard)
        wide.timelinePixelsPerSecond = 0.5
        created.save()
        await created.close()

        let reopened = try ProjectDocument.open(url)
        let sequences = try reopened.container.mainContext.fetch(FetchDescriptor<SequenceProject>())
        #expect(sequences.first { $0.name == "Wide" }?.timelinePixelsPerSecond == 0.5)
        #expect(sequences.first { $0.name == "Standard" }?.timelinePixelsPerSecond == 40)
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

    @Test("Panel sizes persist per package and close flushes a pending resize")
    func panelSizesPersist() async throws {
        let url = temporaryPackage()
        let otherURL = temporaryPackage()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: otherURL)
        }
        let document = try ProjectDocument.create(at: url)
        let other = try ProjectDocument.create(at: otherURL)
        #expect(document.panelLayout.sizes(for: .editorColumns) == nil)
        document.setPanelSizes([275, 650, 350], for: .editorColumns)
        document.setPanelSizes([520, 280], for: .editorRows)
        document.setPanelSizes([310, 209], for: .libraryRows)
        await document.close()

        let reopened = try ProjectDocument.open(url)
        #expect(reopened.panelLayout.sizes(for: .editorColumns) == [275, 650, 350])
        #expect(reopened.panelLayout.sizes(for: .editorRows) == [520, 280])
        #expect(reopened.panelLayout.sizes(for: .libraryRows) == [310, 209])
        #expect(other.panelLayout.sizes(for: .editorColumns) == nil)
        await reopened.close()
        await other.close()
    }

    @Test("Footage pane visibility persists with the workspace")
    func footagePaneVisibilityPersists() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        #expect(document.panelLayout.footageBrowserVisible == nil)
        document.setPanelSizes([310, 209], for: .libraryRows)
        document.setFootageBrowserVisible(false)
        await document.close()

        let reopened = try ProjectDocument.open(url)
        #expect(reopened.panelLayout.footageBrowserVisible == false)
        #expect(reopened.panelLayout.sizes(for: .libraryRows) == [310, 209])
        reopened.setFootageBrowserVisible(true)
        await reopened.close()
        let again = try ProjectDocument.open(url)
        #expect(again.panelLayout.footageBrowserVisible == true)
        await again.close()
    }

    @Test("An unreadable workspace does not prevent opening the film")
    func invalidPanelLayoutFallsBack() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        await document.close()
        try Data("invalid json".utf8).write(to: url.appendingPathComponent("Workspace.json"))
        let reopened = try ProjectDocument.open(url)
        #expect(reopened.panelLayout.sizes(for: .editorColumns) == nil)
        reopened.setPanelSizes([0, .nan], for: .editorRows)
        #expect(reopened.panelLayout.sizes(for: .editorRows) == nil)
        await reopened.close()
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
