import SwiftData
import SwiftUI

struct NarrativeTabView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(sort: \NarrativeProject.updatedAt, order: .reverse) private var projects:
        [NarrativeProject]
    @State private var selectedProject: NarrativeProject?
    @State private var renamingProject: NarrativeProject?
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
        .navigationTitle("Narratives")
        .toolbar {
            ToolbarItem {
                Button(action: addProject) {
                    Label("New Narrative", systemImage: "plus")
                }
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
    private func promptPreviewSheet(for project: NarrativeProject) -> some View {
        let transcript = previewText(for: project)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(transcript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(previewTitle(for: project))
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
                    .disabled(isGenerating || !canGenerate(project))
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
        #endif
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

    private func addProject() {
        let project = NarrativeProject(name: "Untitled Narrative")
        modelContext.insert(project)
        selectedProject = project
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
        defer { isGenerating = false }

        do {
            let config = try AppConfig.loadFromKeychain()

            switch project.providerEnum {
            case .gemini:
                let transcript = NarrativePromptBuilder.build(from: project)
                let response = try await GeminiTTSClient.generate(
                    transcript: transcript,
                    speakers: project.speakers,
                    apiKey: config.googleAIKey
                )
                let relativePath = try FileStorage.saveAudio(response.audioData, extension: "wav")
                let generatedFile = GeneratedNarrative(
                    audioFilePath: relativePath,
                    transcriptText: transcript,
                    project: project,
                    providerName: project.providerEnum.displayName,
                    speakerSummary: speakerSummary(for: project)
                )
                modelContext.insert(generatedFile)

            case .azure:
                let ssml = AzureSSMLBuilder.build(from: project)
                let response = try await AzureTTSClient.generate(
                    project: project,
                    apiKey: config.azureSpeechKey,
                    endpoint: config.azureSpeechEndpoint,
                    format: project.azureOutputFormatEnum
                )
                let relativePath = try FileStorage.saveAudio(
                    response.audioData, extension: response.fileExtension)
                let generatedFile = GeneratedNarrative(
                    audioFilePath: relativePath,
                    transcriptText: ssml,
                    project: project,
                    providerName: project.providerEnum.displayName,
                    speakerSummary: speakerSummary(for: project)
                )
                modelContext.insert(generatedFile)
            }

            project.updatedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func speakerSummary(for project: NarrativeProject) -> String {
        let names = project.speakers
            .map { speaker -> String in
                let voiceName: String
                switch project.providerEnum {
                case .azure:
                    voiceName = speaker.azureVoice
                case .gemini:
                    voiceName = speaker.geminiVoice.isEmpty ? speaker.voice : speaker.geminiVoice
                }
                if voiceName.isEmpty {
                    return speaker.displayName
                }
                return "\(speaker.displayName) \(voiceName)"
            }
            .filter { !$0.isEmpty }
        return names.joined(separator: ", ")
    }

    private func previewText(for project: NarrativeProject) -> String {
        switch project.providerEnum {
        case .gemini: return NarrativePromptBuilder.build(from: project)
        case .azure: return AzureSSMLBuilder.build(from: project)
        }
    }

    private func previewTitle(for project: NarrativeProject) -> String {
        switch project.providerEnum {
        case .gemini: return "Transcript Preview"
        case .azure: return "SSML Preview"
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
