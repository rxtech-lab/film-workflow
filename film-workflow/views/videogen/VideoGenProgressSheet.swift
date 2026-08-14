import SwiftUI

struct VideoGenProgressSheet: View {
    let projectName: String
    @Binding var progress: VideoGenProgress
    var onCancel: () -> Void

    @State private var showCancelConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "video.badge.waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generating Video")
                        .font(.headline)
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(progress.title)
                    .font(.subheadline.weight(.medium))

                if let fraction = progress.fraction {
                    ProgressView(value: fraction, total: 1.0)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Text(progress.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Video generation usually takes a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .destructive) {
                    showCancelConfirm = true
                }
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .interactiveDismissDisabled(true)
        .confirmationDialog(
            "Stop waiting for this video?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Waiting", role: .destructive) { onCancel() }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            // Cancelling only stops the app from waiting — the provider has
            // already been paid, so the job is kept and can be resumed.
            Text("The provider will keep working on it and may still bill this job. You can resume it from the project later.")
        }
    }
}
