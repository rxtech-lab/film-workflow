import SwiftUI

struct GeneratedImageListView: View {
    let files: [GeneratedImage]
    var onDelete: (GeneratedImage) -> Void

    @State private var previewedFile: GeneratedImage?
    @State private var pendingDeletion: GeneratedImage?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

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
                                onDelete: { pendingDeletion = $0 }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
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
                    Button("Copy Path") {
                        Pasteboard.copy(file.imageURL.path)
                    }
                    Button("Reveal in Finder") {
                        #if os(macOS)
                        NSWorkspace.shared.activateFileViewerSelecting([file.imageURL])
                        #endif
                    }
                    Button("Delete", role: .destructive) {
                        onDelete(file)
                    }
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
