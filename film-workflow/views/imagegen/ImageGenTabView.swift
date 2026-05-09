import SwiftData
import SwiftUI

struct ImageGenTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \ImageGenProject.updatedAt, order: .reverse) private var projects: [ImageGenProject]
    @State private var selectedProject: ImageGenProject?
    @State private var renamingProject: ImageGenProject?
    @State private var renameText: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showError = false
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
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Button(action: addProject) {
                    Label("New Project", systemImage: "plus")
                }
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
    }

    // MARK: - Actions

    private func addProject() {
        let project = ImageGenProject(name: "Untitled Project")
        modelContext.insert(project)
        selectedProject = project
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
        return true
    }

    @MainActor
    private func generate(project: ImageGenProject) async {
        isGenerating = true
        defer { isGenerating = false }

        do {
            let config = try AppConfig.loadFromKeychain()

            let result: ImageGenResult
            if project.providerEnum == .google {
                guard !config.googleAIKey.isEmpty else {
                    throw ImageGenError.missingConfig
                }
                result = try await ImageGenClient.generateGoogle(
                    prompt: project.prompt,
                    aspectRatio: project.googleAspectRatioEnum,
                    resolution: project.googleResolutionEnum,
                    apiKey: config.googleAIKey
                )
            } else {
                guard !config.openAIEndpoint.isEmpty,
                      !config.openAIKey.isEmpty,
                      !project.openAIModel.isEmpty else {
                    throw ImageGenError.missingConfig
                }
                let modelHasGoogle = project.openAIModel.lowercased().contains("google")
                if modelHasGoogle {
                    result = try await ImageGenClient.generateOpenAI(
                        prompt: project.prompt,
                        model: project.openAIModel,
                        endpoint: config.openAIEndpoint,
                        apiKey: config.openAIKey,
                        aspectRatio: project.googleAspectRatioEnum,
                        resolution: project.googleResolutionEnum
                    )
                } else {
                    let customSize: String? = project.openAISizeEnum == .custom
                        ? "\(project.openAICustomWidth)x\(project.openAICustomHeight)"
                        : nil
                    result = try await ImageGenClient.generateOpenAI(
                        prompt: project.prompt,
                        model: project.openAIModel,
                        endpoint: config.openAIEndpoint,
                        apiKey: config.openAIKey,
                        size: project.openAISizeEnum,
                        customSize: customSize,
                        quality: project.openAIQualityEnum,
                        format: project.openAIFormatEnum,
                        compression: project.openAICompression,
                        background: project.openAIBackgroundEnum,
                        transparent: project.openAITransparent
                    )
                }
            }

            let relativePath = try FileStorage.saveImage(result.imageData, fileExtension: result.fileExtension)
            let generated = GeneratedImage(
                imageFilePath: relativePath,
                prompt: project.prompt,
                project: project
            )
            modelContext.insert(generated)
            project.updatedAt = Date()
        } catch {
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
