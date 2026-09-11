import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI
import VideoEffectsUI

/// Bottom panel: the current sequence's timeline.
struct TimelinePanel: View {
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?
    let onCreateSequence: () -> Void
    let previewRevision: String
    @State private var remotionRevision = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @State private var dropError: String?
    @State private var browserVisible: Bool

    init(state: EditorWindowState, document: ProjectDocument, sequence: SequenceProject?, previewRevision: String = "", onCreateSequence: @escaping () -> Void) {
        self.state = state
        self.document = document
        self.sequence = sequence
        self.onCreateSequence = onCreateSequence
        self.previewRevision = previewRevision
        _browserVisible = State(initialValue: document.panelLayout.effectsBrowserVisible ?? true)
    }

    var body: some View {
        TimelineBrowserSplit(document: document, browserVisible: browserVisible) {
            timelineColumn
        } browser: {
            VStack(spacing: 0) {
                StudioPanelHeader(title: "Effects & Transitions", symbol: "slider.horizontal.below.rectangle")
                ModifierBrowser { state.modifierSelection = .catalog($0) }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { _ in remotionRevision += 1 }
    }

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StudioPanelHeader(title: "Timeline", symbol: "timeline.selection")
                Button {
                    browserVisible.toggle()
                    document.setEffectsBrowserVisible(browserVisible)
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).padding(.horizontal, 10)
                    .accessibilityLabel("Effects & Transitions")
                    .help(browserVisible ? "Hide effects and transitions" : "Show effects and transitions")
                    .accessibilityIdentifier("toggle-modifier-browser")
            }
            .background(.bar)
            timelineContent
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if let sequence {
            SequenceTimelineView(
                timeline: Binding(get: { sequence.timeline }, set: { sequence.editTimeline($0, undoManager: undoManager) }),
                playhead: Binding(get: { state.playhead }, set: { state.playhead = $0 }),
                selectedClipIDs: $state.selectedClipIDs,
                pixelsPerSecond: Binding(get: { sequence.timelinePixelsPerSecond }, set: { sequence.timelinePixelsPerSecond = $0 }),
                skimming: $state.skimsTimeline,
                onSkim: { time in
                    if let time { state.skim(to: time) } else { state.endSkim() }
                },
                resolver: DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps),
                previewRevision: previewRevision + ":\(remotionRevision)",
                onDrop: { item, trackID, time in
                    Task { await insert(item, on: trackID, at: time, into: sequence) }
                },
                onDeleteClips: { ids in
                    var timeline = sequence.timeline
                    TimelineEditor.remove(&timeline, clipIDs: ids)
                    sequence.editTimeline(timeline, undoManager: undoManager,
                                          actionName: ids.count > 1 ? String(localized: "Delete Clips") : String(localized: "Delete Clip"))
                },
                onDeselect: { state.select(nil) },
                alignment: { clip, timeline in
                    CaptionAudioAlignment.alignment(for: clip, in: timeline, context: modelContext)
                },
                selectedTransitionID: state.selectedTransitionID,
                onInspectEffects: { state.inspectEffects($0) },
                onInspectTransition: { state.inspectTransition($0) }
            )
            .alert("Couldn’t add footage", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
                Button("OK") { dropError = nil }
            } message: {
                Text(dropError ?? "")
            }
        } else {
            VStack(spacing: 0) {
                StudioEmptyState(title: "Build your first sequence", symbol: "film.stack",
                                 message: "Arrange footage, sound and captions on your timeline.")
                    .frame(maxHeight: 130)
                Button("New Sequence", action: onCreateSequence)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { state.select(nil) }

        }
    }

    /// The caption project's default style, so a dropped clip looks the way its Style tab says.
    private func captionStyle(for source: ClipSource) -> TextStyle {
        guard let (prefix, id) = DocumentMediaResolver.parse(source.id), prefix == .caption,
              let project = try? modelContext.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first
        else { return .caption }
        return project.captionStyle
    }

    /// Resolves the dropped footage to learn its natural length before placing it.
    private func insert(_ item: FootageDragItem, on trackID: UUID, at time: TimeInterval, into sequence: SequenceProject) async {
        var duration = item.duration ?? 0
        if duration <= 0, item.source.kind != .image {
            let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            if let media = try? await resolver.resolve(item.source) {
                switch media {
                case .file(_, let natural, _): duration = natural ?? 0
                case .captions(let cues): duration = cues.map(\.end).max() ?? 0
                }
            }
        }
        if duration <= 0 { duration = FootageDragItem.defaultStillDuration }

        var timeline = sequence.timeline
        let clip = Clip(source: item.source, start: time, duration: duration, sourceDuration: item.source.kind == .image ? nil : duration,
                        text: item.source.kind == .captions ? captionStyle(for: item.source) : nil)
        do {
            try TimelineEditor.insert(&timeline, clip: clip, on: trackID)
            sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Clip"))
            state.selectedClipID = clip.id
        } catch TimelineEditError.overlap {
            if let free = TimelineEditor.nextFreeStart(timeline, on: trackID, at: time, duration: duration) {
                var moved = clip
                moved.start = free
                if (try? TimelineEditor.insert(&timeline, clip: moved, on: trackID)) != nil {
                    sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Clip"))
                    state.selectedClipID = moved.id
                    return
                }
            }
            dropError = "There is no room on that track at the drop point."
        } catch {
            dropError = error.localizedDescription
        }
    }
}
