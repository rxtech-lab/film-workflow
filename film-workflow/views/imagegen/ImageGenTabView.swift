import SwiftData
import SwiftUI

struct ImageGenTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \ImageGenProject.updatedAt, order: .reverse) private var projects: [ImageGenProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @State private var selectedProject: ImageGenProject?
    @State private var renamingProject: ImageGenProject?
    @State private var pendingProjectDeletion: ImageGenProject?
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
    @State private var showHistorySheet = false

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

    private func projectRow(_ project: ImageGenProject) -> some View {
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
            systemImage: "photo.on.rectangle.angled",
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
                        ImageGenDetailPane(
                            project: project,
                            isGenerating: isGenerating,
                            onGenerate: { Task { await generate(project: project) } },
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
                        ImageGenProjectParametersView(project: project)
                    } else {
                        placeholder
                    }
                } detail: {
                    if let project = selectedProject {
                        GeneratedImageListView(files: project.generatedFiles) { file in
                            deleteImage(file, project: project)
                        }
                        .navigationTitle(project.name)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .publishesAgentTarget(kind: .imageGen, projectUUID: selectedProject.map(MCPProjectHandlers.stableID))
        .toolbar {
            if let project = selectedProject, !isCompact {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await generate(project: project) }
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
        .insufficientCreditsAlert($insufficientCredits)
        .sheet(isPresented: $showHistorySheet) {
            if let project = selectedProject {
                NavigationStack {
                    GeneratedImageListView(files: project.generatedFiles) { file in
                        deleteImage(file, project: project)
                    }
                    .navigationTitle("Generated Images")
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
            "Delete this image project?",
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
            Text("\"\(project.name)\" and its generated images will be permanently deleted.")
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
        let project = ImageGenProject(name: "Untitled Project")
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

    private func moveProject(_ project: ImageGenProject, to groupID: UUID?) {
        do {
            try ProjectGroupService.move(project, to: groupID, context: modelContext)
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: ImageGenProject) {
        if selectedProject == project {
            selectedProject = nil
        }
        for file in project.generatedFiles {
            FileStorage.deleteFile(at: file.imageFilePath)
        }
        modelContext.delete(project)
    }

    private func deleteImage(_ file: GeneratedImage, project: ImageGenProject) {
        FileStorage.deleteFile(at: file.imageFilePath)
        modelContext.delete(file)
        project.updatedAt = Date()
    }

    private func canGenerate(_ project: ImageGenProject) -> Bool {
        guard !project.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if project.providerEnum == .openai && project.openAIModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if project.providerEnum == .google && project.googleModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    @MainActor
    private func generate(project: ImageGenProject) async {
        isGenerating = true
        defer { isGenerating = false }

        do {
            let config = try AppConfig.loadFromKeychain()
            try await ImageGenerationService.generate(
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

private struct ImageGenDetailPane: View {
    @Bindable var project: ImageGenProject
    var isGenerating: Bool
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
                    ImageGenProjectParametersView(project: project)
                case .history:
                    GeneratedImageListView(files: project.generatedFiles) { _ in }
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
