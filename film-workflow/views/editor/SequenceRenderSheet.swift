import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Codec choice before a sequence render, with a note on Remotion clips that
/// will be rendered first.
struct SequenceRenderSheet: View {
    let sequence: SequenceProject
    let onRender: (TimelineExporter.Preset) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var preset: TimelineExporter.Preset = .h264

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Render Sequence").font(.headline)
                    Text(sequence.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Codec", selection: $preset) {
                ForEach(TimelineExporter.Preset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            let stale = SequenceRenderService.unrenderedRemotionProjects(in: sequence, context: modelContext)
            Text("\(sequence.width) × \(sequence.height) @ \(sequence.fps) fps, \(Timecode.string(seconds: sequence.timeline.duration, fps: sequence.fps)). Saved into the film as version \((SequenceRenderService.renders(for: sequence, context: modelContext).map(\.versionNumber).max() ?? 0) + 1).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !stale.isEmpty {
                Label("\(stale.count) Remotion clip\(stale.count == 1 ? "" : "s") will be rendered first: \(stale.map(\.name).joined(separator: ", "))", systemImage: "atom")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Render") { onRender(preset) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct SequenceRenderProgressSheet: View {
    let sequenceName: String
    let progress: SequenceRenderProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendering Sequence").font(.headline)
                    Text(sequenceName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(progress.label).font(.subheadline.weight(.medium))
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
