import AVFoundation
import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
public final class TimelinePreviewLayer: Identifiable {
    public nonisolated let id: UUID
    public var clip: Clip
    public var trackKind: TrackKind
    public var muted: Bool
    public var source: TimelinePreviewSource
    public var live: LivePreviewPlayback?
    public var player: AVPlayer?
    public var naturalSize: CGSize = .zero
    public var naturalDuration: Double?
    public var active = false
    public var mounted = false
    public var error: String?
    public var preparing: String?
    @ObservationIgnored private var nativeTask: Task<Void, Never>?
    @ObservationIgnored private var seekSerial = 0
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var lastPlaying = false
    @ObservationIgnored private var seekInFlight = false

    init(clip: Clip, track: Track, source: TimelinePreviewSource) {
        id = clip.id
        self.clip = clip; trackKind = track.kind; muted = track.isMuted; self.source = source
        if case .live(let descriptor) = source {
            live = LivePreviewPlayback(descriptor: descriptor)
            naturalSize = CGSize(width: descriptor.width, height: descriptor.height)
            naturalDuration = descriptor.duration
        }
        if case .media(.file(_, let duration, let size)) = source {
            naturalDuration = duration; naturalSize = size ?? .zero
        }
    }

    var blocked: Bool {
        if error != nil || preparing != nil { return true }
        if let live { return !live.ready || live.buffering || live.error != nil || live.limitation != nil }
        if case .media(.file) = source, clip.source.kind.hasVideo, trackKind == .video {
            guard let player, let item = player.currentItem else { return true }
            if item.status == .failed { error = item.error?.localizedDescription ?? "Video could not be played."; return true }
            return item.status != .readyToPlay || item.isPlaybackBufferEmpty
        }
        return false
    }

    func prepareNative() {
        guard player == nil, nativeTask == nil, trackKind == .video, clip.source.kind.hasVideo,
              case .media(.file(let url, _, _)) = source else { return }
        let capturedClip = clip
        nativeTask = Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                guard let original = try await asset.loadTracks(withMediaType: .video).first else {
                    throw PreviewError.message("This footage has no video track.")
                }
                let size = try await original.load(.naturalSize)
                let transform = try await original.load(.preferredTransform)
                let oriented = CGRect(origin: .zero, size: size).applying(transform).size
                naturalSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                let duration = try await asset.load(.duration).seconds
                naturalDuration = duration
                let available = min(capturedClip.sourceRangeDuration, max(0, duration - capturedClip.inPoint))
                guard available > 0 else { throw PreviewError.message("The clip starts beyond the end of its source.") }
                let composition = AVMutableComposition()
                let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                track.preferredTransform = transform
                let sourceRange = CMTimeRange(start: CMTime(seconds: capturedClip.inPoint, preferredTimescale: 600),
                                              duration: CMTime(seconds: available, preferredTimescale: 600))
                try track.insertTimeRange(sourceRange, of: original, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration),
                                     toDuration: CMTime(seconds: available / capturedClip.playbackRate, preferredTimescale: 600))
                try Task.checkCancellation()
                let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
                player.isMuted = true // All file audio comes from the sequence's native audio mix.
                player.actionAtItemEnd = .pause
                self.player = player
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func synchronize(time: Double, playing: Bool) {
        guard let player else { return }
        let local = min(clip.duration, max(0, time - clip.start))
        let desired = active && playing
        let drift = abs(player.currentTime().seconds - local)
        let needsSeek = lastPlaying != desired || (!desired && seekTarget != local) || (desired && drift > 0.08)
        lastPlaying = desired
        if !desired { player.pause() }
        if needsSeek && (!desired || !seekInFlight) {
            seekTarget = local
            seekInFlight = true
            seekSerial += 1
            let serial = seekSerial
            player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, self.seekSerial == serial else { return }
                    self.seekInFlight = false
                    if finished, desired, self.lastPlaying { player.play() }
                }
            }
        } else if desired && player.rate == 0 && !seekInFlight { player.play() }
    }

    func releaseNative() {
        nativeTask?.cancel(); nativeTask = nil
        seekSerial += 1; seekTarget = nil; lastPlaying = false; seekInFlight = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }

    func stop() {
        releaseNative()
        live?.update(time: 0, playing: false, rate: 1, volume: 0, muted: true, force: true)
        live?.onChange = nil
    }
}

