import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GeneratedNarrativeListView: View {
    let files: [GeneratedNarrative]
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var selectedFile: GeneratedNarrative?

    private var sortedFiles: [GeneratedNarrative] {
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
                Text("No Generated Narratives")
                    .font(.headline)

                Text("Generated narration will appear here after you click Generate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.bottom, 16)
    }

    #if os(iOS)
    private var compactListContent: some View {
        List {
            ForEach(sortedFiles) { file in
                NavigationLink(value: file) {
                    GeneratedNarrativeCompactRow(file: file)
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
        .navigationDestination(for: GeneratedNarrative.self) { file in
            GeneratedNarrativeDetailView(file: file) {
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
                    GeneratedNarrativeCard(
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

    private func delete(file: GeneratedNarrative) {
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

private struct NarrativeAudioFile: Transferable {
    let data: Data
    let utType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .audio) { file in
            file.data
        }
    }
}

private func audioUTType(for file: GeneratedNarrative) -> UTType {
    file.fileExtension == "wav" ? .wav : .mp3
}

// MARK: - Compact Row (iOS)

#if os(iOS)
struct GeneratedNarrativeCompactRow: View {
    let file: GeneratedNarrative

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
                    .lineLimit(1)

                Text(file.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !compactMetadataLabel.isEmpty {
                    Text(compactMetadataLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var compactMetadataLabel: String {
        var parts: [String] = []
        if !file.providerName.isEmpty { parts.append(file.providerName) }
        if !file.speakerSummary.isEmpty { parts.append(file.speakerSummary) }
        return parts.joined(separator: " · ")
    }
}
#endif

// MARK: - Detail View (iOS)

#if os(iOS)
struct GeneratedNarrativeDetailView: View {
    let file: GeneratedNarrative
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var audioFile: NarrativeAudioFile?
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

                if !file.transcriptText.isEmpty {
                    transcriptSection
                }
            }
            .padding()
        }
        .navigationTitle("Generated Narrative")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let data = try? Data(contentsOf: file.audioURL) {
                        audioFile = NarrativeAudioFile(data: data, utType: audioUTType(for: file))
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
            "Delete this narration?",
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
            defaultFilename: "narration.\(file.fileExtension)"
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

                if !detailMetadataLabel.isEmpty {
                    Text(detailMetadataLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var detailMetadataLabel: String {
        var parts: [String] = []
        if !file.providerName.isEmpty { parts.append(file.providerName) }
        if !file.speakerSummary.isEmpty { parts.append(file.speakerSummary) }
        return parts.joined(separator: " · ")
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Transcript", systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(file.transcriptText)
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

// MARK: - Card

struct GeneratedNarrativeCard: View {
    let file: GeneratedNarrative
    let isSelected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var showTranscript = false
    @State private var showExporter = false
    @State private var audioFile: NarrativeAudioFile?
    @State private var isHovering = false

    private var utType: UTType { audioUTType(for: file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
                .padding(16)

            Divider()
                .padding(.horizontal, 16)

            MusicPlayerView(url: file.audioURL)
                .padding(16)

            if !file.transcriptText.isEmpty {
                transcriptSection
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.platformControlBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture { onSelect() }
        .contextMenu { contextMenuContent }
        .fileExporter(
            isPresented: $showExporter,
            item: audioFile,
            contentTypes: [utType],
            defaultFilename: "narration.\(file.fileExtension)"
        ) { result in
            audioFile = nil
            if case .failure(let error) = result {
                print("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
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

                Text(file.createdAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !metadataLabel.isEmpty {
                    Text(metadataLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var metadataLabel: String {
        var parts: [String] = []
        if !file.providerName.isEmpty { parts.append(file.providerName) }
        if !file.speakerSummary.isEmpty { parts.append(file.speakerSummary) }
        return parts.joined(separator: " · ")
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 16)

            DisclosureGroup(isExpanded: $showTranscript) {
                ScrollView {
                    Text(file.transcriptText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 180)
                .background(Color.platformTextBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 8)
            } label: {
                Label("Transcript", systemImage: "text.quote")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            if let data = try? Data(contentsOf: file.audioURL) {
                audioFile = NarrativeAudioFile(data: data, utType: utType)
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

        if !file.transcriptText.isEmpty {
            Button {
                showTranscript.toggle()
            } label: {
                Label(showTranscript ? "Hide Transcript" : "Show Transcript", systemImage: "text.quote")
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}
