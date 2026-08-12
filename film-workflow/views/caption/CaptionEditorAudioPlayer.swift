import AVFoundation
import Foundation
import Observation

/// Millisecond-accurate scrubbing for the caption editors.
///
/// Deliberately not the existing `AudioPlayerManager` (`views/music/MusicPlayerView.swift`):
/// that wraps `AVAudioPlayer`, whose `currentTime` is not sample-accurate for
/// compressed formats and which offers no way to stop at an exact time. Caption
/// retiming lives or dies on exact seeks, so this uses `AVPlayer` with
/// zero-tolerance seeking. It also sidesteps `AudioPlayerRegistry`, which never
/// evicts and would pin hour-long files in memory forever.
@Observable
@MainActor
final class CaptionEditorAudioPlayer {
    // `nonisolated(unsafe)` so `deinit` (which is nonisolated under Swift 6) can
    // remove the time observer. The observer must be removed before the player
    // deallocates or AVFoundation can crash. Sound because deinit runs exactly
    // once, when no other reference remains.
    private nonisolated let player: AVPlayer
    // @ObservationIgnored keeps the Observation macro from wrapping this, which
    // would conflict with `nonisolated(unsafe)`. Nothing observes it anyway.
    @ObservationIgnored
    private nonisolated(unsafe) var timeObserver: Any?

    /// Current position in milliseconds.
    private(set) var currentMs: Int = 0
    private(set) var isPlaying = false
    private(set) var durationMs: Int = 0

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        // Local file: there is nothing to buffer for, and waiting only stalls
        // the first play by a few hundred milliseconds.
        player.automaticallyWaitsToMinimizeStalling = false

        // 100 ms matches the retimer's needs without burning CPU on a long file.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentMs = Int((seconds * 1000).rounded())
                }
                // `.waitingToPlayAtSpecifiedRate` counts as playing: the player
                // is ramping up after `play()`, and flipping the button back to
                // "play" there makes the user's first click look ignored.
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }

        Task { await loadDuration() }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        player.pause()
    }

    private func loadDuration() async {
        guard let item = player.currentItem else { return }
        if let duration = try? await item.asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                durationMs = Int((seconds * 1000).rounded())
            }
        }
    }

    // MARK: - Transport

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Seeks with zero tolerance — anything else lands on the nearest keyframe,
    /// which can be seconds away and makes "set start to current time" lie.
    func seek(toMs ms: Int) {
        let clamped = max(0, durationMs > 0 ? min(ms, durationMs) : ms)
        currentMs = clamped
        player.seek(
            to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(byMs delta: Int) {
        seek(toMs: currentMs + delta)
    }

    /// Plays from `startMs` and stops at `endMs`.
    func playRange(startMs: Int, endMs: Int) {
        guard endMs > startMs else { return }
        seek(toMs: startMs)
        player.currentItem?.forwardPlaybackEndTime =
            CMTime(value: CMTimeValue(endMs), timescale: 1000)
        play()
    }

    /// Clears a previous `playRange` limit so normal playback runs to the end.
    func clearPlaybackLimit() {
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }
}
