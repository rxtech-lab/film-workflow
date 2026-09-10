import AVFoundation
import Foundation
import Observation

/// Plays a timeline through the same composition the exporter uses.
///
/// Rebuilding the composition on every edit is cheap (metadata only), so the
/// owner simply calls `load` again when the timeline changes; playback
/// position is preserved.
@MainActor
@Observable
public final class TimelinePlayerController {
    public let player = AVPlayer()
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var placeholders: [ClipSource] = []
    public private(set) var lastError: String?

    /// Longest edge the preview renders at; export ignores this.
    public var previewMaxWidth: Double = 1280

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var frameDuration: TimeInterval = 1 / 30
    private var loadTask: Task<Void, Never>?

    public init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = max(0, CMTimeGetSeconds(time))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Only the identity crosses to the main actor; the item itself is not Sendable.
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.isPlaying = false
            }
        }
    }

    /// Builds and installs the composition for `timeline`. Cancels a build in flight.
    public func load(_ timeline: Timeline, resolver: any MediaResolver) {
        loadTask?.cancel()
        frameDuration = timeline.frameDuration
        let wasPlaying = isPlaying
        let position = currentTime
        loadTask = Task { @MainActor in
            do {
                let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: true)
                guard !Task.isCancelled else { return }
                let scale = min(1, previewMaxWidth / Double(max(1, timeline.width)))
                built.videoComposition.renderScale = Float(scale)
                let item = AVPlayerItem(asset: built.asset)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                player.replaceCurrentItem(with: item)
                duration = CMTimeGetSeconds(built.duration)
                placeholders = built.placeholders
                lastError = nil
                let target = min(position, max(0, duration - frameDuration))
                await seekPlayer(to: target)
                if wasPlaying { player.play(); isPlaying = true }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func unload() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        placeholders = []
    }

    public func play() {
        guard player.currentItem != nil else { return }
        if currentTime >= duration - frameDuration / 2 {
            Task { await seekPlayer(to: 0) ; player.play() }
        } else {
            player.play()
        }
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Frame-accurate seek used by scrubbing and the playhead.
    public func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(0, duration))
        currentTime = clamped
        Task { await seekPlayer(to: clamped) }
    }

    public func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    private func seekPlayer(to time: TimeInterval) async {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }
}