private enum PreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private struct PreviewFileResolver: MediaResolver {
    let sources: [String: ResolvedMedia]
    func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
        guard let media = sources[source.id] else { throw MediaResolverError.unrendered(source) }
        return media
    }
    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
}

/// One transport, with independent surfaces for each picture layer and live audio source.
@MainActor @Observable
public final class TimelinePreviewController {
    public let transport: TimelinePlayerController
    public private(set) var timeline = Timeline()
    public private(set) var layers: [TimelinePreviewLayer] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public private(set) var enabled = false
    public private(set) var visible = false
    @ObservationIgnored private var resolver: (any TimelinePreviewResolver)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var fallbackTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var synchronizing = false

    public init(transport: TimelinePlayerController) { self.transport = transport }

    public func load(_ timeline: Timeline, resolver: any TimelinePreviewResolver) {
        revision += 1
        let generation = revision
        loadTask?.cancel()
        fallbackTasks.values.forEach { $0.cancel() }; fallbackTasks = [:]
        self.timeline = timeline
        enabled = true; isLoading = true; lastError = nil
        transport.setBuffering(true)
        // A suspended master clock must also suspend already-mounted live/audio surfaces.
        for layer in layers {
            layer.player?.pause()
            layer.live?.update(time: layer.clip.sourceTime(at: transport.currentTime), playing: false,
                               rate: 1, volume: 0, muted: true, force: true)
        }
        let previousResolver = self.resolver
        self.resolver = resolver
        loadTask = Task { @MainActor in
            defer { previousResolver?.release() }
            do {
                try Task.checkCancellation()
                var resolved: [String: TimelinePreviewSource] = [:]
                for clip in timeline.renderedClips where resolved[clip.source.id] == nil {
                    try Task.checkCancellation()
                    resolved[clip.source.id] = try await resolver.preview(clip.source)
                    try Task.checkCancellation()
                }
                guard generation == revision else { return }
                let old = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
                // Match the export compositor and the editor's visible track order.
                let ordered = timeline.pictureTracksBackToFront
                    + timeline.tracks.filter { $0.kind == .audio }
                var next: [TimelinePreviewLayer] = []
                for track in ordered {
                    // A disabled lane or clip gets no surface at all, which is
                    // what keeps it out of the picture and the live audio.
                    for clip in track.renderedClips {
                        guard let source = resolved[clip.source.id] else { continue }
                        let layer: TimelinePreviewLayer
                        if let prior = old[clip.id], case .live(let descriptor) = source,
                           prior.live?.descriptor == descriptor {
                            layer = prior; layer.clip = clip; layer.muted = track.isMuted; layer.trackKind = track.kind
                        } else {
                            old[clip.id]?.stop()
                            layer = TimelinePreviewLayer(clip: clip, track: track, source: source)
                        }
                        layer.live?.onChange = { [weak self, weak layer] in
                            guard let self, let layer, self.layers.contains(where: { $0 === layer }) else { return }
                            self.synchronize()
                        }
                        next.append(layer)
                    }
                }
                for layer in layers where !next.contains(where: { $0 === layer }) { layer.stop() }
                layers = next
                isLoading = false
                rebuildAudio()
                if visible { startTicker() }
                synchronize()
            } catch {
                guard generation == revision, !Task.isCancelled else { return }
                isLoading = false; lastError = error.localizedDescription
                layers.forEach { $0.stop() }; layers = []
                transport.setBuffering(true)
            }
        }
    }

