import AVFoundation
import CoreGraphics
import Foundation
import VideoEffectsCore

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
/// Video files share a composition track per lane, except joined transition
/// inputs, which need separate tracks for simultaneous frames. Stills, captions and placeholders
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

    /// `includeCaptions` false leaves caption overlays out of the picture, for
    /// exports that deliver them as a subtitle track or a sidecar file instead.
    public func build(_ timeline: Timeline, allowPlaceholders: Bool, includeSilentAudio: Bool = false, audioOnly: Bool = false, includeCaptions: Bool = true) async throws -> BuiltComposition {
        try timeline.validateModifiers(requireDefinitions: !allowPlaceholders)
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

        // Resolve every source once. Disabled clips and lanes are skipped
        // throughout, so their media is never needed — an unrendered clip
        // that is turned off no longer holds up an export.
        var resolved: [String: Result<ResolvedMedia, Error>] = [:]
        for clip in timeline.renderedClips where resolved[clip.source.id] == nil {
            do {
                resolved[clip.source.id] = .success(try await resolver.resolve(clip.source))
            } catch {
                resolved[clip.source.id] = .failure(error)
            }
        }

        // Per clip: which layer it contributes, and which composition track carries it.
        var clipLayers: [UUID: LayerSpec] = [:]
        var videoTrackIDs: [UUID: CMPersistentTrackID] = [:]   // timeline track → composition track

        let pictureTracks = timeline.pictureTracksBackToFront
        let videoTracks = pictureTracks.filter { $0.kind == .video }
        let overlayTracks = pictureTracks.filter { $0.kind.drawsOverPicture }
        let audioTracks = timeline.tracks.filter { $0.kind == .audio }

        for track in videoTracks {
            for clip in track.renderedClips {
                if audioOnly {
                    if clip.source.kind.hasAudio, case .success(.file(let url, _, _))? = resolved[clip.source.id] {
                        try await insertAudio(asset: AVURLAsset(url: url), clip: clip, into: composition,
                                              parameters: &audioParameters, trackIDs: &audioTrackIDs,
                                              volume: track.isMuted ? 0 : clip.volume)
                    }
                    continue
                }
                switch resolved[clip.source.id] {
                case .success(.file(let url, _, _))? where clip.source.kind.hasVideo:
                    let asset = AVURLAsset(url: url)
                    let window = renderWindow(for: clip, in: timeline)
                    let naturalDuration = CMTimeGetSeconds(try await asset.load(.duration))
                    let lower = max(window.lowerBound, clip.start - clip.inPoint / clip.playbackRate)
                    let upper = min(window.upperBound, clip.start + (naturalDuration - clip.inPoint) / clip.playbackRate)
                    guard upper > lower else { throw TimelineEditError.invalidDuration }
                    var renderClip = clip
                    renderClip.start = lower
                    renderClip.duration = upper - lower
                    renderClip.inPoint = max(0, clip.inPoint + (lower - clip.start) * clip.playbackRate)
                    if let compositionTrack = try await insertVideo(asset: asset, clip: renderClip, timeline: timeline, into: composition, trackIDs: &videoTrackIDs, timelineTrack: track) {
                        let sourceTrack = try await asset.loadTracks(withMediaType: .video).first
                        let preferred = try await sourceTrack?.load(.preferredTransform) ?? .identity
                        let natural = try await sourceTrack?.load(.naturalSize) ?? .zero
                        var layer: LayerSpec = .sourceTrack(compositionTrack, transform: clip.transform, opacity: clip.opacity, preferredTransform: preferred, naturalSize: natural)
                        if lower > window.lowerBound + 0.000001 || upper < window.upperBound - 0.000001 {
                            let generator = AVAssetImageGenerator(asset: asset)
                            generator.appliesPreferredTrackTransform = true
                            generator.requestedTimeToleranceAfter = .zero
                            let fps = Double(try await sourceTrack?.load(.nominalFrameRate) ?? 30)
                            let first: CGImage? = lower > window.lowerBound + 0.000001
                                ? try await generator.image(at: .zero).image : nil
                            let last: CGImage? = upper < window.upperBound - 0.000001
                                ? try await generator.image(at: CMTime(seconds: max(0, naturalDuration - 1 / max(1, fps)), preferredTimescale: timescale)).image : nil
                            layer = .heldEdges(layer, playable: lower..<upper, first: first, last: last, transform: clip.transform, opacity: clip.opacity)
                        }
                        clipLayers[clip.id] = layer
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

        for track in overlayTracks where !audioOnly {
            for clip in track.renderedClips {
                switch resolved[clip.source.id] {
                case .success(.captions(let cues))?:
                    guard includeCaptions else { continue }
                    clipLayers[clip.id] = .text(clip.captionCues(cues), style: clip.text ?? .caption)
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
            for clip in track.renderedClips where includeSilentAudio || clip.volume > 0 {
                if case .success(.file(let url, _, _))? = resolved[clip.source.id] {
                    try await insertAudio(asset: AVURLAsset(url: url), clip: clip, into: composition, parameters: &audioParameters, trackIDs: &audioTrackIDs, volume: track.isMuted ? 0 : clip.volume)
                } else if !audioOnly, case .failure(MediaResolverError.unrendered)? = resolved[clip.source.id] {
                    placeholders.append(clip.source)
                } else if !audioOnly, case .failure(let error)? = resolved[clip.source.id] {
                    throw error
                }
            }
        }

        if !allowPlaceholders, !placeholders.isEmpty {
            throw CompositionBuildError.unrenderedClips(placeholders)
        }

        for clip in timeline.renderedClips where !clip.effects.isEmpty {
            if let layer = clipLayers[clip.id] { clipLayers[clip.id] = .processed(layer, clip.effects) }
        }

        // Segment at clip and transition edges, including held-frame boundaries.

        let pictureClips = pictureTracks.flatMap(\.renderedClips).filter { includeCaptions || $0.source.kind != .captions }
        var edges: Set<TimeInterval> = [0, duration]
        for clip in pictureClips {
            edges.insert(min(max(0, clip.start), duration))
            edges.insert(min(max(0, clip.end), duration))
        }
        for transition in timeline.transitions where transition.isEnabled {
            if let range = transition.range(in: timeline) { edges.insert(range.lowerBound); edges.insert(range.upperBound) }
        }
        for layer in clipLayers.values { addPlayableEdges(layer, to: &edges) }
        let sorted = edges.filter { $0 >= 0 && $0 <= duration }.sorted()
        var instructions: [TimelineCompositionInstruction] = []
        let background = CGColor.fromHex(timeline.backgroundHex)
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let mid = (a + b) / 2
            var layers: [LayerSpec] = []
            var trackIDs: [CMPersistentTrackID] = [baseTrackID]
            for track in pictureTracks {
                let active = timeline.transitions.first { transition in
                    transition.isEnabled && transition.attachment.clipIDs.contains(where: { id in track.renderedClips.contains { $0.id == id } })
                        && transition.range(in: timeline)?.contains(mid) == true
                }
                let layer: LayerSpec?
                if let active, let range = active.range(in: timeline) {
                    switch active.attachment {
                    case .start(let id): layer = .transition(from: nil, to: clipLayers[id], instance: active, range: range)
                    case .end(let id): layer = .transition(from: clipLayers[id], to: nil, instance: active, range: range)
                    case .between(let a, let b): layer = .transition(from: clipLayers[a], to: clipLayers[b], instance: active, range: range)
                    }
                } else { layer = track.renderedClips.first { $0.range.contains(mid) }.flatMap { clipLayers[$0.id] } }
                if let layer { layers.append(layer); trackIDs.append(contentsOf: layer.sourceTrackIDs(at: mid)) }
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

    private func renderWindow(for clip: Clip, in timeline: Timeline) -> Range<Double> {
        var lower = clip.start, upper = clip.end
        for item in timeline.transitions where item.isEnabled && item.attachment.isPair && item.attachment.clipIDs.contains(clip.id) {
            if let range = item.range(in: timeline) { lower = min(lower, range.lowerBound); upper = max(upper, range.upperBound) }
        }
        return lower..<upper
    }

    private func addPlayableEdges(_ layer: LayerSpec, to edges: inout Set<Double>) {
        switch layer {
        case .heldEdges(_, let range, _, _, _, _): edges.insert(range.lowerBound); edges.insert(range.upperBound)
        case .processed(let layer, _): addPlayableEdges(layer, to: &edges)
        default: break
        }
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
        let key = timeline.transitions.contains { $0.isEnabled && $0.attachment.isPair && $0.attachment.clipIDs.contains(clip.id) } ? clip.id : timelineTrack.id
        if let id = trackIDs[key], let existing = composition.track(withTrackID: id) as? AVMutableCompositionTrack {
            compositionTrack = existing
        } else if let created = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            compositionTrack = created
            trackIDs[key] = created.trackID
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
