import AVFoundation
import Foundation
import Observation

/// Plays one narration at a time for audition in a picker.
///
/// Kept separate from `CaptionEditorAudioPlayer` (which is built for
/// millisecond-exact scrubbing) and from `AudioPlayerManager` /
/// `AudioPlayerRegistry` in the Music views — that registry never evicts its
/// players, so routing narration files through it would pin every previewed
/// file in memory for the life of the process.
///
/// Whole-file playback with a coarse position readout is all a picker needs.
@Observable
@MainActor
final class CaptionNarrationPreviewPlayer {
    @ObservationIgnored
    private nonisolated(unsafe) var player: AVPlayer?
    @ObservationIgnored
    private nonisolated(unsafe) var timeObserver: Any?

    /// The narration currently loaded for preview — playing or paused.
    private(set) var playingURL: URL?
    private(set) var currentMs: Int = 0
    private(set) var durationMs: Int = 0

    var isAnyPlaying: Bool { playingURL != nil }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        player?.pause()
    }

    func isPlaying(url: URL) -> Bool {
        playingURL == url
    }

    /// Starts `url`, or pauses/resumes it when it's already loaded.
    ///
    /// Pauses rather than stops so the scrubber and position survive — losing
    /// your place every time you pause makes auditioning a long narration
    /// needlessly painful. Starting a different file replaces the current one;
    /// only one preview plays at a time.
    func toggle(url: URL) {
        if playingURL == url {
            togglePlayPause()
        } else {
            play(url: url)
        }
    }

    func play(url: URL) {
        stop()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        playingURL = url
        currentMs = 0
        durationMs = 0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playingURL == url else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.currentMs = Int(seconds * 1000) }
                // Reaching the end pauses (actionAtItemEnd) but deliberately
                // does not tear down, so the scrubber stays usable and you can
                // replay a passage without reloading.
            }
        }

        Task { [weak self] in
            guard let duration = try? await item.asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(duration)
            guard let self, self.playingURL == url, seconds.isFinite, seconds > 0 else { return }
            self.durationMs = Int(seconds * 1000)
        }

        player.play()
    }

    /// Scrubs the running preview. No-op when nothing is playing.
    func seek(toMs ms: Int) {
        guard let player else { return }
        let clamped = max(0, durationMs > 0 ? min(ms, durationMs) : ms)
        currentMs = clamped
        // Zero tolerance so the thumb lands where it was dropped rather than on
        // the nearest keyframe, which can be seconds away in a long narration.
        player.seek(
            to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    var isPaused: Bool {
        guard let player else { return false }
        return player.timeControlStatus != .playing
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        playingURL = nil
        currentMs = 0
        durationMs = 0
    }
}
