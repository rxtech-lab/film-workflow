import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// What a footage model needs from the window to build its inspector tabs.
struct InspectorContext {
    let document: ProjectDocument
    let state: EditorWindowState
    let index: LibraryIndex
    let sequence: SequenceProject?
    let onRender: () -> Void

    /// Timeline sources identify a recording; library selections identify its
    /// project and keep the chosen recording in the window's version selection.
    var sourceID: String? {
        if let clipID = state.selectedClipID, let clip = sequence?.timeline.clip(id: clipID) {
            return clip.source.id
        }
        guard state.selectedClipIDs.isEmpty, let item = state.selection,
              item.kind == .music || item.kind == .imported else { return nil }
        let cells = index.footage(for: item)
        let selected = state.currentVersion(for: item)
        return (cells.first { $0.id == selected } ?? cells.first)?.drag.source.id
    }

    var footage: (any FootageProtocol)? {
        if let clipID = state.selectedClipID, let clip = sequence?.timeline.clip(id: clipID),
           let (prefix, id) = DocumentMediaResolver.parse(clip.source.id),
           let kind = FootageKind(rawValue: prefix.rawValue) {
            if prefix == .screenRecording {
                return try? RecordingTimelineService.resolve(id: id, context: document.container.mainContext).0.project
            }
            if prefix == .music {
                return index.music.first { $0.generatedFiles.contains { $0.id == id } }
            }
            return index.model(for: LibraryItemID(kind: kind, id: id))
        }
        return state.selection.flatMap { index.model(for: $0) }
    }

    var lyricsProject: CaptionProject? {
        guard let sourceID else { return nil }
        return index.captions.first { $0.lyricsSourceID == sourceID && $0.activeSegmentCount > 0 }
    }
}

/// Every item the library lists. Class-bound because conformers are SwiftData
/// models, which the inspector observes directly.
@MainActor
protocol FootageProtocol: AnyObject {
    var libraryItemID: LibraryItemID { get }
    var footageName: String { get }
}

extension FootageProtocol {
    var footageKind: FootageKind { libraryItemID.kind }
}

/// The primary tab — "Settings", or "Sequence" for a sequence — and an
/// optional footer shown under every one of the item's tabs: the Generate,
/// Transcribe or Render button with its sheets and alerts.
@MainActor
protocol InspectorProtocol: FootageProtocol {
    var settingsTabID: String { get }
    var settingsTabTitle: LocalizedStringKey { get }
    var settingsTabSystemImage: String { get }
    func makeSettingsTab(_ context: InspectorContext) -> AnyView
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView?
}

extension InspectorProtocol {
    var settingsTabID: String { InspectorTabResolver.settingsTabID }
    var settingsTabTitle: LocalizedStringKey { "Settings" }
    var settingsTabSystemImage: String { "slider.horizontal.3" }
    func makeInspectorFooter(_ context: InspectorContext) -> AnyView? { nil }
}

/// A second, editor-style tab: Captions, Composition, Transcript.
@MainActor
protocol EditorTabProviding: FootageProtocol {
    var editorTabID: String { get }
    var editorTabTitle: LocalizedStringKey { get }
    var editorTabSystemImage: String { get }
    func makeEditorTab(_ context: InspectorContext) -> AnyView
}

/// A Style tab editing the persisted default `TextStyle` new clips start with.
@MainActor
protocol CaptionStyleProviding: FootageProtocol {
    var captionStyle: TextStyle { get set }
    func makeStyleTab(_ context: InspectorContext) -> AnyView
}

/// A Translation tab: every language the footage has been translated into,
/// and the runs that fill them in.
@MainActor
protocol TranslationTabProviding: FootageProtocol {
    func makeTranslationTab(_ context: InspectorContext) -> AnyView
}

/// One segment of the inspector's tab row and what it shows.
struct InspectorTabDescriptor: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    /// Whether the footage's footer belongs under this tab. False for the
    /// Clip tab and for the Sequence tab shown alongside a clip's source.
    let showsFooter: Bool
    let content: () -> AnyView
}

/// Turns what a model conforms to into the tabs the inspector offers, the
/// same way `TimelineEditingCapabilities` folds editing protocols into a set.
@MainActor
enum InspectorTabResolver {
    static let settingsTabID = "settings"
    static let sequenceTabID = "sequence"
    static let clipTabID = "clip"
    static let translationTabID = "translation"
    static let lyricsTabID = "lyrics"

