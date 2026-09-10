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
    @State private var dropError: String?

    var body: some View {
        if let sequence {
            SequenceTimelineView(
                timeline: Binding(get: { sequence.timeline }, set: { sequence.timeline = $0 }),
                playhead: Binding(get: { state.playhead }, set: { state.playhead = $0; state.player.pause() }),
                selectedClipID: $state.selectedClipID,
                resolver: DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps),
                onDrop: { item, trackID, time in
                    Task { await insert(item, on: trackID, at: time, into: sequence) }
                }
            )
            .alert("Couldn’t add footage", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
                Button("OK") { dropError = nil }
            } message: {
                Text(dropError ?? "")
            }
        } else {
            ContentUnavailableView {
                Label("No Sequence", systemImage: "film.stack")
            } description: {
                Text("Create a sequence, then drag footage from the library onto its timeline.")
            } actions: {
                Button("New Sequence", action: onCreateSequence)
            }
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
        let clip = Clip(source: item.source, start: time, duration: duration, text: item.source.kind == .captions ? .caption : nil)
        do {
            try TimelineEditor.insert(&timeline, clip: clip, on: trackID)
            sequence.timeline = timeline
            state.selectedClipID = clip.id
        } catch TimelineEditError.overlap {
            if let free = TimelineEditor.nextFreeStart(timeline, on: trackID, at: time, duration: duration) {
                var moved = clip
                moved.start = free
                if (try? TimelineEditor.insert(&timeline, clip: moved, on: trackID)) != nil {
                    sequence.timeline = timeline
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
