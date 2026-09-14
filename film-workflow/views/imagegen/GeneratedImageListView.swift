import SwiftUI
import VideoEditorCore

struct GeneratedImageListView: View {
    let files: [GeneratedImage]
    /// Previewed when the list first appears, e.g. from the library's Versions menu.
    var initialSelectionID: UUID? = nil
    var onDelete: (GeneratedImage) -> Void

    @State private var previewedFile: GeneratedImage?
    @State private var pendingDeletion: GeneratedImage?
    /// Authoring is admin-only; observing the service rebuilds the menus when
    /// the flag lands.
    @State private var authoring = MarketplaceAuthoringService.shared
    @State private var seedRequest: MarketplaceSeedRequest?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    /// What titles a draft made from a take: the item's own name, or enough of
    /// the prompt to recognise it by.
    private func title(for file: GeneratedImage) -> String {
        if let name = file.project?.name, !name.isEmpty { return name }
        let prompt = file.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? String(localized: "Generated image") : String(prompt.prefix(60))
    }

    /// Waits for the hosting sheet to finish presenting before stacking the preview on it.
    private func openInitial() async {
        guard previewedFile == nil, let id = initialSelectionID, let file = files.first(where: { $0.id == id }) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        previewedFile = file
    }

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView(
                    "No images yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Generated images will appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(files.sorted(by: { $0.createdAt > $1.createdAt })) { file in
                            GeneratedImageCard(
                                file: file,
                                onTap: { previewedFile = file },
                                onDelete: { pendingDeletion = $0 },
                                onCreateMarketplaceItem: authoring.canAuthor
                                    ? { seedRequest = .file(title: title(for: file), sourceKind: .image, file: file.imageURL) }
                                    : nil
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .marketplaceSeedHost($seedRequest)
        .task { await openInitial() }
        .sheet(item: $previewedFile) { file in
            GeneratedImagePreviewSheet(file: file) {
                previewedFile = nil
            }
        }
        .confirmationDialog(
            "Delete this generated image?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { file in
            Button("Delete Image", role: .destructive) {
                onDelete(file)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The generated image file will be permanently deleted.")
        }
    }
}

private struct GeneratedImageCard: View {
    let file: GeneratedImage
    var onTap: () -> Void
    var onDelete: (GeneratedImage) -> Void
    /// Nil hides the marketplace action, which is all that gates it.
    var onCreateMarketplaceItem: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                Group {
                    if let image = Image(contentsOfFile: file.imageURL) {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color.platformControlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.platformControlBackground)
                            .frame(height: 160)
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
            }
            .buttonStyle(.plain)

            Text(file.prompt)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.secondary)

            HStack {
                Text(file.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(8)
        .background(Color.platformTextBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        // The same actions on right-click, so this card behaves like every
        // other version list rather than hiding them behind the button.
        .contextMenu { actions }
    }

    /// One list, drawn by both the button and the context menu.
    @ViewBuilder
    private var actions: some View {
        Button("Copy Path") {
            Pasteboard.copy(file.imageURL.path)
        }
        Button("Reveal in Finder") {
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([file.imageURL])
            #endif
        }
        if let onCreateMarketplaceItem {
            Divider()
            Button(action: onCreateMarketplaceItem) {
                Label("Create Marketplace Item…", systemImage: "storefront")
            }
            Divider()
        }
        Button("Delete", role: .destructive) {
            onDelete(file)
        }
    }
}

private struct GeneratedImagePreviewSheet: View {
    let file: GeneratedImage
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = Image(contentsOfFile: file.imageURL) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.platformControlBackground)
                } else {
                    ContentUnavailableView(
                        "Image Unavailable",
                        systemImage: "photo",
                        description: Text("Could not load image at \(file.imageURL.path).")
                    )
                }

                if !file.prompt.isEmpty {
                    Text(file.prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical)
            .navigationTitle("Generated Image")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
                #if os(macOS)
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.imageURL])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
    }
}
