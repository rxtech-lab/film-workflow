import OSLog
import SwiftData
import SwiftUI

private let captionDetailLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "film-workflow",
    category: "CaptionDetailLoading"
)

private struct CaptionPreparedDetail {
    let projectID: UUID
    let projectUpdatedAt: Date
    let validationIssuesBySegment: [UUID: [CaptionValidationIssue]]
}

struct CaptionTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \CaptionProject.updatedAt, order: .reverse) private var projects: [CaptionProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @State private var selectedProject: CaptionProject?
    @State private var renamingProject: CaptionProject?
    @State private var pendingProjectDeletion: CaptionProject?
    @State private var renameText: String = ""
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName: String = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var isTranscribing = false
    @State private var progress: CaptionProgress?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var successNotice: String?
    @State private var pendingRetranscribe: CaptionProject?
    @State private var preparedDetail: CaptionPreparedDetail?

    private var isCompact: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact
        #else
            false
        #endif
    }

    private var projectSelection: Binding<CaptionProject?> {
        Binding(
            get: { selectedProject },
            set: { selectProject($0) }
        )
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: projectSelection) {
            GroupedProjectSections(
                projects: projects,
                groups: groups,
                dragIdentifier: { $0.projectUUID.uuidString },
                onMove: moveProject,
                onCreateProject: { addProject(groupID: $0) },
                onCreateGroup: beginCreatingGroup,
                onRenameGroup: beginRenamingGroup,
                onDeleteGroup: { pendingGroupDeletion = $0 }
            ) { project in
                projectRow(project)
            }
        }
        .contextMenu {
            ProjectCreationMenuItems(
                onCreateProject: { addProject() },
                onCreateGroup: beginCreatingGroup
            )
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .navigationTitle("Captions")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { addProject() }) {
                    Label("New Caption Project", systemImage: "plus")
                }
                Button(action: beginCreatingGroup) {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private func projectRow(_ project: CaptionProject) -> some View {
        NavigationLink(value: project) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: project.isNarrativeSourced
                        ? "text.book.closed" : "waveform")
                    if project.activeSegmentCount == 0 {
                        Text("No captions")
                    } else {
                        Text("\(project.activeSegmentCount) captions")
                    }
                    if project.activeAlignmentQuality.needsReview {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            ProjectCreationMenuItems(
                onCreateProject: { addProject(groupID: project.groupID) },
                onCreateGroup: beginCreatingGroup
            )
            Divider()
            Button("Rename") {
                renameText = project.name
                renamingProject = project
            }
            MoveToProjectGroupMenu(
                groups: groups,
                currentGroupID: project.groupID,
                onMove: { moveProject(project, to: $0) }
            )
            Divider()
            Button("Delete…", role: .destructive) {
                pendingProjectDeletion = project
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "Select a Caption Project",
            systemImage: "captions.bubble",
            description: Text("Choose a caption project from the sidebar or create a new one.")
        )
    }

    @ViewBuilder
    private func compactDetail(for project: CaptionProject) -> some View {
        if let detail = preparedDetail, detail.projectID == project.projectUUID {
            CaptionCompactDetail(
                project: project,
                preparedDetail: detail,
                isTranscribing: isTranscribing,
                canTranscribe: project.hasAudio,
                onTranscribe: { requestTranscribe(project) }
            )
            #if os(iOS)
                .toolbar(.hidden, for: .tabBar)
            #endif
        } else {
            CaptionProjectLoadingView(projectName: project.name)
        }
    }

    @ViewBuilder
    private func parametersColumn(for project: CaptionProject) -> some View {
        if preparedDetail?.projectID == project.projectUUID {
            CaptionProjectParametersView(
                project: project,
                isTranscribing: isTranscribing
            )
        } else {
            CaptionProjectLoadingView(projectName: project.name)
        }
    }

    @ViewBuilder
    private func captionsColumn(for project: CaptionProject) -> some View {
        if let detail = preparedDetail, detail.projectID == project.projectUUID {
            CaptionSegmentListView(
                project: project,
                initialValidationIssues: detail.validationIssuesBySegment,
                validatedProjectUpdate: detail.projectUpdatedAt
            )
            .id(project.projectUUID)
            .navigationTitle(project.name)
        } else {
            CaptionProjectLoadingView(projectName: project.name)
        }
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let project = selectedProject {
                        compactDetail(for: project)
                    } else {
                        placeholder
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } content: {
                    if let project = selectedProject {
                        parametersColumn(for: project)
                    } else {
                        ContentUnavailableView(
                            "Select a Caption Project",
                            systemImage: "captions.bubble",
                            description: Text("Choose a caption project from the sidebar.")
                        )
                    }
                } detail: {
                    if let project = selectedProject {
                        captionsColumn(for: project)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .task(id: selectedProject?.projectUUID) {
            await prepareSelectedProject()
        }
        .publishesAgentTarget(kind: .caption, projectUUID: selectedProject?.projectUUID)
        .toolbar {
            if let project = selectedProject,
               preparedDetail?.projectID == project.projectUUID,
               !isCompact {
                ToolbarItem(placement: .primaryAction) {
                    CaptionTranscribeButton(
                        hasCaptions: project.activeSegmentCount > 0,
                        isTranscribing: isTranscribing,
                        canTranscribe: project.hasAudio,
                        action: { requestTranscribe(project) }
                    )
                }
            }
        }
        .sheet(isPresented: $isTranscribing) {
            CaptionTranscriptionProgressView(progress: progress) {
                transcriptionTask?.cancel()
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .alert(
            "Captions ready",
            isPresented: Binding(
                get: { successNotice != nil },
                set: { if !$0 { successNotice = nil } }
            )
        ) {
            Button("OK") { successNotice = nil }
        } message: {
            Text(successNotice ?? "")
        }
        .alert("Rename Caption Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename") {
                if let project = renamingProject {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        project.name = trimmed
                        project.updatedAt = Date()
                    }
                }
                renamingProject = nil
            }
        }
        .confirmationDialog(
            "Delete this caption project?",
            isPresented: Binding(
                get: { pendingProjectDeletion != nil },
                set: { if !$0 { pendingProjectDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingProjectDeletion
        ) { project in
            Button("Delete Project", role: .destructive) {
                deleteProject(project)
                pendingProjectDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingProjectDeletion = nil }
        } message: { project in
            Text("\"\(project.name)\", its transcript versions, and any audio it owns will be permanently deleted.")
        }
        // On the outer Group so it covers the split-view and compact layouts
        // from one place — both toolbars call `requestTranscribe`.
        .confirmationDialog(
            "Re-transcribe these captions?",
            isPresented: Binding(
                get: { pendingRetranscribe != nil },
                set: { if !$0 { pendingRetranscribe = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRetranscribe
        ) { project in
            // Not `.destructive`: nothing is thrown away any more, and that is
            // exactly what the message says.
            Button("Re-transcribe") {
                let target = project
                pendingRetranscribe = nil
                transcribe(target)
            }
            Button("Cancel", role: .cancel) { pendingRetranscribe = nil }
        } message: { project in
            Text("""
                This creates version \(project.nextVersionNumber). The current \
                version and its translations are kept, and translations carry \
                over for captions that come out unchanged. You can switch back \
                in Caption Setup at any time.
                """)
        }
        .projectGroupDialogs(
            editor: $groupEditor,
            name: $groupName,
            pendingDeletion: $pendingGroupDeletion,
            errorMessage: $groupErrorMessage
        )
    }

    // MARK: - Actions

    private func selectProject(_ project: CaptionProject?) {
        guard selectedProject?.projectUUID != project?.projectUUID else { return }
        preparedDetail = nil
        selectedProject = project
    }

    /// Materializes and validates a project only after SwiftUI has rendered the
    /// loading state. Validation is pure value work and can leave the main
    /// actor; SwiftData snapshotting and the legacy version backfill cannot.
    private func prepareSelectedProject() async {
        guard let project = selectedProject else {
            preparedDetail = nil
            return
        }

        let projectID = project.projectUUID
        let startedAt = Date()
        captionDetailLogger.info("Opening caption project \(projectID.uuidString, privacy: .public)")

        // Give the selection transaction a frame to present ProgressView before
        // SwiftData materializes a large relationship or performs a backfill.
        await Task.yield()
        guard !Task.isCancelled, selectedProject?.projectUUID == projectID else { return }

        let snapshotStartedAt = Date()
        project.ensureVersioned()
        let snapshot = project.snapshot()
        let snapshotSeconds = Date().timeIntervalSince(snapshotStartedAt)
        captionDetailLogger.info(
            "Caption snapshot ready: \(snapshot.segments.count) rows in \(snapshotSeconds) seconds"
        )

        let validationStartedAt = Date()
        let issues = await Task.detached(priority: .userInitiated) {
            CaptionTranscriptValidator.rowIssuesBySegmentID(in: snapshot)
        }.value
        guard !Task.isCancelled, selectedProject?.projectUUID == projectID else { return }

        let validationSeconds = Date().timeIntervalSince(validationStartedAt)
        let totalSeconds = Date().timeIntervalSince(startedAt)
        let issueCount = issues.values.reduce(0) { $0 + $1.count }
        preparedDetail = CaptionPreparedDetail(
            projectID: projectID,
            projectUpdatedAt: project.updatedAt,
            validationIssuesBySegment: issues
        )
        captionDetailLogger.info(
            """
            Caption detail ready: \(issueCount) row issues, validation \(validationSeconds) seconds, \
            total \(totalSeconds) seconds
            """
        )
    }

    private func addProject(groupID: UUID? = nil) {
        let project = CaptionProject(name: "Untitled Captions")
        project.groupID = groupID
        project.languageHint = CaptionSettings.shared.defaultLanguageHint
        project.maxSpeakers = CaptionSettings.shared.defaultMaxSpeakers
        modelContext.insert(project)
        selectProject(project)
    }

    private func beginCreatingGroup() {
        groupName = ""
        groupEditor = .create
    }

    private func beginRenamingGroup(_ group: ProjectGroup) {
        groupName = group.name
        groupEditor = .rename(group)
    }

    private func moveProject(_ project: CaptionProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: CaptionProject) {
        if selectedProject == project {
            selectProject(nil)
        }
        // Only delete audio this project owns — a narrative-sourced project
        // points at a GeneratedNarrative's file, which must survive.
        if project.ownsAudioFile, !project.audioFilePath.isEmpty {
            FileStorage.deleteFile(at: project.audioFilePath)
        }
        modelContext.delete(project)
    }

    /// Confirms a re-run, but never a first run.
    ///
    /// There is nothing to lose the first time, and a dialog on every single
    /// transcription would train the user to dismiss it without reading — which
    /// is precisely when it needs to be read.
    private func requestTranscribe(_ project: CaptionProject) {
        guard !isTranscribing else { return }
        guard project.activeSegmentCount > 0 else {
            transcribe(project)
            return
        }
        pendingRetranscribe = project
    }

    private func transcribe(_ project: CaptionProject) {
        guard !isTranscribing else { return }
        isTranscribing = true
        progress = nil

        transcriptionTask = Task {
            defer {
                isTranscribing = false
                progress = nil
                transcriptionTask = nil
            }
            do {
                let config = try AppConfig.loadFromKeychain()
                let count: Int
                if project.isNarrativeSourced {
                    count = try await CaptionTranscriptionService.alignNarrative(
                        project: project,
                        context: modelContext,
                        config: config,
                        onProgress: { progress = $0 }
                    )
                } else {
                    count = try await CaptionTranscriptionService.transcribe(
                        project: project,
                        context: modelContext,
                        config: config,
                        onProgress: { progress = $0 }
                    )
                }
                successNotice = "Created \(count) caption\(count == 1 ? "" : "s")."
            } catch is CancellationError {
                // User pressed Cancel; nothing to report.
            } catch let error as URLError where error.code == .cancelled {
                // Same, surfaced from URLSession.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

/// The primary action, shared by the split-view toolbar and the compact one so
/// both read "Transcribe" / "Re-transcribe" identically.
private struct CaptionTranscribeButton: View {
    let hasCaptions: Bool
    let isTranscribing: Bool
    let canTranscribe: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isTranscribing {
                ProgressView().controlSize(.small)
            } else {
                // Same glyph as the narrative tab's Generate button: both are
                // "make the thing" primary actions.
                Label(
                    hasCaptions ? "Re-transcribe" : "Transcribe",
                    systemImage: "wand.and.stars"
                )
            }
        }
        .disabled(isTranscribing || !canTranscribe)
        .help(canTranscribe
            ? "Transcribe this audio into captions"
            : "Choose an audio file or a narration first")
    }
}

/// Compact iOS layout: setup and captions as two segments rather than three
/// columns, matching `NarrativeProjectDetailPanes`.
private struct CaptionCompactDetail: View {
    @Bindable var project: CaptionProject
    let preparedDetail: CaptionPreparedDetail
    let isTranscribing: Bool
    let canTranscribe: Bool
    let onTranscribe: () -> Void

    @State private var pane: Pane = .setup

    private enum Pane: String, CaseIterable, Identifiable {
        case setup
        case captions

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .setup: return "Setup"
            case .captions: return "Captions"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch pane {
            case .setup:
                CaptionProjectParametersView(
                    project: project,
                    isTranscribing: isTranscribing
                )
            case .captions:
                CaptionSegmentListView(
                    project: project,
                    initialValidationIssues: preparedDetail.validationIssuesBySegment,
                    validatedProjectUpdate: preparedDetail.projectUpdatedAt
                )
                .id(project.projectUUID)
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CaptionTranscribeButton(
                    hasCaptions: project.activeSegmentCount > 0,
                    isTranscribing: isTranscribing,
                    canTranscribe: canTranscribe,
                    action: onTranscribe
                )
            }
        }
    }
}

private struct CaptionProjectLoadingView: View {
    let projectName: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Loading caption project")
            Text("Loading Captions…")
                .font(.headline)
            Text(projectName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(projectName)
    }
}
