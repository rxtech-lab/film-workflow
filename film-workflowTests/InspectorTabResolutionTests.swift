import Foundation
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Inspector tabs", .serialized)
@MainActor
struct InspectorTabResolutionTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "InspectorTabResolutionTests-\(UUID().uuidString)")!
    }

    @Test("Selecting footage or clips never changes the remembered tab")
    func selectionKeepsTab() {
        let state = EditorWindowState(defaults: defaults())
        #expect(state.inspectorTabID == InspectorTabResolver.settingsTabID)
        state.inspectorTabID = "captions"
        state.select(LibraryItemID(kind: .sequence, id: UUID()))
        #expect(state.inspectorTabID == "captions")
        state.selectedClipID = UUID()
        #expect(state.inspectorTabID == "captions")
        state.select(LibraryItemID(kind: .music, id: UUID()))
        #expect(state.inspectorTabID == "captions")
        #expect(state.selectedClipIDs.isEmpty)
    }

    @Test("The remembered tab survives a relaunch")
    func persisted() {
        let store = defaults()
        let state = EditorWindowState(defaults: store)
        state.inspectorTabID = "style"
        #expect(EditorWindowState(defaults: store).inspectorTabID == "style")
    }

    @Test("A tab the selection does not offer falls back to the first without forgetting the preference")
    func fallback() {
        let tabs = ["settings", "captions"].map {
            InspectorTabDescriptor(id: $0, title: "", systemImage: "", showsFooter: true) { AnyView(EmptyView()) }
        }
        #expect(InspectorTabResolver.effectiveTabID(remembered: "clip", tabs: tabs) == "settings")
        #expect(InspectorTabResolver.effectiveTabID(remembered: "captions", tabs: tabs) == "captions")
        #expect(InspectorTabResolver.effectiveTabID(remembered: "clip", tabs: []) == nil)
    }

    @Test("Tabs come from the protocols a model conforms to")
    func tabsFromConformances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorTabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Test.rxfilmstudio"))
        let context = document.container.mainContext
        let caption = CaptionProject(name: "Talk")
        let music = MusicProject(name: "Theme")
        let sequence = SequenceProject(name: "Cut")
        context.insert(caption)
        context.insert(music)
        context.insert(sequence)
        let index = LibraryIndex(music: [music], captions: [caption], sequences: [sequence])
        let inspector = InspectorContext(document: document, state: EditorWindowState(defaults: defaults()), index: index, sequence: sequence, onRender: {})
        func ids(_ footage: (any FootageProtocol)?, clip: Bool = false, sequenceSelected: Bool = false) -> [String] {
            InspectorTabResolver.tabs(footage: footage, hasClip: clip, sequenceSelected: sequenceSelected, context: inspector).map(\.id)
        }
        #expect(ids(caption) == ["settings", "captions", "style"])
        #expect(ids(caption, clip: true, sequenceSelected: true) == ["settings", "captions", "style", "clip", "sequence"])
        #expect(ids(music) == ["settings", "composition"])
        #expect(ids(sequence, sequenceSelected: true) == ["sequence"])
        #expect(ids(nil, clip: true) == ["clip"])
        #expect(index.model(for: caption.libraryItemID) === caption)
        #expect(index.model(for: LibraryItemID(kind: .music, id: music.id)) === music)
        await document.close()
    }

    @Test("A caption project's style round-trips through its stored JSON")
    func captionStyle() {
        let project = CaptionProject(name: "Talk")
        #expect(project.captionStyle == .caption)
        var style = TextStyle.caption
        style.fontSize = 0.08
        style.alignment = .leading
        project.captionStyle = style
        #expect(project.captionStyle == style)
        #expect(!project.captionStyleData.isEmpty)
    }
}
