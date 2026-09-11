import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The style new clips of these captions start with, and a way to push it
/// onto the clips already on the timeline. The Clip tab still overrides one
/// clip at a time.
struct CaptionStyleTab: View {
    @Bindable var project: CaptionProject
    let context: InspectorContext
    @Environment(\.undoManager) private var undoManager

    private var clipIDs: [UUID] {
        guard let sequence = context.sequence else { return [] }
        let sourceID = project.clipSource.id
        return sequence.timeline.allClips.filter { $0.source.id == sourceID }.map(\.id)
    }

    var body: some View {
        Form {
            Section("Default Style") {
                TextStyleEditor(style: $project.captionStyle)
            }
            Section {
                let count = clipIDs.count
                Button(count == 1 ? "Apply to the Clip on the Timeline" : "Apply to \(count) Clips on the Timeline") { apply() }
                    .disabled(count == 0)
            } footer: {
                Text("Clips dropped from these captions start with this style. Applying it replaces the style of every clip of these captions in the current sequence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func apply() {
        guard let sequence = context.sequence else { return }
        var timeline = sequence.timeline
        let style = project.captionStyle
        for id in clipIDs {
            try? TimelineEditor.update(&timeline, clipID: id) { $0.text = style }
        }
        sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Apply Caption Style"))
    }
}
