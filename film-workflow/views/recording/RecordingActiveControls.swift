import SwiftUI

/// The live session's pause/resume/stop controls. The floating toolbar shows
/// the full row; the panel beside the pet shows the compact one.
struct RecordingActiveControls: View {
    var compact = false
    @State private var session = RecordingSession.shared
    @State private var setup = RecordingSetup.shared

    private var prefix: String { compact ? "recording.pet" : "recording.toolbar" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: compact ? 8 : 14) {
                Image(systemName: session.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .font(compact ? .body : .title2).foregroundStyle(session.phase == .paused ? .orange : .red)
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.project?.name ?? "Recording").font(.headline).lineLimit(1)
                        Text(session.phase == .finalizing ? "Saving take…" : session.phase == .paused ? "Paused" : "Recording")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(session.elapsed, specifier: "%.1f")s").monospacedDigit().font(compact ? .callout : .body)
                Spacer(minLength: 0)
                if session.phase == .paused {
                    if let project = session.project, let document = session.document {
                        Button("Change Sources…", systemImage: "slider.horizontal.3") { setup.open(project: project, document: document, editing: true) }
                            .compactLabels(compact)
                            .accessibilityIdentifier("\(prefix).changeSources")
                    }
                    Button("Resume", systemImage: "play.fill") { session.resume() }
                        .compactLabels(compact)
                        .accessibilityIdentifier("\(prefix).resume")
                } else {
                    Button("Pause", systemImage: "pause.fill") { session.pause() }.disabled(!session.canPause)
                        .compactLabels(compact)
                        .accessibilityIdentifier("\(prefix).pause")
                }
                Button("Stop Recording", systemImage: "stop.fill") { Task { await session.stop() } }
                    .buttonStyle(.glassProminent).tint(.red).disabled(session.phase == .finalizing)
                    .compactLabels(compact)
                    .accessibilityIdentifier("\(prefix).stop")
            }
            if let message = session.error ?? session.notice {
                Text(message).font(.caption).foregroundStyle(session.error == nil ? Color.secondary : .red)
                    .lineLimit(compact ? 2 : 1).help(message)
            }
        }
    }
}

private extension View {
    /// The panel beside the pet has room for glyphs only.
    @ViewBuilder func compactLabels(_ compact: Bool) -> some View {
        if compact { labelStyle(.iconOnly) } else { labelStyle(.automatic) }
    }
}
