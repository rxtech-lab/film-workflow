import SwiftData
import SwiftUI
import TipKit

struct MusicTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \MusicProject.updatedAt, order: .reverse) private var projects: [MusicProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @State private var selectedProject: MusicProject?
    @State private var renamingProject: MusicProject?
    @State private var pendingProjectDeletion: MusicProject?
    @State private var renameText: String = ""
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName: String = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isGenerating = false
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

    private func projectRow(_ project: MusicProject) -> some View {
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
            "Select a Project",
            systemImage: "music.note",
            description: Text("Choose a project from the sidebar or create a new one.")
        )
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let project = selectedProject {
                        MusicProjectDetailPanes(
                            project: project,
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
                        MusicProjectParametersView(project: project)
                    } else {
                        ContentUnavailableView(
                            "Select a Project",
                            systemImage: "music.note",
                            description: Text("Choose a project from the sidebar.")
                        )
                    }
                } detail: {
                    if let project = selectedProject {
                        MusicProjectEditorView(project: project)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .publishesAgentTarget(kind: .music, projectUUID: selectedProject.map(MCPProjectHandlers.stableID))
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
                    .disabled(isGenerating)
                    .popoverTip(FilmWorkflowTips.GenerateMusicTip(), arrowEdge: .top)
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
                NavigationStack {
                    GeneratedMusicListView(files: project.generatedFiles)
                        .formStyle(.grouped)
                        .navigationTitle("Generated Music")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showGeneratedSheet = false
                                }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 700, minHeight: 400, maxHeight: 600)
                #endif
            }
        }
        .sheet(isPresented: $showPromptSheet) {
            if let project = selectedProject {
                promptPreviewSheet(for: project)
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
            "Delete this music project?",
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
            Text("\"\(project.name)\" and its generated audio and reference files will be permanently deleted.")
        }
        .projectGroupDialogs(
            editor: $groupEditor,
            name: $groupName,
            pendingDeletion: $pendingGroupDeletion,
            errorMessage: $groupErrorMessage
        )
    }

    // MARK: - Prompt Preview

    @ViewBuilder
    private func promptPreviewSheet(for project: MusicProject) -> some View {
        let basePrompt = PromptBuilder.build(from: project)
        let prompt = project.inputModeEnum == .prompt
            ? basePrompt + "\n\nAdditional instructions:\n" + project.promptText
            : basePrompt

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !project.referenceImagePaths.isEmpty {
                        Divider()

                        Text("Reference Images (\(project.referenceImagePaths.count))")
                            .font(.subheadline.bold())

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(project.referenceImagePaths.enumerated()), id: \.offset) { _, path in
                                    let url = FileStorage.absoluteURL(for: path)
                                    if let image = Image(contentsOfFile: url) {
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Prompt Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showPromptSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showPromptSheet = false
                        Task { await generate(project: project) }
                    } label: {
                        Label("Start Generation", systemImage: "wand.and.stars")
                    }
                    .disabled(isGenerating)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    // MARK: - Actions

    private func addProject(groupID: UUID? = nil) {
        let project = MusicProject(name: "Untitled Project")
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

    private func moveProject(_ project: MusicProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: MusicProject) {
        if selectedProject == project {
            selectedProject = nil
        }
        for file in project.generatedFiles {
            FileStorage.deleteFile(at: file.audioFilePath)
        }
        for path in project.referenceImagePaths {
            FileStorage.deleteFile(at: path)
        }
        modelContext.delete(project)
    }

    private func generate(project: MusicProject) async {
        isGenerating = true
        defer { isGenerating = false }

        do {
            let config = try AppConfig.loadFromKeychain()
            try await MusicGenerationService.generate(
                project: project,
                context: modelContext,
                config: config
            )
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

struct MusicProjectDetailPanes: View {
    @Bindable var project: MusicProject
    var isGenerating: Bool
    var onGenerate: () -> Void
    var onShowHistory: () -> Void

    @State private var selectedPane: Pane = .parameters

    enum Pane: String, CaseIterable, Identifiable {
        case parameters = "Parameters"
        case structure = "Structure"
        case lyrics = "Lyrics"
        case prompt = "Prompt"
        var id: String { rawValue }
    }

    private var availablePanes: [Pane] {
        var panes: [Pane] = [.parameters]
        if project.inputModeEnum == .prompt {
            panes.append(.prompt)
        } else {
            panes.append(.structure)
            if project.generationTypeEnum == .withLyrics {
                panes.append(.lyrics)
            }
        }
        return panes
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedPane) {
                ForEach(availablePanes) { pane in
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
                    MusicProjectParametersView(project: project)
                case .structure:
                    ScrollView {
                        SongStructureEditorView(
                            entries: $project.songStructureEntries,
                            duration: TimeInterval(project.musicLengthEnum.seconds)
                        )
                        .padding()
                    }
                case .lyrics:
                    ScrollView {
                        LyricsEditorView(entries: $project.lyricEntries)
                            .padding()
                    }
                case .prompt:
                    TextEditor(text: $project.promptText)
                        .font(.body)
                        .padding(8)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onChange(of: availablePanes) { _, newPanes in
                if !newPanes.contains(selectedPane) {
                    selectedPane = newPanes.first ?? .parameters
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onGenerate) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isGenerating)
                    .popoverTip(FilmWorkflowTips.GenerateMusicTip(), arrowEdge: .top)
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

struct RenameSheet: View {
    @Binding var name: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Project")
                .font(.headline)

            TextField("Project Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
