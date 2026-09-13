import Foundation
import Testing
import VideoEditorCore

@testable import film_workflow

/// The footage strip under the library has to list what the card's version
/// badge counts; a Remotion project used to collapse to a single cell however
/// many times it had been rendered.
@Suite("Library version strip")
@MainActor
struct LibraryVersionStripTests {
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
