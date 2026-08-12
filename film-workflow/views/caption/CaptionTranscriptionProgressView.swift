import SwiftUI

/// Non-dismissable progress sheet for a transcription run.
///
/// Same shape as `NarrativeGenerationProgressView`: a run can take minutes, so
/// the sheet can't be dismissed by accident, and Cancel is always available.
struct CaptionTranscriptionProgressView: View {
    let progress: CaptionProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let progress {
                Text(progress.title)
                    .font(.headline)

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                }

                if !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Starting…")
                    .font(.headline)
                ProgressView()
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(minWidth: 380)
        .interactiveDismissDisabled()
    }
}
