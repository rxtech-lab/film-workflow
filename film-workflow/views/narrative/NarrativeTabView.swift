import SwiftData
import SwiftUI

struct NarrativeTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \NarrativeProject.updatedAt, order: .reverse) private var projects:
        [NarrativeProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @State private var selectedProject: NarrativeProject?
    @State private var renamingProject: NarrativeProject?
    @State private var pendingProjectDeletion: NarrativeProject?
    @State private var renameText: String = ""
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName: String = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isGenerating = false
    @State private var generationProgress: NarrativeGenerationProgress?
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var insufficientCredits: InsufficientCreditsNotice?
    @State private var showGeneratedSheet = false
    @State private var showPromptSheet = false

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
        .accountSidebarFooter()
        .navigationTitle("Narratives")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { addProject() }) {
                    Label("New Narrative", systemImage: "plus")
                }
                Button(action: beginCreatingGroup) {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private func projectRow(_ project: NarrativeProject) -> some View {
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
            "Select a Narrative",
            systemImage: "text.book.closed",
            description: Text("Choose a narrative from the sidebar or create a new one.")
        )
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let project = selectedProject {
                        NarrativeProjectDetailPanes(
                            project: project,
                            canGenerate: canGenerate(project),
                            isGenerating: isGenerating,
                            onGenerate: { showPromptSheet = true },
                            onShowHistory: { showGeneratedSheet = true }
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
                        NarrativeProjectParametersView(project: project)
                    } else {
                        ContentUnavailableView(
                            "Select a Narrative",
                            systemImage: "text.book.closed",
                            description: Text("Choose a narrative from the sidebar.")
                        )
                    }
                } detail: {
                    if let project = selectedProject {
                        TranscriptEditorView(project: project)
                            .navigationTitle(project.name)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .publishesAgentTarget(kind: .narrative, projectUUID: selectedProject.map(MCPProjectHandlers.stableID))
        .toolbar {
            if let project = selectedProject, !isCompact {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPromptSheet = true
                    } label: {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isGenerating || !canGenerate(project))
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showGeneratedSheet = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .badge(project.generatedFiles.count)
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .insufficientCreditsAlert($insufficientCredits)
        .sheet(isPresented: $showGeneratedSheet) {
            if let project = selectedProject {
                #if os(macOS)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Generated Narratives")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        GeneratedNarrativeListView(files: project.generatedFiles)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        Divider()

                        HStack {
                            Spacer()
                            Button("Done") { showGeneratedSheet = false }
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .frame(minWidth: 700, minHeight: 400, maxHeight: 600)
                #else
                    NavigationStack {
                        GeneratedNarrativeListView(files: project.generatedFiles)
                            .navigationTitle("Generated Narratives")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showGeneratedSheet = false
                                    }
                                }
                            }
                    }
                #endif
            }
        }
        .sheet(isPresented: $showPromptSheet) {
            if let project = selectedProject {
                PromptPreviewSheet(
                    project: project,
                    isGenerating: isGenerating,
                    canGenerate: canGenerate(project),
                    onCancel: { showPromptSheet = false },
                    onStart: {
                        showPromptSheet = false
                        generationTask = Task { await generate(project: project) }
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { generationProgress != nil },
            set: { if !$0 { generationProgress = nil } }
        )) {
            // Content is re-evaluated as `generationProgress` advances, so the dialog updates
            // live (chunk N of M → stitching) while staying presented.
            if let progress = generationProgress {
                NarrativeGenerationProgressView(progress: progress) {
                    generationTask?.cancel()
                }
                .interactiveDismissDisabled()
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
            "Delete this narrative project?",
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
            Text("\"\(project.name)\" and its generated audio will be permanently deleted.")
        }
        .projectGroupDialogs(
            editor: $groupEditor,
            name: $groupName,
            pendingDeletion: $pendingGroupDeletion,
            errorMessage: $groupErrorMessage
        )
    }

    // MARK: - Helpers

    private func canGenerate(_ project: NarrativeProject) -> Bool {
        guard project.providerEnum.isSupported else { return false }
        guard !project.speakers.isEmpty else { return false }
        return project.paragraphs.contains {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Actions

    private func addProject(groupID: UUID? = nil) {
        let project = NarrativeProject(name: "Untitled Narrative")
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

    private func moveProject(_ project: NarrativeProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: NarrativeProject) {
        if selectedProject == project {
            selectedProject = nil
        }
        for file in project.generatedFiles {
            FileStorage.deleteFile(at: file.audioFilePath)
        }
        modelContext.delete(project)
    }

    private func generate(project: NarrativeProject) async {
        isGenerating = true
        defer {
            isGenerating = false
            generationProgress = nil
            generationTask = nil
        }

        do {
            let config = try AppConfig.loadFromKeychain()
            try await NarrativeGenerationService.generate(
                project: project,
                context: modelContext,
                config: config,
                onProgress: { progress in
                    generationProgress = progress
                }
            )
        } catch is CancellationError {
            // User cancelled — silently dismiss without an error alert.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // In-flight URLSession requests surface cancellation as URLError.cancelled.
        } catch {
            if let notice = InsufficientCreditsNotice(error) {
                insufficientCredits = notice
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

}

/// Prompt/SSML preview shown before generation. Builds the preview **off the main actor** and shows a
/// progress indicator while it does, so opening this sheet for a long transcript no longer freezes the
/// UI (the old synchronous build inside the view body was the freeze on tapping "Generate").
private struct PromptPreviewSheet: View {
    let project: NarrativeProject
    let isGenerating: Bool
    let canGenerate: Bool
    let onCancel: () -> Void
    let onStart: () -> Void

    @State private var transcript: String?
    @State private var didTruncate = false

    /// Cap the *displayed* text — SwiftUI's text layout chokes on very large strings even off-main.
    /// The full transcript is still what gets synthesized; this only limits the preview.
    private let displayLimit = 12_000

    private var title: String {
        switch project.providerEnum {
        case .gemini: return "Transcript Preview"
        case .azure: return "SSML Preview"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let transcript {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if didTruncate {
                                Text("Preview truncated for display. The full transcript will still be generated.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(transcript)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Building preview…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onStart) {
                        Label("Start Generation", systemImage: "wand.and.stars")
                    }
                    .disabled(isGenerating || !canGenerate)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
        #endif
        .task {
            // Snapshot the main-actor model, then build the preview off-main (see NarrativePreviewBuilder).
            let provider = project.providerEnum
            let speakers = project.speakers
            let paragraphs = project.paragraphs
            let scene = project.sceneDescription
            let notes = project.notes
            let context = project.context

            let full = await NarrativePreviewBuilder.build(
                provider: provider,
                speakers: speakers,
                paragraphs: paragraphs,
                scene: scene,
                notes: notes,
                context: context
            )
            if full.count > displayLimit {
                transcript = String(full.prefix(displayLimit))
                didTruncate = true
            } else {
                transcript = full
                didTruncate = false
            }
        }
    }
}

struct NarrativeProjectDetailPanes: View {
    @Bindable var project: NarrativeProject
    var canGenerate: Bool
    var isGenerating: Bool
    var onGenerate: () -> Void
    var onShowHistory: () -> Void

    @State private var selectedPane: Pane = .parameters

    enum Pane: String, CaseIterable, Identifiable {
        case parameters = "Parameters"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    NarrativeProjectParametersView(project: project)
                case .transcript:
                    TranscriptEditorView(project: project)
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
                .disabled(isGenerating || !canGenerate)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onShowHistory) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .badge(project.generatedFiles.count)
            }
        }
    }
}
