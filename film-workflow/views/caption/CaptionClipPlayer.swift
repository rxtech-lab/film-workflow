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
        // The audio is a local file, so there is nothing to buffer for. Left on,
        // AVPlayer sits in `.waitingToPlayAtSpecifiedRate` for a beat on the
        // first play of a file, which delays the start for no benefit.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        playingClipID = clipID

        monitor = Task { @MainActor [weak self] in
            await player.seek(
                to: CMTime(value: CMTimeValue(startMs), timescale: 1000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard let self, self.playingClipID == clipID, !Task.isCancelled else { return }
            player.play()
            await self.monitorPlayback(clipID: clipID, endMs: endMs)
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        player?.pause()
        player = nil
        playingClipID = nil
    }

    /// Polls until the clip reaches `endMs`, then tears the player down.
    ///
    /// Startup is the subtle part: `play()` does not put the player in
    /// `.playing` synchronously, and on the first play of a file it can spend a
    /// few hundred milliseconds getting there. So "not playing" only means
    /// finished once playback has actually been observed — otherwise the first
    /// tick would stop a clip that had not started yet, and the button would do
    /// nothing until a second click found the file warm.
    private func monitorPlayback(clipID: String, endMs: Int) async {
        var hasStarted = false
        var ticksWaitingToStart = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard playingClipID == clipID, let player else { return }

            let current = Int((CMTimeGetSeconds(player.currentTime()) * 1000).rounded())
            if current >= endMs - 20 {
                stop()
                return
            }

            if player.currentItem?.status == .failed {
                stop()
                return
            }

            if player.timeControlStatus == .playing {
                hasStarted = true
            } else if hasStarted {
                // Paused before the end time: `actionAtItemEnd` fired, or the
                // item ran out early.
                if player.timeControlStatus == .paused {
                    stop()
                    return
                }
            } else {
                // Never got going — don't leave the row stuck on "stop".
                ticksWaitingToStart += 1
                if ticksWaitingToStart >= 50 {
                    stop()
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
