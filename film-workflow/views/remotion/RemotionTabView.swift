#if os(macOS)
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RemotionTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RemotionProject.updatedAt, order: .reverse) private var projects: [RemotionProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]

    @State private var selectedProject: RemotionProject?
    @State private var renamingProject: RemotionProject?
    @State private var pendingProjectDeletion: RemotionProject?
    @State private var renameText: String = ""
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName: String = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var statusMessage: String?
    @State private var isSeeding: Bool = false
    @State private var reloadToken: Int = 0
    @State private var runtime = RemotionRuntime.shared

    @State private var showSourceSheet: Bool = false
    @State private var renderError: String?
    @State private var showRenderError: Bool = false

    @State private var showExportSheet: Bool = false
    @State private var exportOptions: RemotionExportOptions?
    @State private var pendingProjectId: UUID?

    @State private var renderTask: Task<Void, Never>?
    @State private var renderProgress: RenderProgress = .init(stage: .starting, fraction: nil, detail: nil)
    @State private var showProgressSheet: Bool = false
    @State private var showRendersSheet: Bool = false
    @State private var rendersRefreshToken: Int = 0

    var body: some View {
        splitView
            .toolbar { toolbarContent }
            .modifier(SheetsModifier(
                renamingProject: $renamingProject,
                renameText: $renameText,
                showSourceSheet: $showSourceSheet,
                sourceProjectDir: selectedProject?.projectDir,
                sourceRefreshToken: reloadToken,
                showExportSheet: $showExportSheet,
                exportOptions: $exportOptions,
                projectName: selectedProject?.name ?? "video",
                sourceWidth: selectedProject?.compositionWidth ?? 1920,
                sourceHeight: selectedProject?.compositionHeight ?? 1080,
                sourceFps: selectedProject?.compositionFps ?? 30,
                onConfirmExport: confirmAndStartRender,
                showProgressSheet: $showProgressSheet,
                renderProgress: $renderProgress,
                onCancelRender: { renderTask?.cancel() },
                renderError: renderError,
                showRenderError: $showRenderError
            ))
            .publishesAgentTarget(kind: .remotion, projectUUID: selectedProject?.id)
            .sheet(isPresented: $showRendersSheet) {
                if let project = selectedProject {
                    NavigationStack {
                        RemotionRenderListView(project: project, refreshToken: rendersRefreshToken)
                            .navigationTitle("Renders")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showRendersSheet = false }
                                }
                            }
                    }
                    .frame(minWidth: 760, minHeight: 460)
                }
            }
            .onChange(of: selectedProject?.id) { _, newId in
                handleSelection(projectId: newId)
            }
            // The agent edits composition files through MCP; this is how the
            // Studio preview learns to reload. Replaces the old in-app agent's
            // `onFileWritten` callback, which only existed while its own chat
            // pane was on screen.
            .onReceive(NotificationCenter.default.publisher(for: .agentDidMutateProject)) { note in
                guard let tool = note.userInfo?["tool"] as? String,
                      tool.hasPrefix("remotion_")
                else { return }
                reloadToken += 1
                guard let project = selectedProject else { return }
                // The model may hardcode dimensions that disagree with the
                // project settings; the form remains the source of truth.
                let patched = RemotionCodeBuilder.patchProjectConstants(
                    in: project.compositionSource,
                    project: project
                )
                if patched != project.compositionSource {
                    project.compositionSource = patched
                    try? RemotionCodeBuilder.writeComposition(project: project, source: patched)
                }
            }
            .onAppear {
                // Returning from another tab: onDisappear stopped Studio, and
                // selectedProject didn't change so onChange won't re-fire. Re-boot it.
                if !showProgressSheet, let id = selectedProject?.id {
                    handleSelection(projectId: id)
                }
            }
            .onDisappear {
                Task { await runtime.stop() }
            }
            .confirmationDialog(
                "Delete this Remotion project?",
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
                Text("\"\(project.name)\" and its Remotion source, assets, and chat history will be permanently deleted.")
            }
            .projectGroupDialogs(
                editor: $groupEditor,
                name: $groupName,
                pendingDeletion: $pendingGroupDeletion,
                errorMessage: $groupErrorMessage
            )
    }

    @ViewBuilder
    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let project = selectedProject {
                editorPane(project: project)
                    .navigationTitle(project.name)
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "film.stack",
                    description: Text("Choose a project from the sidebar or create a new one.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let project = selectedProject {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourceSheet = true
                } label: {
                    Label("View Source", systemImage: "doc.text")
                }
                .disabled(project.compositionSource.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginExport(project: project)
                } label: {
                    if showProgressSheet {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Render", systemImage: "wand.and.stars")
                    }
                }
                .disabled(showProgressSheet || project.compositionSource.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRendersSheet = true
                } label: {
                    Label("Renders", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    private func confirmAndStartRender() {
        guard let id = pendingProjectId,
              let project = projects.first(where: { $0.id == id }),
              let opts = exportOptions else { return }
        startRender(project: project, options: opts)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedProject) {
            GroupedProjectSections(
                projects: projects,
                groups: groups,
                dragIdentifier: { $0.id.uuidString },
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .accountSidebarFooter()
        .navigationTitle("Remotion Projects")
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

    private func projectRow(_ project: RemotionProject) -> some View {
        NavigationLink(value: project) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.updatedAt, style: .date)
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
            Button("Duplicate") { duplicateProject(project) }
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

    @ViewBuilder
    private func editorPane(project: RemotionProject) -> some View {
        HSplitView {
            leftPanel(project: project)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

            previewPanel(project: project)
                .frame(minWidth: 360)
        }
    }

    /// The form is the whole left panel now. Refining a composition by
    /// conversation moved to the agent window, which can reach every project
    /// rather than only this one.
    @ViewBuilder
    private func leftPanel(project: RemotionProject) -> some View {
        RemotionParametersView(
            project: project,
            statusMessage: $statusMessage,
            isSeeding: $isSeeding
        )
    }

    @ViewBuilder
    private func previewPanel(project: RemotionProject) -> some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if runtime.isStarting {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting Remotion Studio…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if runtime.currentURL != nil, runtime.currentProjectId == project.id {
                RemotionPreviewWebView(url: runtime.currentURL, reloadToken: reloadToken)
            } else if showProgressSheet {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Studio preview is paused while rendering.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else if let err = runtime.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(err)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(project.createdViaMCP
                         ? "Loading the Studio preview…"
                         : "Click \"Create Composition & Start Studio\" to start the preview.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Actions

    private func addProject(groupID: UUID? = nil) {
        let project = RemotionProject(name: "Untitled Video")
        project.groupID = groupID
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

    private func moveProject(_ project: RemotionProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func duplicateProject(_ source: RemotionProject) {
        let copy = RemotionProjectService.duplicate(source, context: modelContext)
        copy.groupID = source.groupID
        selectedProject = copy
    }

    private func deleteProject(_ project: RemotionProject) {
        if selectedProject?.id == project.id {
            selectedProject = nil
            Task { await runtime.stop() }
        }
        RemotionProjectService.delete(project, context: modelContext)
    }

    private func handleSelection(projectId: UUID?) {
        guard let id = projectId else {
            Task { await runtime.stop() }
            return
        }
        guard let project = projects.first(where: { $0.id == id }) else {
            Task { await runtime.stop() }
            return
        }

        // The DB copy of compositionSource can lag behind disk — e.g. an MCP/agent
        // write that touched src/Composition.tsx directly. If we have a composition on
        // disk, trust it and bring the model back in sync rather than showing the
        // "Generate Initial Composition" placeholder.
        if project.compositionSource.isEmpty {
            let onDisk = project.projectDir
                .appendingPathComponent("src", isDirectory: true)
                .appendingPathComponent("Composition.tsx")
            if let recovered = try? String(contentsOf: onDisk, encoding: .utf8),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.compositionSource = recovered
            }
        }
        guard !project.compositionSource.isEmpty else {
            Task { await runtime.stop() }
            return
        }

        // Reconcile on-disk composition with the project's current resolution/fps/duration
        // before Studio boots, so the preview reflects the SwiftUI settings on first load.
        let patched = RemotionCodeBuilder.patchProjectConstants(
            in: project.compositionSource,
            project: project
        )
        if patched != project.compositionSource {
            project.compositionSource = patched
        }
        try? RemotionCodeBuilder.writeComposition(project: project, source: patched)

        Task {
            do {
                try await runtime.start(projectId: id, projectDir: project.projectDir)
                reloadToken += 1
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func beginExport(project: RemotionProject) {
        guard !showProgressSheet else { return }
        pendingProjectId = project.id
        let res = ExportResolution.allCases.first(where: {
            $0.size.width == project.compositionWidth &&
            $0.size.height == project.compositionHeight
        }) ?? .p1080
        let fps = ExportFrameRate(rawValue: project.compositionFps) ?? .fps30
        exportOptions = RemotionExportOptions(resolution: res, frameRate: fps)
        showExportSheet = true
    }

    private func startRender(project: RemotionProject, options: RemotionExportOptions) {
        renderError = nil
        renderProgress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
        showProgressSheet = true

        let projectId = project.id
        let projectDir = project.projectDir
        let (w, h) = options.resolution.size
        let fps = options.frameRate.rawValue

        renderTask = Task {
            defer {
                Task { @MainActor in
                    showProgressSheet = false
                    renderTask = nil
                }
            }
            do {
                // Always a fresh version: an explicit Render is a request for a
                // new take, even when nothing changed since the last one.
                _ = try await RemotionRenderService.ensureRender(
                    project: project,
                    width: w,
                    height: h,
                    fps: fps,
                    context: modelContext,
                    force: true
                ) { p in
                    renderProgress = p
                }
                rendersRefreshToken += 1
                showRendersSheet = true

                if selectedProject?.id == projectId {
                    do {
                        try await runtime.start(projectId: projectId, projectDir: projectDir)
                        reloadToken += 1
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                // user-initiated, no error UI
            } catch {
                await MainActor.run {
                    renderError = error.localizedDescription
                    showRenderError = true
                }
            }
        }
    }
}

private struct SheetsModifier: ViewModifier {
    @Binding var renamingProject: RemotionProject?
    @Binding var renameText: String

    @Binding var showSourceSheet: Bool
    let sourceProjectDir: URL?
    let sourceRefreshToken: Int

    @Binding var showExportSheet: Bool
    @Binding var exportOptions: RemotionExportOptions?
    let projectName: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFps: Int

    let onConfirmExport: () -> Void

    @Binding var showProgressSheet: Bool
    @Binding var renderProgress: RenderProgress
    let onCancelRender: () -> Void

    let renderError: String?
    @Binding var showRenderError: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $renamingProject) { project in
                RenameSheet(name: $renameText) {
                    project.name = renameText
                    project.updatedAt = Date()
                    renamingProject = nil
                } onCancel: {
                    renamingProject = nil
                }
            }
            .sheet(isPresented: $showSourceSheet) {
                if let dir = sourceProjectDir {
                    RemotionSourceSheetView(
                        projectDir: dir,
                        refreshToken: sourceRefreshToken
                    ) {
                        showSourceSheet = false
                    }
                }
            }
            .sheet(isPresented: $showExportSheet) {
                exportSheet
            }
            .sheet(isPresented: $showProgressSheet) {
                RemotionRenderProgressSheet(
                    projectName: projectName,
                    progress: $renderProgress,
                    onCancel: onCancelRender
                )
            }
            .alert("Render failed", isPresented: $showRenderError) {
                Button("OK") {}
            } message: {
                Text(renderError ?? "An unknown error occurred.")
            }
    }

    @ViewBuilder
    private var exportSheet: some View {
        if exportOptions != nil {
            RemotionExportSheet(
                projectName: projectName,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFps: sourceFps,
                options: Binding(
                    get: { exportOptions ?? RemotionExportOptions() },
                    set: { exportOptions = $0 }
                ),
                onCancel: { showExportSheet = false },
                onExport: {
                    showExportSheet = false
                    onConfirmExport()
                }
            )
        }
    }
}
#endif
