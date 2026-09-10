import SwiftData
import SwiftUI

struct NarrationInspector: View {
    let project: NarrativeProject
    @Environment(\.modelContext) private var modelContext

    @State private var isGenerating = false
    @State private var showPromptSheet = false
    @State private var generationProgress: NarrativeGenerationProgress?
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var insufficientCredits: InsufficientCreditsNotice?

    private var canGenerate: Bool {
        guard project.providerEnum.isSupported, !project.speakers.isEmpty else { return false }
        return project.paragraphs.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        InspectorLayout(versionsTitle: "Versions", versionCount: project.generatedFiles.count) {
            VStack(spacing: 0) {
                NarrativeProjectParametersView(project: project)
                Divider()
                GenerateButton(title: "Generate", isBusy: isGenerating, isEnabled: canGenerate) { showPromptSheet = true }
                    .padding(10)
            }
        } versions: {
            GeneratedNarrativeListView(files: project.generatedFiles)
        }
        .alert("Error", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "An unknown error occurred.") }
        .insufficientCreditsAlert($insufficientCredits)
        .sheet(isPresented: $showPromptSheet) {
            NarrativePromptPreviewSheet(project: project, isGenerating: isGenerating, canGenerate: canGenerate,
                                        onCancel: { showPromptSheet = false },
                                        onStart: {
                                            showPromptSheet = false
                                            generationTask = Task { await generate() }
                                        })
        }
        .sheet(isPresented: Binding(get: { generationProgress != nil }, set: { if !$0 { generationProgress = nil } })) {
            if let progress = generationProgress {
                NarrativeGenerationProgressView(progress: progress) { generationTask?.cancel() }
            }
        }
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false; generationProgress = nil; generationTask = nil }
        do {
            let config = try AppConfig.loadFromKeychain()
            try await NarrativeGenerationService.generate(project: project, context: modelContext, config: config) { generationProgress = $0 }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            if let notice = InsufficientCreditsNotice(error) { insufficientCredits = notice; return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Prompt/SSML preview shown before generation, built off the main actor.
struct NarrativePromptPreviewSheet: View {
    let project: NarrativeProject
    let isGenerating: Bool
    let canGenerate: Bool
    let onCancel: () -> Void
    let onStart: () -> Void

    @State private var transcript: String?
    @State private var didTruncate = false
    private let displayLimit = 12_000

    var body: some View {
        NavigationStack {
            Group {
                if let transcript {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if didTruncate {
                                Text("Preview truncated for display. The full transcript will still be generated.")
                                    .font(.caption).foregroundStyle(.secondary)
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
                        Text("Building preview…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(project.providerEnum == .azure ? "SSML Preview" : "Transcript Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onStart) { Label("Start Generation", systemImage: "wand.and.stars") }
                        .disabled(isGenerating || !canGenerate)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            let full = await NarrativePreviewBuilder.build(
                provider: project.providerEnum, speakers: project.speakers, paragraphs: project.paragraphs,
                scene: project.sceneDescription, notes: project.notes, context: project.context
            )
            if full.count > displayLimit {
                transcript = String(full.prefix(displayLimit)); didTruncate = true
            } else {
                transcript = full; didTruncate = false
            }
        }
    }
}