    /// Footage tabs in protocol order (settings, editor, style, translation),
    /// then Clip
    /// when clips are selected, then Sequence when the sequence is the
    /// library selection but a clip's source is what the footage tabs show.
    static func tabs(footage: (any FootageProtocol)?, hasClip: Bool, sequenceSelected: Bool, context: InspectorContext) -> [InspectorTabDescriptor] {
        var tabs: [InspectorTabDescriptor] = []
        if let footage {
            if let inspectable = footage as? any InspectorProtocol {
                tabs.append(InspectorTabDescriptor(id: inspectable.settingsTabID, title: inspectable.settingsTabTitle,
                                                   systemImage: inspectable.settingsTabSystemImage, showsFooter: true) {
                    inspectable.makeSettingsTab(context)
                })
            }
            if let editable = footage as? any EditorTabProviding {
                tabs.append(InspectorTabDescriptor(id: editable.editorTabID, title: editable.editorTabTitle,
                                                   systemImage: editable.editorTabSystemImage, showsFooter: true) {
                    editable.makeEditorTab(context)
                })
            }
            if let lyrics = context.lyricsProject {
                tabs.append(InspectorTabDescriptor(id: lyricsTabID, title: "Lyrics", systemImage: "music.note.list", showsFooter: false) {
                    AnyView(MusicLyricsInspector(project: lyrics)
                        .id(lyrics.projectUUID)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("music-lyrics-inspector"))
                })
            }
            if let styled = footage as? any CaptionStyleProviding {
                tabs.append(InspectorTabDescriptor(id: "style", title: "Style", systemImage: "textformat", showsFooter: true) {
                    styled.makeStyleTab(context)
                })
            }
            if let translatable = footage as? any TranslationTabProviding {
                tabs.append(InspectorTabDescriptor(id: translationTabID, title: "Translation", systemImage: "globe", showsFooter: true) {
                    translatable.makeTranslationTab(context)
                })
            }
        }
        if hasClip, let sequence = context.sequence {
            tabs.append(InspectorTabDescriptor(id: clipTabID, title: "Clip", systemImage: "rectangle.dashed", showsFooter: false) {
                AnyView(ClipInspectorTab(sequence: sequence, context: context))
            })
        }
        if sequenceSelected, footage?.footageKind != .sequence, let sequence = context.sequence {
            tabs.append(InspectorTabDescriptor(id: sequenceTabID, title: "Sequence", systemImage: "film.stack", showsFooter: false) {
                AnyView(SequenceInspector(sequence: sequence, document: context.document, onRender: context.onRender))
            })
        }
        return tabs
    }

    /// The remembered tab when the row offers it, else the first. Never
    /// changes the preference itself: a tab that is missing for this
    /// selection comes back as soon as a later selection offers it.
    static func effectiveTabID(remembered: String, tabs: [InspectorTabDescriptor]) -> String? {
        tabs.contains { $0.id == remembered } ? remembered : tabs.first?.id
    }
}

/// The Clip tab: one selected clip's timing, picture, audio and text, or a
/// note when several are selected.
struct ClipInspectorTab: View {
    let sequence: SequenceProject
    let context: InspectorContext
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let state = context.state
        if let clipID = state.selectedClipID {
            let timeline = Binding(get: { sequence.timeline }, set: {
                sequence.editTimeline($0, undoManager: undoManager, actionName: String(localized: "Edit Clip"))
            })
            let remotion = remotionProject(for: clipID)
            let status: String? = remotion.flatMap { project in
                RemotionRenderService.cachedRender(project: project, width: sequence.width, height: sequence.height, fps: project.compositionFps,
                                                   context: context.document.container.mainContext, preserveAlpha: true) == nil
                    ? "Live preview available · renders when exporting" : nil
            }
            ClipInspectorView(timeline: timeline, clipID: clipID, renderStatus: status,
                              captionLanguages: captionLanguages(for: clipID),
                              onRender: remotion == nil ? nil : context.onRender)
        } else if state.selectedClipIDs.count > 1 {
            StudioEmptyState(title: "\(state.selectedClipIDs.count) Clips Selected", symbol: "rectangle.stack",
                             message: "Drag them to move together, or press Delete to remove them all.")
        } else {
            StudioEmptyState(title: "No Clip Selected", symbol: "rectangle.dashed",
                             message: "Select a clip on the timeline.")
        }
    }

    /// What a caption clip can be drawn in: the transcript, then every
    /// language its project has been translated into. Empty for anything else,
    /// which leaves the inspector's language rows out.
    private func captionLanguages(for clipID: UUID) -> [CaptionLanguageChoice] {
        guard let clip = sequence.timeline.clip(id: clipID), clip.source.kind == .captions,
              let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .caption,
              let project = try? context.document.container.mainContext
                  .fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first else {
            return []
        }
        return [CaptionLanguageChoice(code: "", name: String(localized: "Original"))]
            + project.translatedLanguages.sorted().map {
                CaptionLanguageChoice(code: $0, name: CaptionTranslationAvailability.displayName($0))
            }
    }

    private func remotionProject(for clipID: UUID) -> RemotionProject? {
        guard let clip = sequence.timeline.clip(id: clipID), clip.source.kind == .remotion,
              let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .remotion else { return nil }
        return context.index.remotion(id)
    }
}
