#if os(macOS)
import SwiftUI

struct RemotionRenderProgressSheet: View {
    let projectName: String
    @Binding var progress: RenderProgress
    var onCancel: () -> Void

    @State private var showCancelConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendering Video")
                        .font(.headline)
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(stageLabel)
                    .font(.subheadline.weight(.medium))

                if let f = progress.fraction {
                    ProgressView(value: f, total: 1.0)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack {
                    Text(progress.detail ?? " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let f = progress.fraction, !showsPercentInDetail {
                        Text("\(Int(f * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .destructive) {
                    showCancelConfirm = true
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(true)
        .confirmationDialog(
            "Cancel rendering?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Rendering", role: .destructive) { onCancel() }
            Button("Keep Rendering", role: .cancel) {}
        } message: {
            Text("The partial video file will be removed.")
        }
    }

    private var stageLabel: String {
        switch progress.stage {
        case .starting: return "Preparing…"
        case .bundling: return "Bundling composition…"
        case .gettingCompositions: return "Launching renderer…"
        case .rendering: return "Rendering frames"
        case .encoding: return "Encoding video"
        }
    }

    private var showsPercentInDetail: Bool {
        guard let d = progress.detail else { return false }
        return d.contains("%")
    }
}
#endif
