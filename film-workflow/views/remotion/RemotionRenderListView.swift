#if os(macOS)
import AppKit
import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Versions of a Remotion project's renders: play, reveal, export, delete.
struct RemotionRenderListView: View {
    @Environment(\.modelContext) private var modelContext
    let project: RemotionProject
    /// Bumped by the owner after a render so the list refetches.
    var refreshToken: Int = 0
    /// Selected when the list first appears, e.g. from the library's Versions menu.
    var initialSelectionID: UUID? = nil

    @State private var renders: [RemotionRender] = []
    @State private var selected: RemotionRender?
    @State private var player = AVPlayer()
    @State private var pendingDeletion: RemotionRender?

    var body: some View {
        Group {
            if renders.isEmpty {
                ContentUnavailableView(
                    "No Renders Yet",
                    systemImage: "film",
                    description: Text("Render the composition to create the first version.")
                )
            } else {
                HSplitView {
                    List(renders, selection: $selected) { render in
                        row(render)
                            .tag(render)
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    .accessibilityIdentifier("remotion.versions.list")

                    VStack(spacing: 0) {
                        VideoPlayer(player: player)
                            .frame(minHeight: 240)
                            .accessibilityIdentifier("remotion.versions.player")
                        if let selected {
                            detailBar(selected)
                        }
                    }
                    .frame(minWidth: 360)
                }
            }
        }
        .task(id: refreshToken) { reload() }
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
                RemotionRenderService.delete(render, context: modelContext)
                pendingDeletion = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The rendered video file will be permanently deleted.")
        }
    }

    private func row(_ render: RemotionRender) -> some View {
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remotion.version.\(render.versionNumber)")
    }

    @ViewBuilder
    private func thumbnail(_ render: RemotionRender) -> some View {
        if let url = render.thumbnailURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }

    private func detailBar(_ render: RemotionRender) -> some View {
        HStack {
            Text("\(render.versionLabel) · \(render.dimensionsLabel)")
                .font(.callout)
                .accessibilityIdentifier("remotion.versions.selection")
            Spacer()
            actions(render)
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private func actions(_ render: RemotionRender) -> some View {
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
        renders = RemotionRenderService.renders(for: project, context: modelContext)
        if selected == nil, let id = initialSelectionID, let initial = renders.first(where: { $0.id == id }) {
            selected = initial
        } else if selected == nil || !renders.contains(where: { $0.id == selected?.id }) {
            selected = renders.first
        }
    }

    private func exportRender(_ render: RemotionRender) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(project.name)-\(render.versionLabel).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RemotionRenderService.export(render, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
#endif
