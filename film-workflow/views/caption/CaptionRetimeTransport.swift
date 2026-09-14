import SwiftUI

/// Observe the playback clock here so its 100 ms updates never rebuild the
/// transcript list, header or save controls.
struct CaptionRetimeTransport: View {
    let player: CaptionEditorAudioPlayer?
    let audioDurationMs: Int
    let focusedIndex: Int?
    let focusedRange: CaptionRetimeDraft.Range?
    @Binding var boundary: CaptionTimestampBoundary
    @Binding var editingBoundary: CaptionTimestampBoundary?
    let setBoundaryToPlayhead: () -> Void

    private static let pending = Color.yellow

    // MARK: - Transport

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                playbackControls(player)
            }

            pendingBanner

            HStack(spacing: 10) {
                Picker("Boundary", selection: $boundary) {
                    ForEach(CaptionTimestampBoundary.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                Button {
                    editingBoundary = boundary
                } label: {
                    Label("Type a time…", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(focusedIndex == nil)

                Spacer()

                Button {
                    guard let range = focusedRange else { return }
                    player?.clearPlaybackLimit()
                    player?.playRange(startMs: range.startMs, endMs: range.endMs)
                } label: {
                    Label("Preview", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(focusedIndex == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func playbackControls(_ player: CaptionEditorAudioPlayer) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    player.clearPlaybackLimit()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Play / Pause")
                .accessibilityIdentifier("caption-retime-play")

                Button { player.step(byMs: -1000) } label: { Image(systemName: "gobackward.1") }
                    .buttonStyle(.borderless)
                Button { player.step(byMs: 1000) } label: { Image(systemName: "goforward.1") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("caption-retime-forward")

                Spacer()

                let elapsed: String = CaptionExporter.vttTimestamp(player.currentMs)
                Text(elapsed)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("caption-retime-playhead")
            }

            if audioDurationMs > 0 {
                Slider(
                    value: Binding(
                        get: { Double(player.currentMs) },
                        set: {
                            player.clearPlaybackLimit()
                            player.seek(toMs: Int($0))
                        }
                    ),
                    in: 0...Double(audioDurationMs)
                )
            }
        }
    }

    /// Restates the pending boundary next to the playhead, so the answer to "what
    /// will Space write?" is visible without looking back up at the list.
    private var pendingBanner: some View {
        let isStart = boundary == .start
        let playhead: String = CaptionExporter.vttTimestamp(player?.currentMs ?? 0)

        return HStack(spacing: 10) {
            Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                .foregroundStyle(Self.pending)

            VStack(alignment: .leading, spacing: 1) {
                Text("Space sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let index = focusedIndex {
                    let number: Int = index + 1
                    Text(isStart ? "Start of caption \(number)" : "End of caption \(number)")
                        .font(.callout.weight(.medium))
                } else {
                    Text("No caption selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(playhead)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Self.pending)

            Button {
                setBoundaryToPlayhead()
            } label: {
                Text(isStart ? "Set Start" : "Set End")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.black)
                    .frame(minWidth: 76)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.pending)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(player == nil || focusedIndex == nil)
            .accessibilityIdentifier("caption-retime-set-boundary")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Self.pending.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Self.pending.opacity(0.45))
        }
        .animation(.snappy(duration: 0.15), value: boundary)
    }

}
