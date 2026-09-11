import AVFoundation
import Foundation
import Observation

/// Plays a timeline through the same composition the exporter uses.
///
/// Structural edits rebuild the composition. Volume and mute edits update
/// the active mix without replacing the item or seeking during playback.
@MainActor
@Observable
public final class TimelinePlayerController {
    public let player = AVPlayer()
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var placeholders: [ClipSource] = []
    public private(set) var lastError: String?
    public private(set) var isBuffering = false
    public private(set) var isLoading = false
    @ObservationIgnored public var onTransportChange: (() -> Void)?

    /// Longest edge the preview renders at; export ignores this.
    public var previewMaxWidth: Double = 1280

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var frameDuration: TimeInterval = 1 / 30
    private var loadTask: Task<Void, Never>?
    private var loadedTimeline: Timeline?
    private var loadedAudioOnly = false
    private var loadGeneration = 0
    private var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]

    public init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = max(0, CMTimeGetSeconds(time))
                self.onTransportChange?()
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
                self.currentTime = self.duration
                self.onTransportChange?()
            }
        }
    }

    /// Builds and installs the composition for `timeline`. Cancels a build in flight.
    public func load(_ timeline: Timeline, resolver: any MediaResolver, audioOnly: Bool = false) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        lastError = nil
        if let loadedTimeline, timeline != loadedTimeline,
           loadedAudioOnly == audioOnly,
           Self.withoutAudioLevels(timeline) == Self.withoutAudioLevels(loadedTimeline),
           let item = player.currentItem {
            let mix = AVMutableAudioMix()
            mix.inputParameters = timeline.tracks.flatMap { track in
                track.clips.compactMap { clip -> AVMutableAudioMixInputParameters? in
                    guard let trackID = audioTrackIDs[clip.id] else { return nil }
                    let input = AVMutableAudioMixInputParameters()
                    input.trackID = trackID
                    input.audioTimePitchAlgorithm = .spectral
                    input.setVolume(track.isMuted ? 0 : clip.volume, at: .zero)
                    return input
                }
            }
            item.audioMix = mix
            self.loadedTimeline = timeline
            lastError = nil
            isLoading = false
            onTransportChange?()
            return
        }
        frameDuration = timeline.frameDuration
        let wasPlaying = isPlaying
        isLoading = true
        duration = timeline.duration
        player.pause()
        loadTask = Task { @MainActor in
            defer { if generation == loadGeneration { isLoading = false; onTransportChange?() } }
            do {
                let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: true, includeSilentAudio: true, audioOnly: audioOnly)
                guard !Task.isCancelled else { return }
                let scale = min(1, previewMaxWidth / Double(max(1, timeline.width)))
                built.videoComposition.renderScale = Float(scale)
                let item = AVPlayerItem(asset: built.asset)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                player.replaceCurrentItem(with: item)
                loadedTimeline = timeline
                loadedAudioOnly = audioOnly
                audioTrackIDs = built.audioTrackIDs
                duration = CMTimeGetSeconds(built.duration)
                placeholders = built.placeholders
                lastError = nil
                let target = min(currentTime, max(0, duration))
                await seekPlayer(to: target)
                guard !Task.isCancelled else { return }
                if wasPlaying, isPlaying, !isBuffering { player.play() }
            } catch {
                if generation == loadGeneration, !Task.isCancelled { lastError = error.localizedDescription }
            }
        }
    }

    public func unload() {
        loadGeneration += 1
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        placeholders = []
        loadedTimeline = nil
        audioTrackIDs = [:]
        isBuffering = false
        isLoading = false
        onTransportChange?()
    }

    public func play() {
        guard player.currentItem != nil else { return }
        if currentTime >= duration - frameDuration / 2 {
            currentTime = 0
            Task {
                await seekPlayer(to: 0)
                if isPlaying, !isBuffering, !isLoading { player.play() }
            }
        } else {
            if !isBuffering, !isLoading { player.play() }
        }
        isPlaying = true
        onTransportChange?()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        onTransportChange?()
    }

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Frame-accurate seek used by scrubbing and the playhead.
    public func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        // The editing cursor can travel beyond media; only AVPlayer is bounded.
        currentTime = max(0, time)
        onTransportChange?()
        let clamped = min(currentTime, max(0, duration))
        guard player.currentItem != nil else { return }
        Task { await seekPlayer(to: clamped) }
    }

    public func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    /// Buffering suspends the clock without losing the user's play/pause intent.
    public func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
        if value { player.pause() }
        else if isPlaying, !isLoading { player.play() }
    }

    private static func withoutAudioLevels(_ timeline: Timeline) -> Timeline {
        var normalized = timeline
        for track in normalized.tracks.indices {
            normalized.tracks[track].isMuted = false
            for clip in normalized.tracks[track].clips.indices {
                normalized.tracks[track].clips[clip].volume = 1
            }
        }
        return normalized
    }

    private func seekPlayer(to time: TimeInterval) async {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
