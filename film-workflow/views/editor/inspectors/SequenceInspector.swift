import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore
import VideoEditorUI

struct SequenceInspector: View {
    let sequence: SequenceProject
    let document: ProjectDocument
    let onRender: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var renders: [SequenceRender] = []
    @State private var refreshToken = 0
    @State private var pendingDeletion: SequenceRender?
    @State private var isRenderingRemotion = false
    @State private var remotionProgress: SequenceRenderProgress?
    @State private var remotionTask: Task<Void, Never>?
    @State private var remotionError: String?

    private var stale: [RemotionProject] {
        SequenceRenderService.unrenderedRemotionProjects(in: sequence, context: modelContext)
    }

    var body: some View {
        InspectorLayout(versionsTitle: "Renders", versionCount: renders.count) {
            VStack(spacing: 0) {
                Form {
                    SequenceSettingsView(timeline: Binding(get: { sequence.timeline }, set: { sequence.timeline = $0 }))
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
        } versions: {
            rendersList
        }
        .task(id: refreshToken) { renders = SequenceRenderService.renders(for: sequence, context: modelContext) }
        .onChange(of: sequence.updatedAt) { _, _ in refreshToken += 1 }
        .confirmationDialog("Delete this render?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { render in
            Button("Delete \(render.versionLabel)", role: .destructive) {
                SequenceRenderService.delete(render, context: modelContext)
                pendingDeletion = nil
                refreshToken += 1
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in Text("The rendered video file will be permanently deleted.") }
    }

    @ViewBuilder
    private var rendersList: some View {
        if renders.isEmpty {
            ContentUnavailableView {
                Label("No Renders", systemImage: "film.stack")
            } description: {
                Text("Render the sequence to create version 1.")
            }
        } else {
            List(renders) { render in
                HStack(spacing: 10) {
                    if let url = render.thumbnailURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 56, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(render.versionLabel).font(.callout.weight(.semibold))
                        Text(render.dimensionsLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(render.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                    Menu {
                        Button("Play") { NSWorkspace.shared.open(render.videoURL) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([render.videoURL]) }
                        Button("Export…") { exportRender(render) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeletion = render }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
            .listStyle(.inset)
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

    private func exportRender(_ render: SequenceRender) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sequence.name)-\(render.versionLabel).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SequenceRenderService.export(render, to: url) } catch { NSAlert(error: error).runModal() }
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
