import SwiftUI

/// Modal progress shown while Azure narration audio is synthesized in batches and stitched.
struct NarrativeGenerationProgressView: View {
    let progress: NarrativeGenerationProgress
    /// Cancels the in-flight generation. When nil, the cancel button is hidden.
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail = parallelDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            progressBar

            if let onCancel {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: 360)
        #if os(macOS)
            .frame(minWidth: 340)
        #endif
    }

    @ViewBuilder
    private var progressBar: some View {
        switch progress {
        case let .synthesizing(completed, total, _) where total > 0:
            ProgressView(value: Double(completed), total: Double(total))
                .progressViewStyle(.linear)
        case .synthesizing, .stitching:
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var title: String {
        switch progress {
        case .synthesizing: return "Generating Audio"
        case .stitching: return "Stitching Audio"
        }
    }

    private var subtitle: String {
        switch progress {
        case let .synthesizing(completed, total, inFlight):
            // Show the highest chunk currently being worked on (completed + the ones in flight), so a
            // run with 4 parallel requests reads "Chunk 4 of 13" up front rather than crawling 1→2→3.
            let working = min(completed + inFlight, max(total, 1))
            return "Chunk \(working) of \(total)"
        case .stitching:
            return "Combining the chunks into one file…"
        }
    }

    private var parallelDetail: String? {
        switch progress {
        case let .synthesizing(completed, _, inFlight) where inFlight > 0:
            return "\(completed) done · \(inFlight) generating in parallel"
        case .synthesizing, .stitching:
            return nil
        }
    }
}