    public func setVisible(_ value: Bool) {
        visible = value
        if value && enabled { startTicker(); synchronize() }
        else {
            ticker?.cancel(); ticker = nil
            transport.pause()
            for layer in layers {
                layer.releaseNative(); layer.mounted = false
                layer.live?.update(time: layer.clip.inPoint, playing: false, rate: 1, volume: 0, muted: true, force: true)
            }
        }
    }

    public func unload() {
        revision += 1
        loadTask?.cancel(); ticker?.cancel()
        fallbackTasks.values.forEach { $0.cancel() }; fallbackTasks = [:]
        layers.forEach { $0.stop() }; layers = []
        resolver?.release(); resolver = nil
        transport.onTransportChange = nil
        transport.setBuffering(false)
        enabled = false; isLoading = false; lastError = nil
    }

    private func startTicker() {
        guard ticker == nil || ticker?.isCancelled == true else { return }
        transport.onTransportChange = { [weak self] in self?.synchronize() }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.synchronize()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private func rebuildAudio() {
        var files: [String: ResolvedMedia] = [:]
        for layer in layers {
            if case .media(let media) = layer.source { files[layer.clip.source.id] = media }
        }
        transport.load(timeline, resolver: PreviewFileResolver(sources: files), audioOnly: true)
    }

    public func synchronize() {
        guard enabled, visible, !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        let time = transport.currentTime
        if !transport.isLoading, let error = transport.lastError { lastError = error }
        if let item = transport.player.currentItem, item.status == .failed {
            lastError = item.error?.localizedDescription ?? "The sequence audio could not be played."
        }
        var blocked = isLoading || lastError != nil || transport.isLoading
        if let item = transport.player.currentItem, item.status != .readyToPlay || item.isPlaybackBufferEmpty { blocked = true }
        for layer in layers {
            if let live = layer.live { layer.naturalDuration = live.descriptor.duration }
            let inSource = layer.naturalDuration.map { layer.clip.sourceTime(at: time) < $0 } ?? true
            layer.active = layer.clip.range.contains(time) && inSource
            layer.mounted = time >= layer.clip.start - 2 && time < layer.clip.end && inSource
            if layer.mounted {
                layer.prepareNative()
                if let live = layer.live, live.limitation != nil || (live.ready && (layer.clip.playbackRate > 10 || layer.clip.volume > 1)) {
                    prepareFallback(layer)
                }
            } else if layer.player != nil {
                layer.releaseNative()
            }
            if layer.active && layer.blocked { blocked = true }
        }
        transport.setBuffering(blocked)
        let playing = transport.isPlaying && !blocked
        for layer in layers {
            layer.synchronize(time: time, playing: playing)
            layer.live?.update(time: layer.clip.sourceTime(at: time), playing: layer.active && playing,
                               rate: min(10, layer.clip.playbackRate), volume: min(1, layer.clip.volume),
                               muted: !layer.active || layer.muted)
        }
    }

    private func prepareFallback(_ layer: TimelinePreviewLayer) {
        let id = layer.clip.source.id
        guard fallbackTasks[id] == nil, let resolver, layer.preparing == nil else { return }
        let generation = revision
        layer.preparing = "Preparing rendered preview…"
        fallbackTasks[id] = Task { @MainActor in
            do {
                let media = try await resolver.renderedPreview(layer.clip.source) { [weak self] label in
                    guard let self, generation == self.revision else { return }
                    for item in self.layers where item.clip.source.id == id { item.preparing = label }
                }
                try Task.checkCancellation()
                guard generation == revision else { return }
                for item in layers where item.clip.source.id == id {
                    item.stop(); item.live = nil; item.source = .media(media); item.preparing = nil
                    item.error = nil; item.prepareNative()
                }
                rebuildAudio()
            } catch {
                guard generation == revision, !Task.isCancelled else { return }
                for item in layers where item.clip.source.id == id { item.preparing = nil; item.error = error.localizedDescription }
            }
            synchronize()
        }
    }
}
