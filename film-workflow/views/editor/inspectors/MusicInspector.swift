import SwiftData
import SwiftUI

/// Generate button and prompt preview for a music project, shown under every
/// one of its inspector tabs.
struct MusicInspectorFooter: View {
    let project: MusicProject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage

    @State private var isGenerating = false
    @State private var showPromptSheet = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var insufficientCredits: InsufficientCreditsNotice?

    var body: some View {
        GenerateButton(title: "Generate", isBusy: isGenerating, isEnabled: true, tip: FilmWorkflowTips.GenerateMusicTip()) {
            showPromptSheet = true
        }
        .padding(10)
        .alert("Error", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "An unknown error occurred.") }
        .insufficientCreditsAlert($insufficientCredits)
        .sheet(isPresented: $showPromptSheet) { promptPreviewSheet }
    }

    @ViewBuilder
    private var promptPreviewSheet: some View {
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
                        Text("Reference Images (\(project.referenceImagePaths.count))").font(.subheadline.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(project.referenceImagePaths.enumerated()), id: \.offset) { _, path in
                                    if let image = Image(contentsOfFile: storage.absoluteURL(for: path)) {
                                        image.resizable().aspectRatio(contentMode: .fill)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPromptSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showPromptSheet = false
                        Task { await generate() }
                    } label: { Label("Start Generation", systemImage: "wand.and.stars") }
                    .disabled(isGenerating)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let config = try AppConfig.loadFromKeychain()
            try await MusicGenerationService.generate(project: project, context: modelContext, config: config)
        } catch {
            if let notice = InsufficientCreditsNotice(error) { insufficientCredits = notice; return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
