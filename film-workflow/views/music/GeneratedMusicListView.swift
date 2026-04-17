import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GeneratedMusicListView: View {
    let files: [GeneratedMusic]
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var selectedFile: GeneratedMusic?

    private var sortedFiles: [GeneratedMusic] {
        files.sorted { $0.createdAt > $1.createdAt }
    }

    private var useCompactList: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if files.isEmpty {
                emptyStateView
            } else if useCompactList {
                compactListContent
            } else {
                cardListContent
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

    #if os(iOS)
    private var compactListContent: some View {
        List {
            ForEach(sortedFiles) { file in
                NavigationLink(value: file) {
                    GeneratedMusicCompactRow(file: file)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(file: file)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: GeneratedMusic.self) { file in
            GeneratedMusicDetailView(file: file) {
                delete(file: file)
            }
        }
    }
    #else
    private var compactListContent: some View { EmptyView() }
    #endif

    private var cardListContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedFiles) { file in
                    GeneratedMusicCard(
                        file: file,
                        isSelected: selectedFile?.id == file.id,
                        onSelect: { selectedFile = file },
                        onDelete: { delete(file: file) }
                    )
                }
            }
            .padding()
        }
    }

    private func delete(file: GeneratedMusic) {
        withAnimation(.easeInOut(duration: 0.25)) {
            FileStorage.deleteFile(at: file.audioFilePath)
            modelContext.delete(file)
            if selectedFile?.id == file.id {
                selectedFile = nil
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

private func audioUTType(for file: GeneratedMusic) -> UTType {
    file.fileExtension == "wav" ? .wav : .mp3
}

// MARK: - Compact Row (iOS)

#if os(iOS)
struct GeneratedMusicCompactRow: View {
    let file: GeneratedMusic

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.8), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.createdAt, style: .date)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(file.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(file.fileExtension.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
        }
        .padding(.vertical, 2)
    }
}
#endif

// MARK: - Detail View (iOS)

#if os(iOS)
struct GeneratedMusicDetailView: View {
    let file: GeneratedMusic
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var audioFile: AudioFile?
    @State private var showExporter = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                MusicPlayerView(url: file.audioURL)
                    .padding(16)
                    .background(Color.platformControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let lyrics = file.lyricsText, !lyrics.isEmpty {
                    lyricsSection(lyrics: lyrics)
                }
            }
            .padding()
        }
        .navigationTitle("Generated Music")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let data = try? Data(contentsOf: file.audioURL) {
                        audioFile = AudioFile(data: data, utType: audioUTType(for: file))
                        showExporter = true
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this music?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the audio file.")
        }
        .fileExporter(
            isPresented: $showExporter,
            item: audioFile,
            contentTypes: [audioUTType(for: file)],
            defaultFilename: "generated.\(file.fileExtension)"
        ) { result in
            audioFile = nil
            if case .failure(let error) = result {
                print("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.8), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.createdAt, style: .date)
                    .font(.headline)
                Text(file.createdAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(file.fileExtension.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
        }
    }

    private func lyricsSection(lyrics: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Lyrics", systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(lyrics)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.platformTextBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
#endif

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

    private var utType: UTType { audioUTType(for: file) }

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
                .background(Color.platformTextBackground.opacity(0.5))
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
            .fill(Color.platformControlBackground)
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
            Pasteboard.copy(file.audioURL.path)
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
