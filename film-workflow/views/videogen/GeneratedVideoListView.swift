import AVKit
import SwiftUI

struct GeneratedVideoListView: View {
    let files: [GeneratedVideo]
    var onDelete: (GeneratedVideo) -> Void

    @State private var previewedFile: GeneratedVideo?
    @State private var pendingDeletion: GeneratedVideo?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView(
                    "No videos yet",
                    systemImage: "video.badge.waveform",
                    description: Text("Generated videos will appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(files.sorted(by: { $0.createdAt > $1.createdAt })) { file in
                            GeneratedVideoCard(
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
            GeneratedVideoPreviewSheet(file: file) {
                previewedFile = nil
            }
        }
        .confirmationDialog(
            "Delete this generated video?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { file in
            Button("Delete Video", role: .destructive) {
                onDelete(file)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The generated video file will be permanently deleted.")
        }
    }
}

private struct GeneratedVideoCard: View {
    let file: GeneratedVideo
    var onTap: () -> Void
    var onDelete: (GeneratedVideo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                ZStack {
                    if let url = file.thumbnailURL, let image = Image(contentsOfFile: url) {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color.platformControlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.platformControlBackground)
                            .frame(height: 120)
                    }

                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .buttonStyle(.plain)

            Text(file.prompt)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.secondary)

            if !file.dimensionsLabel.isEmpty {
                Text(file.dimensionsLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(file.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("Copy Path") {
                        Pasteboard.copy(file.videoURL.path)
                    }
                    Button("Reveal in Finder") {
                        #if os(macOS)
                        NSWorkspace.shared.activateFileViewerSelecting([file.videoURL])
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

private struct GeneratedVideoPreviewSheet: View {
    let file: GeneratedVideo
    var onDismiss: () -> Void

    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

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
            .navigationTitle("Generated Video")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: file.videoURL)
                }
                #if os(macOS)
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.videoURL])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                #endif
            }
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: file.videoURL))
            player.play()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 560)
        #endif
    }
}
