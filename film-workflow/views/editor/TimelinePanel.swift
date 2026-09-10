import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Bottom panel: the current sequence's timeline.
struct TimelinePanel: View {
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?
    let onCreateSequence: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @State private var dropError: String?

    var body: some View {
        VStack(spacing: 0) {
            StudioPanelHeader(title: "Timeline", symbol: "timeline.selection")
            timelineContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var timelineContent: some View {
        if let sequence {
            SequenceTimelineView(
                timeline: Binding(get: { sequence.timeline }, set: { sequence.editTimeline($0, undoManager: undoManager) }),
                playhead: Binding(get: { state.playhead }, set: { state.playhead = $0 }),
                selectedClipIDs: $state.selectedClipIDs,
                pixelsPerSecond: Binding(get: { sequence.timelinePixelsPerSecond }, set: { sequence.timelinePixelsPerSecond = $0 }),
                resolver: DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps),
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
                }
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
        let clip = Clip(source: item.source, start: time, duration: duration, sourceDuration: item.source.kind == .image ? nil : duration, text: item.source.kind == .captions ? .caption : nil)
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
