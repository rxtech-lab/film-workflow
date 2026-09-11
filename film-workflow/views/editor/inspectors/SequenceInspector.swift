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
    @State private var isRenderingRemotion = false
    @State private var remotionProgress: SequenceRenderProgress?
    @State private var remotionTask: Task<Void, Never>?
    @State private var remotionError: String?

    private var stale: [RemotionProject] {
        SequenceRenderService.unrenderedRemotionProjects(in: sequence, context: modelContext)
    }

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
                    if count == 0 {
                        Text("None on the timeline").foregroundStyle(.secondary)
                    } else {
                        let staleCount = stale.count
                        HStack {
                            Text(staleCount == 0 ? "All \(count) rendered for this size" : "\(staleCount) of \(count) need rendering")
                                .foregroundStyle(staleCount == 0 ? Color.secondary : Color.orange)
                            Spacer()
                            Button(isRenderingRemotion ? "Rendering…" : "Render Remotion Clips") { renderRemotion() }
                                .disabled(staleCount == 0 || isRenderingRemotion)
                                .controlSize(.small)
                        }
                        if let remotionProgress, isRenderingRemotion {
                            ProgressView(value: remotionProgress.fraction ?? 0) { Text(remotionProgress.label).font(.caption) }
                        }
                        if let remotionError {
                            Text(remotionError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            Button(action: onRender) {
                HStack { Image(systemName: "film.stack"); Text("Render") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sequence.timeline.isEmpty)
            .padding(10)
        }
    }

    private func renderRemotion() {
        isRenderingRemotion = true
        remotionError = nil
        remotionTask = Task { @MainActor in
            defer { isRenderingRemotion = false; remotionProgress = nil }
            do {
                try await SequenceRenderService.renderRemotionClips(in: sequence, context: modelContext) { remotionProgress = $0 }
                sequence.updatedAt = Date()   // nudges the preview to reload with the new render
            } catch is CancellationError {
            } catch {
                remotionError = error.localizedDescription
            }
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
