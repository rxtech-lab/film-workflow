import AVFoundation
import CoreGraphics
import Foundation

/// The AVFoundation objects for one timeline, ready for a player or exporter.
public struct BuiltComposition {
    public let asset: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let audioTrackIDs: [UUID: CMPersistentTrackID]
    public let duration: CMTime
    /// Clips drawn as slates because their media does not exist yet.
    public let placeholders: [ClipSource]
}

public enum CompositionBuildError: Error, Sendable {
    /// Export was asked for while a clip still has no media.
    case unrenderedClips([ClipSource])
    case missingBaseClip
}

/// Turns a `Timeline` into an `AVMutableComposition` plus a video
/// composition driven by `TimelineVideoCompositor`.
///
/// Video files become composition tracks (one per timeline track, since a
/// track never holds overlapping clips). Stills, captions and placeholders
/// never touch the composition: the compositor draws them. A looping black
/// base clip underlies everything so every segment has a source frame, which
/// is what makes AVFoundation invoke the compositor at all.
@MainActor
public struct TimelineCompositionBuilder {
    public let resolver: any MediaResolver
    public let timescale: CMTimeScale = 600

    public init(resolver: any MediaResolver) {
        self.resolver = resolver
    }

    public func build(_ timeline: Timeline, allowPlaceholders: Bool, includeSilentAudio: Bool = false) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        let duration = max(timeline.duration, timeline.frameDuration)
        let totalTime = CMTime(seconds: duration, preferredTimescale: timescale)
        var placeholders: [ClipSource] = []
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]

        // Base track: looped black so the whole duration has a source frame.
        guard let baseTrackID = try insertBaseTrack(into: composition, duration: totalTime) else {
            throw CompositionBuildError.missingBaseClip
        }

        // Resolve every source once.
        var resolved: [String: Result<ResolvedMedia, Error>] = [:]
        for clip in timeline.allClips where resolved[clip.source.id] == nil {
            do {
                resolved[clip.source.id] = .success(try await resolver.resolve(clip.source))
            } catch {
                resolved[clip.source.id] = .failure(error)
            }
        }

        // Per clip: which layer it contributes, and which composition track carries it.
        var clipLayers: [UUID: LayerSpec] = [:]
        var videoTrackIDs: [UUID: CMPersistentTrackID] = [:]   // timeline track → composition track

        // Picture order: video tracks bottom-up (last in the array is lowest), then overlays.
        let videoTracks = Array(timeline.tracks.filter { $0.kind == .video }.reversed())
        let overlayTracks = Array(timeline.tracks.filter { $0.kind == .overlay }.reversed())
        let audioTracks = timeline.tracks.filter { $0.kind == .audio }

        for track in videoTracks {
            for clip in track.sortedClips {
                switch resolved[clip.source.id] {
                case .success(.file(let url, _, _))? where clip.source.kind.hasVideo:
                    let asset = AVURLAsset(url: url)
                    if let compositionTrack = try await insertVideo(asset: asset, clip: clip, timeline: timeline, into: composition, trackIDs: &videoTrackIDs, timelineTrack: track) {
                        let sourceTrack = try await asset.loadTracks(withMediaType: .video).first
                        let preferred = try await sourceTrack?.load(.preferredTransform) ?? .identity
                        let natural = try await sourceTrack?.load(.naturalSize) ?? .zero
                        clipLayers[clip.id] = .sourceTrack(compositionTrack, transform: clip.transform, opacity: clip.opacity, preferredTransform: preferred, naturalSize: natural)
                    }
                    if includeSilentAudio || (!track.isMuted && clip.volume > 0) {
                        try await insertAudio(asset: asset, clip: clip, into: composition, parameters: &audioParameters, trackIDs: &audioTrackIDs, volume: track.isMuted ? 0 : clip.volume)
                    }
                case .success(.file(let url, _, _))?:
                    clipLayers[clip.id] = .still(url, transform: clip.transform, opacity: clip.opacity)
                case .failure(MediaResolverError.unrendered)?:
                    placeholders.append(clip.source)
                    clipLayers[clip.id] = .placeholder(clip.source.displayName)
                case .failure(let error)?:
                    throw error
                default:
                    continue
                }
            }
        }

        for track in overlayTracks {
            for clip in track.sortedClips {
                switch resolved[clip.source.id] {
                case .success(.captions(let cues))?:
                    // Shift cues onto the timeline clock and clip them to the clip.
                    let shifted = cues.compactMap { cue -> TextCue? in
                        let start = max(clip.start, cue.start - clip.inPoint + clip.start)
                        let end = min(clip.end, cue.end - clip.inPoint + clip.start)
                        return end > start ? TextCue(start: start, end: end, text: cue.text) : nil
                    }
                    clipLayers[clip.id] = .text(shifted, style: clip.text ?? .caption)
                case .success(.file(let url, _, _))?:
                    clipLayers[clip.id] = .still(url, transform: clip.transform, opacity: clip.opacity)
                case .failure(let error)?:
                    throw error
                default:
                    continue
                }
            }
        }

        for track in audioTracks where includeSilentAudio || !track.isMuted {
            for clip in track.sortedClips where includeSilentAudio || clip.volume > 0 {
                if case .success(.file(let url, _, _))? = resolved[clip.source.id] {
                    try await insertAudio(asset: AVURLAsset(url: url), clip: clip, into: composition, parameters: &audioParameters, trackIDs: &audioTrackIDs, volume: track.isMuted ? 0 : clip.volume)
                }
            }
        }

        if !allowPlaceholders, !placeholders.isEmpty {
            throw CompositionBuildError.unrenderedClips(placeholders)
        }

        // Segment the timeline at every picture edge.
        let pictureClips = (videoTracks + overlayTracks).flatMap(\.clips)
        var edges: Set<TimeInterval> = [0, duration]
        for clip in pictureClips {
            edges.insert(min(max(0, clip.start), duration))
            edges.insert(min(max(0, clip.end), duration))
        }
        let sorted = edges.sorted()
        var instructions: [TimelineCompositionInstruction] = []
        let background = CGColor.fromHex(timeline.backgroundHex)
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let mid = (a + b) / 2
            var layers: [LayerSpec] = []
            var trackIDs: [CMPersistentTrackID] = [baseTrackID]
            for track in videoTracks {
                guard let clip = track.clip(at: mid), let layer = clipLayers[clip.id] else { continue }
                layers.append(layer)
                if case .sourceTrack(let id, _, _, _, _) = layer { trackIDs.append(id) }
            }
            for track in overlayTracks {
                guard let clip = track.clip(at: mid), let layer = clipLayers[clip.id] else { continue }
                layers.append(layer)
            }
            let range = CMTimeRange(
                start: CMTime(seconds: a, preferredTimescale: timescale),
                end: CMTime(seconds: b, preferredTimescale: timescale)
            )
            instructions.append(TimelineCompositionInstruction(timeRange: range, layers: layers, sourceTrackIDs: trackIDs, backgroundColor: background))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TimelineVideoCompositor.self
        videoComposition.renderSize = timeline.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, timeline.fps)))
        videoComposition.instructions = instructions

        let mix: AVMutableAudioMix?
        if audioParameters.isEmpty {
            mix = nil
        } else {
            let m = AVMutableAudioMix()
            m.inputParameters = audioParameters
            mix = m
        }

        return BuiltComposition(
            asset: composition,
            videoComposition: videoComposition,
            audioMix: mix,
            audioTrackIDs: audioTrackIDs,
            duration: totalTime,
            placeholders: placeholders
        )
    }

    // MARK: - Tracks

    private func insertBaseTrack(into composition: AVMutableComposition, duration: CMTime) throws -> CMPersistentTrackID? {
        guard let url = Bundle.module.url(forResource: "blank", withExtension: "mov") else { return nil }
        let asset = AVURLAsset(url: url)
        // Synchronous loads are acceptable here: the clip is a bundled 1 s file.
        guard let source = asset.tracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let clipDuration = asset.duration
        var cursor = CMTime.zero
        while cursor < duration {
            let remaining = duration - cursor
            let piece = CMTimeMinimum(clipDuration, remaining)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: source, at: cursor)
            cursor = cursor + piece
        }
        return track.trackID
    }

    private func insertVideo(
        asset: AVURLAsset,
        clip: Clip,
        timeline: Timeline,
        into composition: AVMutableComposition,
        trackIDs: inout [UUID: CMPersistentTrackID],
        timelineTrack: Track
    ) async throws -> CMPersistentTrackID? {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let compositionTrack: AVMutableCompositionTrack
        if let id = trackIDs[timelineTrack.id], let existing = composition.track(withTrackID: id) as? AVMutableCompositionTrack {
            compositionTrack = existing
        } else if let created = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            compositionTrack = created
            trackIDs[timelineTrack.id] = created.trackID
        } else {
            return nil
        }
        let sourceDuration = try await asset.load(.duration)
        let inPoint = CMTime(seconds: clip.inPoint, preferredTimescale: timescale)
        let wanted = CMTime(seconds: clip.sourceRangeDuration, preferredTimescale: timescale)
        let available = CMTimeMaximum(.zero, sourceDuration - inPoint)
        let length = CMTimeMinimum(wanted, available)
        guard length > .zero else { return compositionTrack.trackID }
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: inPoint, duration: length),
            of: source,
            at: CMTime(seconds: clip.start, preferredTimescale: timescale)
        )
        let at = CMTime(seconds: clip.start, preferredTimescale: timescale)
        compositionTrack.scaleTimeRange(CMTimeRange(start: at, duration: length),
                                       toDuration: CMTime(seconds: CMTimeGetSeconds(length) / clip.playbackRate, preferredTimescale: timescale))
        return compositionTrack.trackID
    }

    private func insertAudio(
        asset: AVURLAsset,
        clip: Clip,
        into composition: AVMutableComposition,
        parameters: inout [AVMutableAudioMixInputParameters],
        trackIDs: inout [UUID: CMPersistentTrackID],
        volume: Float
    ) async throws {
        var asset = asset
        var sourceStart = clip.inPoint
        if clip.isReversed {
            let url = try await ReversedAudioCache.shared.file(for: asset.url)
            asset = AVURLAsset(url: url)
            let natural = CMTimeGetSeconds(try await asset.load(.duration))
            sourceStart = max(0, natural - clip.sourceEnd)
        }
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        let sourceDuration = try await asset.load(.duration)
        let inPoint = CMTime(seconds: sourceStart, preferredTimescale: timescale)
        let wanted = CMTime(seconds: clip.sourceRangeDuration, preferredTimescale: timescale)
        let length = CMTimeMinimum(wanted, CMTimeMaximum(.zero, sourceDuration - inPoint))
        guard length > .zero else { return }
        let at = CMTime(seconds: clip.start, preferredTimescale: timescale)
        try track.insertTimeRange(CMTimeRange(start: inPoint, duration: length), of: source, at: at)
        track.scaleTimeRange(CMTimeRange(start: at, duration: length),
                             toDuration: CMTime(seconds: CMTimeGetSeconds(length) / clip.playbackRate, preferredTimescale: timescale))
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTimePitchAlgorithm = .spectral
        input.setVolume(volume, at: at)
        trackIDs[clip.id] = track.trackID
        parameters.append(input)
    }
}
