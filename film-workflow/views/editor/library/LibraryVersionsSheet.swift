import SwiftData
import SwiftUI

/// Which item's versions the sheet shows, and which one to open on.
struct LibraryVersionsTarget: Identifiable, Hashable {
    let item: LibraryItemID
    let versionID: UUID?
    var id: LibraryItemID { item }
}

/// Every version of one library item — generated takes, renders or
/// transcripts — opened from the library's context menu.
struct LibraryVersionsSheet: View {
    let index: LibraryIndex
    let target: LibraryVersionsTarget
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var title: String {
        guard let name = index.name(of: target.item), !name.isEmpty else { return String(localized: "Versions") }
        return String(localized: "\(name) Versions")
    }

    @ViewBuilder
    private var content: some View {
        switch target.item.kind {
        case .screenRecording:
            if let project = index.recording(target.item.id) {
                RecordingTakeListView(project: project)
            } else { missing }
        case .music:
            if let p = index.music(target.item.id) {
                GeneratedMusicListView(files: p.generatedFiles, initialSelectionID: target.versionID)
            } else { missing }
        case .narration:
            if let p = index.narration(target.item.id) {
                GeneratedNarrativeListView(files: p.generatedFiles, initialSelectionID: target.versionID)
            } else { missing }
        case .image:
            if let p = index.image(target.item.id) {
                GeneratedImageListView(files: p.generatedFiles, initialSelectionID: target.versionID) { file in
                    storage.deleteFile(at: file.imageFilePath)
                    modelContext.delete(file)
                    p.updatedAt = Date()
                }
            } else { missing }
        case .video:
            if let p = index.video(target.item.id) {
                GeneratedVideoListView(files: p.generatedFiles, initialSelectionID: target.versionID) { file in
                    storage.deleteFile(at: file.videoFilePath)
                    if let t = file.thumbnailFilePath { storage.deleteFile(at: t) }
                    modelContext.delete(file)
                    p.updatedAt = Date()
                }
            } else { missing }
        case .remotion:
            if let p = index.remotion(target.item.id) {
                RemotionRenderListView(project: p, initialSelectionID: target.versionID)
            } else { missing }
        case .sequence:
            if let s = index.sequence(target.item.id) {
                SequenceRenderListView(sequence: s, initialSelectionID: target.versionID)
            } else { missing }
        case .caption:
            if let p = index.caption(target.item.id) {
                CaptionVersionsListView(project: p, highlightedID: target.versionID)
            } else { missing }
        case .imported:
            ContentUnavailableView("No Versions", systemImage: "paperclip",
                                   description: Text("Imported files have a single version."))
        }
    }

    private var missing: some View {
        ContentUnavailableView("Not Found", systemImage: "questionmark.folder")
    }
}

/// Takes of one screen recording. Right-click removes a take, the same command
/// the trailing button runs and behind the same confirmation.
private struct RecordingTakeListView: View {
    let project: ScreenRecordingProject
    @State private var pendingRemoval: RecordingTake?

    var body: some View {
        List(project.visibleTakes.sorted { $0.createdAt > $1.createdAt }) { take in
            HStack {
                VStack(alignment: .leading) { Text(take.name).font(.headline); Text("\(take.duration, specifier: "%.1f")s · \(take.components.count) tracks") }
                Spacer()
                RecordingTakeRemoveButton(take: take, selection: $pendingRemoval).buttonStyle(.borderless)
            }
            .contextMenu {
                Button("Remove Take…", systemImage: "trash", role: .destructive) { pendingRemoval = take }
            }
        }
        .modifier(RecordingTakeRemovalConfirmation(take: $pendingRemoval))
    }
}

/// Transcription runs of a caption project. Choosing one makes it the take the
/// editor, exports and translations all point at.
private struct CaptionVersionsListView: View {
    let project: CaptionProject
    let highlightedID: UUID?

    @Environment(\.modelContext) private var modelContext
    @State private var pendingDeletion: CaptionTranscriptVersion?

    var body: some View {
        if project.orderedVersions.isEmpty {
            ContentUnavailableView("No Versions", systemImage: "captions.bubble",
                                   description: Text("Transcribe the audio to create version 1."))
        } else {
            List(project.orderedVersions) { version in
                let isActive = version.id == project.activeVersionID
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(version.number)").font(.callout.weight(.semibold))
                        Text(detail(version)).font(.caption).foregroundStyle(.secondary)
                        if !version.note.isEmpty {
                            Text(version.note).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if isActive {
                        Text("Active").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Use This Version") { _ = CaptionTranscriptionService.activateVersion(version.id, in: project) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(version.id == highlightedID ? Color.accentColor.opacity(0.12) : nil)
                .contextMenu { menu(for: version) }
            }
            .listStyle(.inset)
            .modifier(CaptionVersionDeleteConfirmation(
                version: $pendingDeletion,
                onDelete: { version in
                    CaptionTranscriptionService.deleteVersion(version.id, from: project, context: modelContext)
                }
            ))
        }
    }

    /// Delete is hidden on the last version rather than disabled: the service
    /// refuses it outright, since a project with captions and no version reads
    /// as pre-versioning and shows every take at once.
    @ViewBuilder
    private func menu(for version: CaptionTranscriptVersion) -> some View {
        if version.id != project.activeVersionID {
            Button("Use This Version") { _ = CaptionTranscriptionService.activateVersion(version.id, in: project) }
        }
        if project.versions.count > 1 {
            Divider()
            Button("Delete Version…", systemImage: "trash", role: .destructive) { pendingDeletion = version }
        }
    }

    private func detail(_ version: CaptionTranscriptVersion) -> String {
        var parts = ["\(version.segmentCount) captions"]
        if let provider = version.providerEnum { parts.append(provider.displayName) }
        if !version.languageCode.isEmpty { parts.append(version.languageCode) }
        parts.append(version.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
