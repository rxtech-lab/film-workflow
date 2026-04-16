import SwiftData
import SwiftUI

struct MusicTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \MusicProject.updatedAt, order: .reverse) private var projects: [MusicProject]
    @State private var selectedProject: MusicProject?
    @State private var renamingProject: MusicProject?
    @State private var renameText: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showError = false
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
                        .padding()
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

    private func addProject() {
        let project = MusicProject(name: "Untitled Project")
        modelContext.insert(project)
        selectedProject = project
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
            let basePrompt = PromptBuilder.build(from: project)
            let prompt = project.inputModeEnum == .prompt
                ? basePrompt + "\n\nAdditional instructions:\n" + project.promptText
                : basePrompt

            var imageDataPairs: [(mimeType: String, base64: String)] = []
            for path in project.referenceImagePaths {
                let url = FileStorage.absoluteURL(for: path)
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mimeType = ext == "png" ? "image/png" : "image/jpeg"
                imageDataPairs.append((mimeType: mimeType, base64: data.base64EncodedString()))
            }

            let response = try await LyriaClient.generate(
                prompt: prompt,
                imageDataPairs: imageDataPairs,
                apiKey: config.googleAIKey
            )

            let ext: String
            switch response.mimeType {
            case "audio/wav": ext = "wav"
            case "audio/mp3", "audio/mpeg": ext = "mp3"
            default: ext = "wav"
            }

            let relativePath = try FileStorage.saveAudio(response.audioData, extension: ext)

            let generatedFile = GeneratedMusic(
                audioFilePath: relativePath,
                lyricsText: response.lyricsText,
                project: project
            )
            modelContext.insert(generatedFile)
            project.updatedAt = Date()

        } catch {
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
                    Text(pane.rawValue).tag(pane)
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
                        SongStructureEditorView(entries: $project.songStructureEntries)
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
