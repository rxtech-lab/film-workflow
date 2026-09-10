import AppKit
import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Versions of a sequence's renders: play, reveal, export, delete.
struct SequenceRenderListView: View {
    @Environment(\.modelContext) private var modelContext
    let sequence: SequenceProject
    /// Selected when the list first appears, e.g. from the library's Versions menu.
    var initialSelectionID: UUID? = nil

    @State private var renders: [SequenceRender] = []
    @State private var selected: SequenceRender?
    @State private var player = AVPlayer()
    @State private var pendingDeletion: SequenceRender?

    var body: some View {
        Group {
            if renders.isEmpty {
                ContentUnavailableView(
                    "No Renders",
                    systemImage: "film.stack",
                    description: Text("Render the sequence to create version 1.")
                )
            } else {
                HSplitView {
                    List(renders, selection: $selected) { render in
                        row(render)
                            .tag(render)
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    VStack(spacing: 0) {
                        VideoPlayer(player: player)
                            .frame(minHeight: 240)
                        if let selected {
                            detailBar(selected)
                        }
                    }
                    .frame(minWidth: 360)
                }
            }
        }
        .task { reload() }
        .onChange(of: sequence.updatedAt) { _, _ in reload() }
        .onChange(of: selected?.id) { _, _ in
            if let selected {
                player.replaceCurrentItem(with: AVPlayerItem(url: selected.videoURL))
            } else {
                player.replaceCurrentItem(with: nil)
            }
        }
        .onDisappear { player.pause() }
        .confirmationDialog(
            "Delete this render?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { render in
            Button("Delete \(render.versionLabel)", role: .destructive) {
                SequenceRenderService.delete(render, context: modelContext)
                pendingDeletion = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The rendered video file will be permanently deleted.")
        }
    }

    private func row(_ render: SequenceRender) -> some View {
        HStack(spacing: 10) {
            thumbnail(render)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(render.versionLabel).font(.headline)
                Text(render.dimensionsLabel).font(.caption).foregroundStyle(.secondary)
                Text(render.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { actions(render) }
    }

    @ViewBuilder
    private func thumbnail(_ render: SequenceRender) -> some View {
        if let url = render.thumbnailURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "film.stack").foregroundStyle(.secondary))
        }
    }

    private func detailBar(_ render: SequenceRender) -> some View {
        HStack {
            Text("\(render.versionLabel) · \(render.dimensionsLabel)")
                .font(.callout)
            Spacer()
            actions(render)
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private func actions(_ render: SequenceRender) -> some View {
        Button {
            NSWorkspace.shared.open(render.videoURL)
        } label: { Label("Open in Player", systemImage: "play.rectangle") }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([render.videoURL])
        } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button {
            exportRender(render)
        } label: { Label("Export…", systemImage: "square.and.arrow.down") }
        Button(role: .destructive) {
            pendingDeletion = render
        } label: { Label("Delete…", systemImage: "trash") }
    }

    private func reload() {
        renders = SequenceRenderService.renders(for: sequence, context: modelContext)
        if selected == nil, let id = initialSelectionID, let initial = renders.first(where: { $0.id == id }) {
            selected = initial
        } else if selected == nil || !renders.contains(where: { $0.id == selected?.id }) {
            selected = renders.first
        }
    }

    private func exportRender(_ render: SequenceRender) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sequence.name)-\(render.versionLabel).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SequenceRenderService.export(render, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
