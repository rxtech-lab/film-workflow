import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore

@testable import film_workflow

/// The footage strip under the library has to list what the card's version
/// badge counts; a Remotion project used to collapse to a single cell however
/// many times it had been rendered.
@Suite("Library version strip")
@MainActor
struct LibraryVersionStripTests {
    private struct UpdatingLibrary: View {
        let document: ProjectDocument
        let state: EditorWindowState
        @Query private var projects: [RemotionProject]
        @Query private var renders: [RemotionRender]

        var body: some View {
            LibraryPanel(index: LibraryIndex(remotions: projects, remotionRenders: renders), groups: [],
                         state: state, document: document, onCreate: { _, _ in }, onMove: { _, _ in },
                         onImport: {}, onCreateGroup: {}, onRenameGroup: { _ in }, onDeleteGroup: { _ in },
                         onRename: { _ in }, onDelete: { _ in }, onExport: { _ in }, onShowVersions: { _, _ in },
                         marketplace: nil)
        }
    }

    @Test("An open footage panel replaces its live placeholder with every new render")
    func openPanelReceivesNewRenders() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdatingVersions-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = RemotionProject(name: "Hello World")
        let context = document.container.mainContext
        context.insert(project)
        try context.save()
        let state = EditorWindowState()
        state.select(.init(kind: .remotion, id: project.id))
        let host = NSHostingView(rootView: UpdatingLibrary(document: document, state: state).modelContainer(document.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(hostedAccessibilityDescendants(host).contains { $0.accessibilityIdentifier() == "footage.cell.\(project.id.uuidString)" })
        var renders: [RemotionRender] = []
        for version in 1...2 {
            let render = render(project.id, version: version)
            context.insert(render); renders.append(render)
            try context.save()
            try await Task.sleep(for: .milliseconds(300))
            let elements = hostedAccessibilityDescendants(host)
            for render in renders {
                #expect(elements.contains { $0.accessibilityIdentifier() == "footage.cell.\(render.id.uuidString)" },
                        "The lower panel must refresh when v\(version) is saved")
            }
            #expect(!elements.contains { $0.accessibilityIdentifier() == "footage.cell.\(project.id.uuidString)" },
                    "The live placeholder must disappear once render versions exist")
        }
        await document.close()
    }

    private func render(_ projectID: UUID, version: Int, width: Int = 1920, height: Int = 1080) -> RemotionRender {
        RemotionRender(projectID: projectID, versionNumber: version, sourceHash: "hash\(version)", width: width, height: height,
                       fps: 30, filePath: "Renders/Remotion/\(projectID)/v00\(version).mp4", durationSeconds: 5)
    }

    @Test("Every Remotion render is its own cell, newest first")
    func remotionRendersAreCells() throws {
        let project = RemotionProject(name: "Hello World")
        let index = LibraryIndex(remotions: [project], remotionRenders: [render(project.id, version: 1), render(project.id, version: 2)])
        let item = LibraryItemID(kind: .remotion, id: project.id)
        let cells = index.footage(for: item)
        #expect(cells.map(\.title) == ["v2", "v1"])
        #expect(cells.count == index.versions(for: item).count)
        // Each cell plays its own file; the drag payload stays the live project,
        // which is what the timeline renders for the sequence it lands in.
        #expect(Set(cells.compactMap(\.mediaURL)).count == 2)
        #expect(cells.allSatisfy { $0.drag.source.id == project.dragItem.source.id })
        #expect(cells.allSatisfy { $0.previewSource?.isTemporal == true })
        #expect(cells.allSatisfy { $0.previewSource?.canScrub == true })
        #expect(Set(cells.compactMap(\.previewSource)).count == 2,
                "Each render needs its own video frames, independent of the live project")
    }

    @Test("A render of another project is not listed")
    func rendersAreScopedToTheirProject() {
        let project = RemotionProject(name: "Hello World"), other = RemotionProject(name: "Elsewhere")
        let index = LibraryIndex(remotions: [project, other], remotionRenders: [render(project.id, version: 1), render(other.id, version: 1)])
        #expect(index.footage(for: LibraryItemID(kind: .remotion, id: project.id)).count == 1)
    }

    @Test("Before the first render the project itself stands in")
    func unrenderedProjectKeepsItsLiveCell() throws {
        let project = RemotionProject(name: "Hello World")
        let index = LibraryIndex(remotions: [project])
        let cell = try #require(index.footage(for: LibraryItemID(kind: .remotion, id: project.id)).first)
        #expect(cell.id == project.id)
        #expect(cell.subtitle.contains("renders on demand"))
        #expect(cell.mediaURL == nil)
    }
}
