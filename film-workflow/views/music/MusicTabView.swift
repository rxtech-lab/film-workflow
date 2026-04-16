import SwiftData
import SwiftUI

struct MusicTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MusicProject.updatedAt, order: .reverse) private var projects: [MusicProject]
    @State private var selectedProject: MusicProject?
    @State private var renamingProject: MusicProject?
    @State private var renameText: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showGeneratedSheet = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "music.note",
                    description: Text("Choose a project from the sidebar or create a new one.")
                )
            }
        }
        .toolbar {
            if let project = selectedProject {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await generate(project: project) }
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
                .frame(minWidth: 500, minHeight: 400)
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
