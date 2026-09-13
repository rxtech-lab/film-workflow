import SwiftData
import SwiftUI

/// Generate button for an image project, shown under its inspector tabs.
struct ImageInspectorFooter: View {
    let project: ImageGenProject
    @Environment(\.modelContext) private var modelContext

    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var insufficientCredits: InsufficientCreditsNotice?
    @State private var subscriptionImageModel = ""

    private var canGenerate: Bool {
        guard !project.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !project.subscriptionModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !subscriptionImageModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GenerateButton(title: "Generate", isBusy: isGenerating, isEnabled: canGenerate) { Task { await generate() } }
            .padding(10)
            .onAppear {
                subscriptionImageModel = (try? AppConfig.loadFromKeychain())?.subscriptionImageModel ?? ""
            }
            .alert("Error", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "An unknown error occurred.") }
            .insufficientCreditsAlert($insufficientCredits)
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let config = try AppConfig.loadFromKeychain()
            try await ImageGenerationService.generate(project: project, context: modelContext, config: config)
        } catch {
            if let notice = InsufficientCreditsNotice(error) { insufficientCredits = notice; return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
