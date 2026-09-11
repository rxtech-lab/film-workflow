import SwiftData
import SwiftUI

/// Generate and Resume for a video project, with the pending-job banner,
/// shown under its inspector tabs.
struct VideoInspectorFooter: View {
    let project: VideoGenProject
    @Environment(\.modelContext) private var modelContext

    @State private var generateTask: Task<Void, Never>?
    @State private var progress: VideoGenProgress = .submitting
    @State private var showProgressSheet = false
    @State private var showResumeChoice = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var isGenerating: Bool { generateTask != nil }

    private var canGenerate: Bool {
        guard !project.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !project.googleModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.hasPendingJob, !isGenerating {
                HStack {
                    Label("A generation is still running at the provider.", systemImage: "clock.arrow.2.circlepath")
                        .font(.caption)
                    Spacer()
                    Button("Resume") { startResume() }.controlSize(.small)
                }
                .padding(8)
                .background(.yellow.opacity(0.15))
            }
            GenerateButton(title: "Generate", isBusy: isGenerating, isEnabled: canGenerate) { startGenerate() }
                .padding(10)
        }
        .alert("Error", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "An unknown error occurred.") }
        .confirmationDialog("This project already has a generation running.", isPresented: $showResumeChoice, titleVisibility: .visible) {
            Button("Resume It") { startResume() }
            Button("Start a New One") {
                VideoGenerationService.abandonPendingJob(project, context: modelContext)
                startGenerate(force: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starting a new generation abandons the running one — the provider may still bill it.")
        }
        .sheet(isPresented: $showProgressSheet) {
            VideoGenProgressSheet(projectName: project.name, progress: $progress) { generateTask?.cancel() }
        }
    }

    private func startGenerate(force: Bool = false) {
        guard generateTask == nil else { return }
        if project.hasPendingJob, !force { showResumeChoice = true; return }
        run { config, onProgress in
            try await VideoGenerationService.generate(project: project, context: modelContext, config: config, onProgress: onProgress)
        }
    }

    private func startResume() {
        guard generateTask == nil else { return }
        run { config, onProgress in
            try await VideoGenerationService.resume(project: project, context: modelContext, config: config, onProgress: onProgress)
        }
    }

    private func run(work: @escaping @MainActor (AppConfig, @escaping VideoProgressHandler) async throws -> Any?) {
        progress = .submitting
        showProgressSheet = true
        generateTask = Task { @MainActor in
            defer { showProgressSheet = false; generateTask = nil }
            do {
                let config = try AppConfig.loadFromKeychain()
                _ = try await work(config) { update in progress = update }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
