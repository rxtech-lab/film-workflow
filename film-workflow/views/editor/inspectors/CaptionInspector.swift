import SwiftData
import SwiftUI

/// Transcribe button, progress sheet and confirmations for a caption project,
/// shown under every one of its inspector tabs. While a transcription runs the
/// project is marked busy on the window state so the Settings tab can lock
/// its controls.
struct CaptionInspectorFooter: View {
    let project: CaptionProject
    let state: EditorWindowState
    @Environment(\.modelContext) private var modelContext

    @State private var isTranscribing = false
    @State private var progress: CaptionProgress?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var insufficientCredits: InsufficientCreditsNotice?
    @State private var unavailableModel: UnavailableModelNotice?
    @State private var successNotice: String?
    @State private var confirmRetranscribe = false

    var body: some View {
        GenerateButton(title: project.activeSegmentCount > 0 ? "Re-transcribe" : "Transcribe",
                       isBusy: isTranscribing, isEnabled: project.hasAudio,
                       tip: FilmWorkflowTips.TranscribeTip()) {
            requestTranscribe()
        }
        .padding(10)
        .help(project.hasAudio ? "Transcribe this audio into captions" : "Choose an audio file or a narration first")
        .sheet(isPresented: $isTranscribing) {
            CaptionTranscriptionProgressView(progress: progress) { transcriptionTask?.cancel() }
        }
        .alert("Error", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "An unknown error occurred.") }
        .insufficientCreditsAlert($insufficientCredits)
        .unavailableModelAlert($unavailableModel)
        .alert("Captions ready", isPresented: Binding(get: { successNotice != nil }, set: { if !$0 { successNotice = nil } })) {
            Button("OK") { successNotice = nil }
        } message: { Text(successNotice ?? "") }
        .confirmationDialog("Re-transcribe these captions?", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("Re-transcribe") { transcribe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates version \(project.nextVersionNumber). The current version and its translations are kept, and translations carry over for captions that come out unchanged.")
        }
    }

    private func requestTranscribe() {
        guard !isTranscribing else { return }
        if project.activeSegmentCount > 0 { confirmRetranscribe = true } else { transcribe() }
    }

    private func transcribe() {
        guard !isTranscribing else { return }
        isTranscribing = true
        progress = nil
        // Marked on the window state, not this view's state, so the flag
        // clears even if the selection has moved on before the work ends.
        let item = project.libraryItemID
        state.busyItems.insert(item)
        transcriptionTask = Task {
            defer { isTranscribing = false; progress = nil; transcriptionTask = nil; state.busyItems.remove(item) }
            do {
                let config = try AppConfig.loadFromKeychain()
                let count: Int
                if project.isNarrativeSourced {
                    count = try await CaptionTranscriptionService.alignNarrative(project: project, context: modelContext, config: config) { progress = $0 }
                } else {
                    count = try await CaptionTranscriptionService.transcribe(project: project, context: modelContext, config: config) { progress = $0 }
                }
                successNotice = "Created \(count) caption\(count == 1 ? "" : "s")."
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if let notice = InsufficientCreditsNotice(error) { insufficientCredits = notice; return }
                // A stale saved model needs the picker, not a retry.
                if let notice = UnavailableModelNotice(error) { unavailableModel = notice; return }
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
