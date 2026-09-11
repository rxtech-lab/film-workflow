import SwiftData
import SwiftUI
import VideoEditorCore

// Which tabs the inspector shows for each footage model, following
// `TimelineDraggable+Models.swift`: a model gains a tab by conforming to the
// protocol that describes it, and the panel never switches on kind.

extension MusicProject: InspectorProtocol, EditorTabProviding {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .music, id: id) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(MusicProjectParametersView(project: self)) }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(MusicInspectorFooter(project: self)) }
    var editorTabID: String { "composition" }
    var editorTabTitle: LocalizedStringKey { "Composition" }
    var editorTabSystemImage: String { "music.note.list" }
    func makeEditorTab(_ context: InspectorContext) -> AnyView { AnyView(MusicProjectEditorView(project: self)) }
}

extension NarrativeProject: InspectorProtocol, EditorTabProviding {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .narration, id: id) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(NarrativeProjectParametersView(project: self)) }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(NarrationInspectorFooter(project: self)) }
    var editorTabID: String { "transcript" }
    var editorTabTitle: LocalizedStringKey { "Transcript" }
    var editorTabSystemImage: String { "text.quote" }
    func makeEditorTab(_ context: InspectorContext) -> AnyView { AnyView(TranscriptEditorView(project: self)) }
}

extension CaptionProject: InspectorProtocol, EditorTabProviding, CaptionStyleProviding {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .caption, id: projectUUID) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView {
        AnyView(CaptionProjectParametersView(project: self, isTranscribing: context.state.busyItems.contains(libraryItemID)))
    }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(CaptionInspectorFooter(project: self, state: context.state)) }
    var editorTabID: String { "captions" }
    var editorTabTitle: LocalizedStringKey { "Captions" }
    var editorTabSystemImage: String { "captions.bubble" }
    func makeEditorTab(_ context: InspectorContext) -> AnyView { AnyView(CaptionProjectViewer(project: self).id(projectUUID)) }
    func makeStyleTab(_ context: InspectorContext) -> AnyView { AnyView(CaptionStyleTab(project: self, context: context)) }
}

extension ImageGenProject: InspectorProtocol {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .image, id: id) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(ImageGenProjectParametersView(project: self)) }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(ImageInspectorFooter(project: self)) }
}

extension VideoGenProject: InspectorProtocol {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .video, id: id) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(VideoGenProjectParametersView(project: self)) }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(VideoInspectorFooter(project: self)) }
}

extension RemotionProject: InspectorProtocol {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .remotion, id: id) }
    var footageName: String { name }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(RemotionSettingsTab(project: self)) }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { AnyView(RemotionInspectorFooter(project: self)) }
}

extension ImportedAsset: InspectorProtocol {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .imported, id: id) }
    var footageName: String { name }
    var settingsTabTitle: LocalizedStringKey { "File" }
    var settingsTabSystemImage: String { "doc" }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView { AnyView(ImportedInspector(asset: self)) }
}

extension SequenceProject: InspectorProtocol {
    var libraryItemID: LibraryItemID { LibraryItemID(kind: .sequence, id: id) }
    var footageName: String { name }
    var settingsTabID: String { InspectorTabResolver.sequenceTabID }
    var settingsTabTitle: LocalizedStringKey { "Sequence" }
    var settingsTabSystemImage: String { "film.stack" }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView {
        AnyView(SequenceInspector(sequence: self, document: context.document, onRender: context.onRender))
    }
}
