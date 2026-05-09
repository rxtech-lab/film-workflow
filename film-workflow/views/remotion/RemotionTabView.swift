#if os(macOS)
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RemotionTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RemotionProject.updatedAt, order: .reverse) private var projects: [RemotionProject]

    @State private var selectedProject: RemotionProject?
    @State private var renamingProject: RemotionProject?
    @State private var renameText: String = ""
    @State private var statusMessage: String?
    @State private var isSeeding: Bool = false
    @State private var reloadToken: Int = 0
    @State private var runtime = RemotionRuntime.shared

    @State private var showSourceSheet: Bool = false
    @State private var renderError: String?
    @State private var showRenderError: Bool = false

    @State private var showExportSheet: Bool = false
    @State private var exportOptions: RemotionExportOptions?
    @State private var showConfirmExport: Bool = false
    @State private var pendingProjectId: UUID?

    @State private var renderTask: Task<Void, Never>?
    @State private var renderProgress: RenderProgress = .init(stage: .starting, fraction: nil, detail: nil)
    @State private var showProgressSheet: Bool = false

    @State private var leftTab: LeftTab = .form

    private enum LeftTab: Hashable {
        case form
        case chat
    }

    var body: some View {
        splitView
            .toolbar { toolbarContent }
            .modifier(SheetsModifier(
                renamingProject: $renamingProject,
                renameText: $renameText,
                showSourceSheet: $showSourceSheet,
                sourceProjectId: selectedProject?.id,
                sourceRefreshToken: reloadToken,
                showExportSheet: $showExportSheet,
                exportOptions: $exportOptions,
                projectName: selectedProject?.name ?? "video",
                sourceWidth: selectedProject?.compositionWidth ?? 1920,
                sourceHeight: selectedProject?.compositionHeight ?? 1080,
                sourceFps: selectedProject?.compositionFps ?? 30,
                showConfirmExport: $showConfirmExport,
                confirmTitle: confirmTitle,
                confirmMessage: confirmMessage,
                onConfirmExport: confirmAndStartRender,
                showProgressSheet: $showProgressSheet,
                renderProgress: $renderProgress,
                onCancelRender: { renderTask?.cancel() },
                renderError: renderError,
                showRenderError: $showRenderError
            ))
            .onChange(of: selectedProject?.id) { _, newId in
                handleSelection(projectId: newId)
            }
            .onDisappear {
                Task { await runtime.stop() }
            }
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
            ForEach(projects) { project in
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
                    Button("Rename") {
                        renameText = project.name
                        renamingProject = project
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        deleteProject(project)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .navigationTitle("Remotion Projects")
        .toolbar {
            ToolbarItem {
                Button(action: addProject) {
                    Label("New Project", systemImage: "plus")
                }
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

    @ViewBuilder
    private func leftPanel(project: RemotionProject) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $leftTab) {
                Text("Form").tag(LeftTab.form)
                Text("Chat").tag(LeftTab.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch leftTab {
            case .form:
                RemotionParametersView(
                    project: project,
                    statusMessage: $statusMessage,
                    isSeeding: $isSeeding
                )
            case .chat:
                RemotionChatView(project: project, reloadToken: $reloadToken)
            }
        }
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
                    Text("Click \"Generate Initial Composition\" in the Form tab to start the Studio preview.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Actions

    private func addProject() {
        let project = RemotionProject(name: "Untitled Video")
        modelContext.insert(project)
        selectedProject = project
    }

    private func deleteProject(_ project: RemotionProject) {
        if selectedProject?.id == project.id {
            selectedProject = nil
            Task { await runtime.stop() }
        }
        for path in project.imagePaths {
            FileStorage.deleteFile(at: path)
        }
        if let p = project.referenceImagePath { FileStorage.deleteFile(at: p) }
        if let m = project.musicFilePath { FileStorage.deleteFile(at: m) }
        let dir = FileStorage.remotionProjectDir(id: project.id)
        try? FileManager.default.removeItem(at: dir)
        modelContext.delete(project)
    }

    private func handleSelection(projectId: UUID?) {
        guard let id = projectId else {
            Task { await runtime.stop() }
            return
        }
        guard let project = projects.first(where: { $0.id == id }),
              !project.compositionSource.isEmpty else {
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
                try await runtime.start(projectId: id)
                reloadToken += 1
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func defaultRenderFilename(for project: RemotionProject) -> String {
        let base = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "video.mp4" : "\(base).mp4"
    }

    private func defaultDestinationURL(for project: RemotionProject) -> URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent(defaultRenderFilename(for: project))
    }

    private func beginExport(project: RemotionProject) {
        guard !showProgressSheet else { return }
        pendingProjectId = project.id
        let res = ExportResolution.allCases.first(where: {
            $0.size.width == project.compositionWidth &&
            $0.size.height == project.compositionHeight
        }) ?? .p1080
        let fps = ExportFrameRate(rawValue: project.compositionFps) ?? .fps30
        exportOptions = RemotionExportOptions(
            resolution: res,
            frameRate: fps,
            destination: defaultDestinationURL(for: project)
        )
        showExportSheet = true
    }

    private var confirmTitle: String {
        guard let opts = exportOptions else { return "Render?" }
        return "Render at \(opts.resolution.shortLabel) @ \(opts.frameRate.rawValue)fps?"
    }

    private var confirmMessage: String {
        guard let opts = exportOptions else { return "" }
        return "Saving to \(opts.destination.path). This may take several minutes."
    }

    private func startRender(project: RemotionProject, options: RemotionExportOptions) {
        renderError = nil
        renderProgress = RenderProgress(stage: .starting, fraction: nil, detail: nil)
        showProgressSheet = true

        let projectId = project.id
        let dest = options.destination
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
                try await RemotionRenderer.render(
                    projectId: projectId,
                    to: dest,
                    width: w,
                    height: h,
                    fps: fps
                ) { p in
                    renderProgress = p
                }

                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }

                if selectedProject?.id == projectId {
                    do {
                        try await runtime.start(projectId: projectId)
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
    let sourceProjectId: UUID?
    let sourceRefreshToken: Int

    @Binding var showExportSheet: Bool
    @Binding var exportOptions: RemotionExportOptions?
    let projectName: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFps: Int

    @Binding var showConfirmExport: Bool
    let confirmTitle: String
    let confirmMessage: String
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
                if let id = sourceProjectId {
                    RemotionSourceSheetView(
                        projectId: id,
                        refreshToken: sourceRefreshToken
                    ) {
                        showSourceSheet = false
                    }
                }
            }
            .sheet(isPresented: $showExportSheet) {
                exportSheet
            }
            .confirmationDialog(
                confirmTitle,
                isPresented: $showConfirmExport,
                titleVisibility: .visible
            ) {
                Button("Render Now") { onConfirmExport() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
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
                    get: { exportOptions ?? RemotionExportOptions(destination: URL(fileURLWithPath: "/")) },
                    set: { exportOptions = $0 }
                ),
                onCancel: { showExportSheet = false },
                onExport: {
                    showExportSheet = false
                    showConfirmExport = true
                }
            )
        }
    }
}
#endif
