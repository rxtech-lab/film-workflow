import SwiftData
import SwiftUI

struct VideoGenTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \VideoGenProject.updatedAt, order: .reverse) private var projects: [VideoGenProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @State private var selectedProject: VideoGenProject?
    @State private var renamingProject: VideoGenProject?
    @State private var pendingProjectDeletion: VideoGenProject?
    @State private var renameText: String = ""
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName: String = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showHistorySheet = false

    // A generation is one cancellable Task plus a progress sheet, the shape
    // `RemotionTabView` uses for renders. Unlike a render, cancelling here does
    // not throw the work away — see `resume` below.
    @State private var generateTask: Task<Void, Never>?
    @State private var progress: VideoGenProgress = .submitting
    @State private var showProgressSheet = false
    @State private var showResumeChoice = false

    private var isGenerating: Bool { generateTask != nil }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedProject) {
            GroupedProjectSections(
                projects: projects,
                groups: groups,
                dragIdentifier: { String(describing: $0.persistentModelID) },
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
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { addProject() }) {
                    Label("New Project", systemImage: "plus")
                }
                Button(action: beginCreatingGroup) {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private func projectRow(_ project: VideoGenProject) -> some View {
        NavigationLink(value: project) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(project.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Makes an abandoned job discoverable — otherwise a generation
                // the user quit out of is invisible until they happen to
                // reselect the project.
                if project.hasPendingJob {
                    ProgressView()
                        .controlSize(.small)
                        .help("A generation is still running")
                }
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
            "Select a Project",
            systemImage: "video.badge.waveform",
            description: Text("Choose a project from the sidebar or create a new one.")
        )
    }

    @ViewBuilder
    private func pendingJobBanner(_ project: VideoGenProject) -> some View {
        if project.hasPendingJob, !isGenerating {
            HStack(spacing: 10) {
                Image(systemName: project.pendingJobIsStale ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                    .foregroundStyle(project.pendingJobIsStale ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.pendingJobIsStale
                        ? "This generation is over a day old and probably expired."
                        : "A generation is still running with the provider.")
                        .font(.callout)
                    if let startedAt = project.pendingJobStartedAt {
                        Text("Started \(startedAt, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !project.pendingJobIsStale {
                    Button("Resume") { startResume(project: project) }
                }
                Button("Discard") {
                    VideoGenerationService.abandonPendingJob(project, context: modelContext)
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.platformControlBackground)
        }
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let project = selectedProject {
                        VideoGenDetailPane(
                            project: project,
                            isGenerating: isGenerating,
                            banner: { AnyView(pendingJobBanner(project)) },
                            onGenerate: { startGenerate(project: project) },
                            onShowHistory: { showHistorySheet = true }
                        )
                        #if os(iOS)
                        .toolbar(.hidden, for: .tabBar)
                        #endif
                    } else {
                        placeholder
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } content: {
                    if let project = selectedProject {
                        VStack(spacing: 0) {
                            pendingJobBanner(project)
                            VideoGenProjectParametersView(project: project)
                        }
                    } else {
                        placeholder
                    }
                } detail: {
                    if let project = selectedProject {
                        GeneratedVideoListView(files: project.generatedFiles) { file in
                            deleteVideo(file, project: project)
                        }
                        .navigationTitle(project.name)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .publishesAgentTarget(kind: .videoGen, projectUUID: selectedProject.map(MCPProjectHandlers.stableID))
        .toolbar {
            if let project = selectedProject, !isCompact {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startGenerate(project: project)
                    } label: {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Generate", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isGenerating || !canGenerate(project))
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "This project already has a generation running.",
            isPresented: $showResumeChoice,
            titleVisibility: .visible
        ) {
            Button("Resume It") {
                if let project = selectedProject { startResume(project: project) }
            }
            Button("Start a New One") {
                if let project = selectedProject {
                    VideoGenerationService.abandonPendingJob(project, context: modelContext)
                    startGenerate(project: project, force: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starting a new generation abandons the running one — the provider may still bill it.")
        }
        .sheet(isPresented: $showProgressSheet) {
            VideoGenProgressSheet(
                projectName: selectedProject?.name ?? "",
                progress: $progress,
                onCancel: { generateTask?.cancel() }
            )
        }
        .sheet(isPresented: $showHistorySheet) {
            if let project = selectedProject {
                NavigationStack {
                    GeneratedVideoListView(files: project.generatedFiles) { file in
                        deleteVideo(file, project: project)
                    }
                    .navigationTitle("Generated Videos")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showHistorySheet = false
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameSheet(name: $renameText) {
                project.name = renameText
                project.updatedAt = Date()
                renamingProject = nil
            } onCancel: {
                renamingProject = nil
            }
        }
        .confirmationDialog(
            "Delete this video project?",
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
            Text("\"\(project.name)\" and its generated videos will be permanently deleted.")
        }
        .projectGroupDialogs(
            editor: $groupEditor,
            name: $groupName,
            pendingDeletion: $pendingGroupDeletion,
            errorMessage: $groupErrorMessage
        )
    }

    // MARK: - Actions

    private func addProject(groupID: UUID? = nil) {
        let project = VideoGenProject(name: "Untitled Project")
        project.groupID = groupID
        if let config = try? AppConfig.loadFromKeychain(), !config.defaultVideoModel.isEmpty {
            project.googleModel = config.defaultVideoModel
            VeoModelFamily.clamp(project)
        }
        modelContext.insert(project)
        selectedProject = project
    }

    private func beginCreatingGroup() {
        groupName = ""
        groupEditor = .create
    }

    private func beginRenamingGroup(_ group: ProjectGroup) {
        groupName = group.name
        groupEditor = .rename(group)
    }

    private func moveProject(_ project: VideoGenProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: VideoGenProject) {
        if selectedProject == project {
            selectedProject = nil
        }
        for file in project.generatedFiles {
            FileStorage.deleteFile(at: file.videoFilePath)
            if let thumbnail = file.thumbnailFilePath {
                FileStorage.deleteFile(at: thumbnail)
            }
        }
        modelContext.delete(project)
    }

    private func deleteVideo(_ file: GeneratedVideo, project: VideoGenProject) {
        FileStorage.deleteFile(at: file.videoFilePath)
        if let thumbnail = file.thumbnailFilePath {
            FileStorage.deleteFile(at: thumbnail)
        }
        modelContext.delete(file)
        project.updatedAt = Date()
    }

    private func canGenerate(_ project: VideoGenProject) -> Bool {
        guard !project.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !project.googleModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func startGenerate(project: VideoGenProject, force: Bool = false) {
        guard generateTask == nil else { return }
        // Never silently abandon a job the provider is already billing for.
        if project.hasPendingJob, !force {
            showResumeChoice = true
            return
        }
        run(project: project) { config, onProgress in
            try await VideoGenerationService.generate(
                project: project,
                context: modelContext,
                config: config,
                onProgress: onProgress
            )
        }
    }

    private func startResume(project: VideoGenProject) {
        guard generateTask == nil else { return }
        run(project: project) { config, onProgress in
            try await VideoGenerationService.resume(
                project: project,
                context: modelContext,
                config: config,
                onProgress: onProgress
            )
        }
    }

    private func run(
        project: VideoGenProject,
        work: @escaping @MainActor (AppConfig, @escaping VideoProgressHandler) async throws -> Any?
    ) {
        progress = .submitting
        showProgressSheet = true

        generateTask = Task { @MainActor in
            defer {
                showProgressSheet = false
                generateTask = nil
            }
            do {
                let config = try AppConfig.loadFromKeychain()
                _ = try await work(config) { update in
                    progress = update
                }
            } catch is CancellationError {
                // User-initiated: the job stays pending so it can be resumed.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

private struct VideoGenDetailPane: View {
    @Bindable var project: VideoGenProject
    var isGenerating: Bool
    var banner: () -> AnyView
    var onGenerate: () -> Void
    var onShowHistory: () -> Void

    @State private var selectedPane: Pane = .parameters

    enum Pane: String, CaseIterable, Identifiable {
        case parameters = "Parameters"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            banner()

            Picker("", selection: $selectedPane) {
                ForEach(Pane.allCases) { pane in
                    Text(LocalizedStringKey(pane.rawValue)).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedPane {
                case .parameters:
                    VideoGenProjectParametersView(project: project)
                case .history:
                    GeneratedVideoListView(files: project.generatedFiles) { _ in }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onGenerate) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isGenerating)
            }
        }
    }
}
