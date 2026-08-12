import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Plays one caption's audio range and stops exactly at its end.
///
/// Used for per-row previews in the segment list and per-word previews in the
/// word inspector. `forwardPlaybackEndTime` does the stopping, and a 100 ms
/// poll flips `isPlaying` back — `AVPlayer` posts no notification when it stops
/// at a forward end time, so without the poll the button would stay stuck on
/// "playing".
@Observable
@MainActor
final class CaptionClipPlayer {
    // `nonisolated(unsafe)` so the nonisolated `deinit` can stop playback and
    // cancel the monitor; see the note in `CaptionEditorAudioPlayer`.
    @ObservationIgnored
    private nonisolated(unsafe) var player: AVPlayer?
    @ObservationIgnored
    private nonisolated(unsafe) var monitor: Task<Void, Never>?

    private(set) var playingClipID: String?

    var isPlaying: Bool { playingClipID != nil }

    deinit {
        monitor?.cancel()
        player?.pause()
    }

    func isPlaying(clipID: String) -> Bool {
        playingClipID == clipID
    }

    /// Plays `[startMs, endMs)`. Calling it again with the same id stops.
    func toggle(url: URL, startMs: Int, endMs: Int, clipID: String) {
        if playingClipID == clipID {
            stop()
            return
        }
        play(url: url, startMs: startMs, endMs: endMs, clipID: clipID)
    }

    func play(url: URL, startMs: Int, endMs: Int, clipID: String) {
        guard endMs > startMs else { return }
        stop()

        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(value: CMTimeValue(endMs), timescale: 1000)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        playingClipID = clipID

        player.seek(
            to: CMTime(value: CMTimeValue(startMs), timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playingClipID == clipID else { return }
                player.play()
                self.startMonitor(clipID: clipID, endMs: endMs)
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        player?.pause()
        player = nil
        playingClipID = nil
    }

    private func startMonitor(clipID: String, endMs: Int) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.playingClipID == clipID, let player = self.player else { return }

                let current = Int((CMTimeGetSeconds(player.currentTime()) * 1000).rounded())
                // Treat "paused" as done too: that's what actionAtItemEnd does
                // when the forward end time is reached.
                if player.timeControlStatus != .playing || current >= endMs - 20 {
                    self.stop()
                    return
                }
            }
        }
    }
}

/// A play/stop button for one caption range.
struct CaptionClipPlayButton: View {
    let url: URL
    let startMs: Int
    let endMs: Int
    let clipID: String
    @Bindable var clipPlayer: CaptionClipPlayer

    var body: some View {
        Button {
            clipPlayer.toggle(url: url, startMs: startMs, endMs: endMs, clipID: clipID)
        } label: {
            Image(systemName: clipPlayer.isPlaying(clipID: clipID)
                ? "stop.circle.fill" : "play.circle")
        }
        .buttonStyle(.borderless)
        .disabled(endMs <= startMs)
        .help("Play this caption")
    }
}
