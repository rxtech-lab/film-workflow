import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GeneratedMusicListView: View {
    let files: [GeneratedMusic]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedFile: GeneratedMusic?

    private var sortedFiles: [GeneratedMusic] {
        files.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if files.isEmpty {
                emptyStateView
            } else {
                musicListContent
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 80, height: 80)

                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text("No Generated Music")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Generated music will appear here after you click Generate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var musicListContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedFiles) { file in
                    GeneratedMusicCard(
                        file: file,
                        isSelected: selectedFile?.id == file.id,
                        onSelect: { selectedFile = file },
                        onDelete: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                FileStorage.deleteFile(at: file.audioFilePath)
                                modelContext.delete(file)
                                if selectedFile?.id == file.id {
                                    selectedFile = nil
                                }
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Audio File Transfer

private struct AudioFile: Transferable {
    let data: Data
    let utType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .audio) { file in
            file.data
        }
    }
}

// MARK: - Music Card

struct GeneratedMusicCard: View {
    let file: GeneratedMusic
    let isSelected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var showLyrics = false
    @State private var showExporter = false
    @State private var audioFile: AudioFile?
    @State private var isHovering = false

    private var utType: UTType {
        file.fileExtension == "wav" ? .wav : .mp3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with metadata
            cardHeader
                .padding(16)

            Divider()
                .padding(.horizontal, 16)

            // Player controls
            playerSection
                .padding(16)

            // Expandable lyrics section
            if let lyrics = file.lyricsText, !lyrics.isEmpty {
                lyricsSection(lyrics: lyrics)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: .black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu { contextMenuContent }
        .fileExporter(
            isPresented: $showExporter,
            item: audioFile,
            contentTypes: [utType],
            defaultFilename: "generated.\(file.fileExtension)"
        ) { result in
            audioFile = nil
            if case .failure(let error) = result {
                print("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Waveform icon with gradient background
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.8), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)

                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.createdAt, style: .date)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(file.createdAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Format badge
            formatBadge
        }
    }

    private var formatBadge: some View {
        Text(file.fileExtension.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: Capsule())
    }

    private var playerSection: some View {
        MusicPlayerView(url: file.audioURL)
    }

    private func lyricsSection(lyrics: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 16)

            DisclosureGroup(isExpanded: $showLyrics) {
                ScrollView {
                    Text(lyrics)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 8)
            } label: {
                Label("Lyrics", systemImage: "text.quote")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 2 : 1
            )
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            if let data = try? Data(contentsOf: file.audioURL) {
                audioFile = AudioFile(data: data, utType: utType)
                showExporter = true
            }
        } label: {
            Label("Export\u{2026}", systemImage: "square.and.arrow.up")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.audioURL.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        if file.lyricsText != nil {
            Button {
                showLyrics.toggle()
            } label: {
                Label(showLyrics ? "Hide Lyrics" : "Show Lyrics", systemImage: "text.quote")
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Legacy Row (for compatibility)

struct GeneratedMusicRow: View {
    let file: GeneratedMusic
    var onDelete: () -> Void

    var body: some View {
        GeneratedMusicCard(
            file: file,
            isSelected: false,
            onSelect: {},
            onDelete: onDelete
        )
    }
}

// MARK: - Preview

#Preview("With Music Files") {
    GeneratedMusicListView_PreviewContainer(isEmpty: false)
}

#Preview("Empty State") {
    GeneratedMusicListView_PreviewContainer(isEmpty: true)
}

private struct GeneratedMusicListView_PreviewContainer: View {
    let isEmpty: Bool

    var body: some View {
        ScrollView {
            GeneratedMusicListView(files: isEmpty ? [] : PreviewMusicData.sampleFiles)
                .padding()
        }
        .frame(width: 500, height: 600)
    }
}

// Preview helper with sample data
private enum PreviewMusicData {
    static var sampleFiles: [GeneratedMusic] {
        // Create mock data for preview
        let file1 = GeneratedMusic(
            audioFilePath: "sample1.mp3",
            lyricsText: "Verse 1:\nWalking through the city lights\nDreaming of a better time\nEvery step I take tonight\nLeads me closer to the sky\n\nChorus:\nWe are the dreamers\nWe are the believers",
            project: MusicProject(name: "Preview Project")
        )

        let file2 = GeneratedMusic(
            audioFilePath: "sample2.wav",
            lyricsText: nil,
            project: MusicProject(name: "Preview Project")
        )

        let file3 = GeneratedMusic(
            audioFilePath: "sample3.mp3",
            lyricsText: "Instrumental track with ambient sounds",
            project: MusicProject(name: "Preview Project")
        )

        return [file1, file2, file3]
    }
}
