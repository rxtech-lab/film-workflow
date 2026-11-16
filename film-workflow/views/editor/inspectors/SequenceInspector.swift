import AppKit
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Sequence settings and the Render button. Renders themselves live in the
/// library's versions sheet.
struct SequenceInspector: View {
    let sequence: SequenceProject
    let document: ProjectDocument
    let onRender: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SequenceSettingsView(timeline: Binding(get: { sequence.timeline }, set: {
                    sequence.editTimeline($0, undoManager: undoManager, actionName: String(localized: "Change Sequence Settings"))
                }))
                Section("Name") {
                    TextField("Name", text: Binding(get: { sequence.name }, set: { sequence.name = $0; sequence.updatedAt = Date() }))
                }
                Section("Remotion Clips") {
                    let count = SequenceRenderService.remotionProjects(in: sequence, context: modelContext).count
                    Text(count == 0 ? "None on the timeline" : "\(count) drawn live by MotionSwift. Double-click one on the timeline to edit its composition.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            Button {
                FilmFeatureTip.sequenceRender.didPerform()
                onRender()
            } label: {
                HStack { Image(systemName: "film.stack"); Text("Render") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sequence.timeline.isEmpty)
            .filmTip(.sequenceRender, when: !sequence.timeline.isEmpty)
            .padding(10)
        }
    }
}

struct ImportedInspector: View {
    let asset: ImportedAsset

    var body: some View {
        Form {
            Section("Imported File") {
                LabeledContent("Name", value: asset.name)
                LabeledContent("Kind", value: asset.kindEnum.rawValue.capitalized)
                LabeledContent("Storage", value: asset.isReferenced ? "Referenced in place" : "Copied into film")
                if asset.durationSeconds > 0 { LabeledContent("Duration", value: "\(Int(asset.durationSeconds.rounded())) s") }
                if asset.width > 0 { LabeledContent("Size", value: "\(asset.width) × \(asset.height)") }
                LabeledContent("Original") {
                    Text(asset.originalPath).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if let url = asset.resolveURL() {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    Label("The file could not be found.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
